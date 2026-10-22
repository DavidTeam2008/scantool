#!/usr/bin/env bash
#
# Word 导出保真度校验（spec/word-fidelity T003 / SC-002）。
#
# 流程：
#   1. 取 `build/word-fidelity/out-pageimage.docx`（App 产出的图片版 Word）
#      与 `out-restored.docx`（可编辑版对照）；
#   2. 用 macOS QuickLook（qlmanage）把 docx **渲染成图片**（等价于「在 Word
#      里打开看长什么样」—— macOS 的 Word 文档预览器）；
#   3. 用 ffmpeg 的 SSIM 把渲染图与两张参考图比对：
#      - `page.jpg`   = App 导出的**页面图**（透视矫正 + 增强后的整页）
#                       → **导出保真度**（Word 是否忠实复现了要导出的页面）
#      - `reference.jpg` = 原始照片 → **用户口径**（与原片的相似度）
#   4. 门限：导出保真度 SSIM ≥ 0.90（验收门）；用户口径一并打印。
#
# 用法：make word-fidelity   （先跑 make test-only T=WordFidelityExportTests）
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="$ROOT/build/word-fidelity"
THRESHOLD="${WORD_FIDELITY_THRESHOLD:-0.90}"

if [[ ! -f "$OUT/out-pageimage.docx" ]]; then
  echo "✗ 缺少 $OUT/out-pageimage.docx —— 先跑：make test-only T=WordFidelityExportTests" >&2
  exit 2
fi
for tool in qlmanage ffmpeg ffprobe; do
  command -v "$tool" >/dev/null || { echo "✗ 缺少依赖：$tool" >&2; exit 2; }
done

dims() {  # $1 = 图片 → "宽 高"
  ffprobe -v error -select_streams v:0 -show_entries stream=width,height \
    -of csv=p=0 "$1" | tr ',' ' '
}

render() {  # $1 = docx 路径 → 打印渲染出的 PNG 路径
  local docx="$1"
  local tmp png
  tmp="$(mktemp -d)"
  qlmanage -t -s 1600 -o "$tmp" "$docx" >/dev/null 2>&1 || true
  png="$(find "$tmp" -name '*.png' -maxdepth 1 | head -1)"
  if [[ -z "$png" ]]; then
    echo "✗ qlmanage 未能渲染 $docx" >&2
    exit 3
  fi
  echo "$png"
}

# 渲染图 → 页面图区：预览器把页面塞进固定画布（macOS 用 A4），页面图按宽度或
# 高度贴合 → 画布上会多出白边。比对前先**裁到内容区**（否则一条白边会被
# 放大成整体错位，SSIM 失真）。
ssim() {  # $1 = 渲染图 $2 = 参考图 → 打印 SSIM（0~1）
  local rw rh iw ih
  read -r rw rh <<<"$(dims "$1")"
  read -r iw ih <<<"$(dims "$2")"
  # 内容区裁剪：渲染图比参考图更宽 → 内容按高度贴合（裁两侧）；更窄 → 按宽度
  # 贴合（裁底部，页图在顶部）。
  local crop
  if python3 -c "import sys; sys.exit(0 if $rw * $ih > $rh * $iw else 1)"; then
    crop="crop=min(iw\\,ih*$iw/$ih):ih:(iw-min(iw\\,ih*$iw/$ih))/2:0"
  else
    crop="crop=iw:min(ih\\,iw*$ih/$iw):0:0"
  fi
  # 口径（**必须**照此执行，否则数字不可比）：
  #   · 统一缩放到 800×800（同一形变，抹掉预览器与原图的分辨率差）；
  #   · 统一高斯模糊 sigma=3（**对齐容差**）：预览器把页面塞进自己的画布，
  #     与原图存在 ~0.2% 的比例差 → 边缘错位 1~2px；不模糊的话 SSIM 会被
  #     文字笔画边缘吃掉（同一张图也能只有 0.6），失真。
  #   · 模糊只抹掉亚像素错位，**版面/文字块的错位与重排仍被如实惩罚**
  #     （实测：图片版 0.93 / 版面还原档 0.77）。
  ffmpeg -v info -i "$1" -i "$2" \
    -lavfi "[0:v]${crop},scale=800:800:flags=bicubic,gblur=sigma=3[a];[1:v]scale=800:800:flags=bicubic,gblur=sigma=3[b];[a][b]ssim" -f null - 2>&1 \
    | sed -n 's/.*All:\([0-9.]*\).*/\1/p' | tail -1
}

echo "=== Word 导出保真度（spec/word-fidelity T003）==="
echo "阈值：SSIM ≥ $THRESHOLD"
echo ""

# 模型真值（App 侧离屏渲染：预览 == 导出模型，与外部渲染器无关）。
# model = 导出模型本身的保真度；docx = 外部渲染器看到的保真度；
# 两者之差 = **导出层（OOXML）造成的损失**（叠字/错位都在这一层）。
model_score() {  # $1 = 模型渲染 PNG
  ssim "$1" "$OUT/page.jpg"
}

status=0
for tier in pageimage restored; do
  docx="$OUT/out-$tier.docx"
  [[ -f "$docx" ]] || continue
  png="$(render "$docx")"
  s_page="$(ssim "$png" "$OUT/page.jpg")"
  s_ref="$(ssim "$png" "$OUT/reference.jpg")"
  echo "[$tier]"
  echo "  渲染图        : $png"
  echo "  SSIM(页面图)  : ${s_page:-n/a}   ← 导出保真度（门限 ${THRESHOLD}）"
  echo "  SSIM(原始照片): ${s_ref:-n/a}   ← 用户口径（与原片相似度）"
  model_png="$OUT/preview-$tier.png"
  if [[ -f "$model_png" ]]; then
    s_model="$(model_score "$model_png")"
    echo "  SSIM(导出模型): ${s_model:-n/a}   ← App 侧模型真值（预览 == 导出模型）"
    echo "  导出层损失    : $(python3 -c "
try:
    print('%.3f' % (float('$s_model') - float('$s_page')))
except Exception:
    print('n/a')
" 2>/dev/null)   ← 模型 → docx 的差（叠字/错位都在这一层）"
  fi
  if [[ "$tier" == "pageimage" ]]; then
    if [[ -z "$s_page" ]] || ! python3 -c "import sys; sys.exit(0 if float('$s_page') >= $THRESHOLD else 1)"; then
      echo "  ✗ 未达门限（导出保真度）"
      status=1
    else
      echo "  ✓ 导出保真度达标"
    fi
  fi
  echo ""
done
exit $status
