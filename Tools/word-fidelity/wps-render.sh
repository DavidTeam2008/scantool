#!/usr/bin/env bash
#
# 用本机 WPS Office 把 docx 转成 PDF，再把第一页 PDF 转成 PNG。
# 这是用户口径「把 Word 转成图片」的本机实现；QuickLook 只作自动闸门代理。
#
# 依赖：
#   - /Applications/wpsoffice.app
#   - macOS Accessibility（终端/OpenCode 已被授权控制 System Events）
#   - qlmanage（PDF 第一页 → PNG）
#
# 用法：
#   ./Tools/word-fidelity/wps-render.sh <input.docx> [output-dir]
#
# 产物：
#   <output-dir>/<basename>.pdf
#   <output-dir>/<basename>-wps.png
#
# 注意：WPS 的 PDF 导出走「文件 → 输出为PDF...」；不点「纯图PDF」（VIP）。
set -euo pipefail

DOCX="${1:?用法: wps-render.sh <input.docx> [output-dir]}"
[[ -f "$DOCX" ]] || { echo "✗ 文件不存在：$DOCX" >&2; exit 2; }
DOCX="$(cd "$(dirname "$DOCX")" && pwd)/$(basename "$DOCX")"
SRC_DIR="$(dirname "$DOCX")"
OUTDIR="${2:-$SRC_DIR}"
mkdir -p "$OUTDIR"
OUTDIR="$(cd "$OUTDIR" && pwd)"
BASE="$(basename "$DOCX" .docx)"
# WPS 的导出队列会记住上一次成功任务，复用同一路径时行可能未勾选。
# 每次用唯一副本打开，强制 WPS 新建一条已勾选的导出任务。
WORK_DOCX="$OUTDIR/wps-render-${BASE}-$$.docx"
WORK_BASE="$(basename "$WORK_DOCX" .docx)"
cp "$DOCX" "$WORK_DOCX"
# WPS 的 PDF 导出默认落在源 docx 同目录；随后复制到 OUTDIR。
PDF_SRC="$OUTDIR/$WORK_BASE.pdf"
PDF="$OUTDIR/$BASE.pdf"
PNG="$OUTDIR/$BASE-wps.png"

WPS_APP="/Applications/wpsoffice.app"
[[ -d "$WPS_APP" ]] || { echo "✗ 未安装 WPS：$WPS_APP" >&2; exit 2; }
for tool in qlmanage osascript; do
  command -v "$tool" >/dev/null || { echo "✗ 缺少依赖：$tool" >&2; exit 2; }
done

rm -f "$PDF_SRC" "$PDF" "$PNG"
TMP=""
trap 'rm -f "$WORK_DOCX" "$PDF_SRC"; [[ -n "$TMP" ]] && rm -rf "$TMP"' EXIT

osascript <<'APPLESCRIPT' >/dev/null 2>&1 || true
tell application "System Events"
  if exists process "wpsoffice" then
    tell process "wpsoffice"
      set frontmost to true
      repeat with w in (every window)
        try
          set t to title of w as text
          if t is "输出为PDF" or t is "批量输出为图片" or t is "" then
            click (first UI element of w whose description is "关闭按钮")
          end if
        end try
      end repeat
    end tell
  end if
end tell
APPLESCRIPT

open -a "$WPS_APP" "$WORK_DOCX"

# 等 WPS 打开文档窗口（标题 = 文件名）。
for _ in $(seq 1 40); do
  if osascript -e 'tell application "System Events" to tell process "wpsoffice" to get title of every window' 2>/dev/null \
      | grep -Fq "$(basename "$WORK_DOCX")"; then
    break
  fi
  sleep 1
done

osascript <<'APPLESCRIPT'
tell application "wpsoffice" to activate
tell application "System Events"
  tell process "wpsoffice"
    set frontmost to true
    click menu item "输出为PDF..." of menu 1 of menu bar item "文件" of menu bar 1
  end tell
end tell
APPLESCRIPT

# 等导出窗口出现。
for _ in $(seq 1 20); do
  if osascript -e 'tell application "System Events" to tell process "wpsoffice" to get title of every window' 2>/dev/null \
      | grep -Fq "输出为PDF"; then
    break
  fi
  sleep 1
done

# 给 WPS 队列行一点渲染时间；过早点击时按钮还是禁用态。
sleep 3

osascript <<'APPLESCRIPT'
tell application "System Events"
  tell process "wpsoffice"
    set frontmost to true
    click button "开始输出" of group 1 of window "输出为PDF"
  end tell
end tell
APPLESCRIPT

# WPS 有时弹「文件已添加到队列中」提示（标题为空，窗口 2），点「是(Y)」继续。
for _ in $(seq 1 20); do
  CLICKED="$(osascript <<'APPLESCRIPT' 2>/dev/null || true
tell application "System Events"
  tell process "wpsoffice"
    repeat with w in (every window)
      try
        if exists button "是(Y)" of w then
          click button "是(Y)" of w
          return "yes"
        end if
      end try
    end repeat
  end tell
end tell
return ""
APPLESCRIPT
)"
  [[ "$CLICKED" == "yes" ]] && break
  sleep 0.5
done

# 等 PDF 落盘（WPS 默认保存到源文件同目录）。
for _ in $(seq 1 60); do
  [[ -s "$PDF_SRC" ]] && break
  sleep 1
done
if [[ ! -s "$PDF_SRC" ]]; then
  echo "✗ WPS 未产出 PDF：$PDF_SRC" >&2
  exit 3
fi
if [[ "$PDF_SRC" != "$PDF" ]]; then
  cp "$PDF_SRC" "$PDF"
fi

# PDF 第一页 → PNG（2000px 高，比例与原页一致）。
TMP="$(mktemp -d)"
qlmanage -t -s 2000 -o "$TMP" "$PDF" >/dev/null 2>&1 || true
RENDERED="$(find "$TMP" -maxdepth 1 -name '*.png' | head -1)"
if [[ -z "$RENDERED" ]]; then
  echo "✗ qlmanage 未能渲染 PDF：$PDF" >&2
  exit 4
fi
cp "$RENDERED" "$PNG"
echo "PDF : $PDF"
echo "PNG : $PNG"
