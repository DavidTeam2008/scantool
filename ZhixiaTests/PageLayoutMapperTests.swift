import Testing
import Foundation

@testable import Zhixia

/// 归一化 bbox ↔ 画布像素 / DOCX EMU 映射契约（spec/layout-restore plan D6/D7）。
///
/// 预览（LayoutCanvas）与 DOCX 导出（动态 sectPr + 浮动定位）**共用同一坐标映射**：
/// Vision 归一化坐标（左下原点、y 向上、相对于整页）→ 目标空间（左上原点、y 向下，
/// 单位为画布像素或 EMU）。历史上 y 翻转 / 单位换算散落在 view 与导出各自实现里
/// （`1 px @96dpi = 9525 EMU`、posOffset 误用 twips 的教训见 DocxExportService.emus），
/// 这里把映射收敛成纯函数并锁住数值。
struct PageLayoutMapperTests {

    private let accuracy = 1e-9

    // MARK: - 构造（aspect-fit 参数）

    @Test("同尺寸目标：纯线性缩放，scale=1、offset=0（DOCX 动态页即此情形）")
    func identityMapParameters() {
        let map = PageLayoutMapper.map(pageSize: CGSize(width: 869, height: 1024), targetSize: CGSize(width: 869, height: 1024))
        #expect(abs(map.scale - 1) < accuracy)
        #expect(map.offset == .zero)
        #expect(map.flipsY)
    }

    @Test("等比缩放：留白方向 offset=0，铺满方向 offset=0")
    func uniformScaleHasNoOffset() {
        let map = PageLayoutMapper.map(pageSize: CGSize(width: 2000, height: 1000), targetSize: CGSize(width: 1000, height: 500))
        #expect(abs(map.scale - 0.5) < accuracy)
        #expect(map.offset == .zero)
    }

    @Test("aspect-fit 留白：目标比源「更方」→ 上下留白、水平铺满")
    func aspectFitLetterboxesVertically() {
        // 极端宽高比：2000×100 的长条页放进 1000×2000 的竖版画布
        let map = PageLayoutMapper.map(pageSize: CGSize(width: 2000, height: 100), targetSize: CGSize(width: 1000, height: 2000))
        #expect(abs(map.scale - 0.5) < accuracy) // min(1000/2000, 2000/100)
        #expect(abs(map.offset.x) < accuracy) // 水平铺满
        #expect(abs(map.offset.y - 975) < accuracy) // (2000 - 100*0.5)/2
    }

    @Test("aspect-fit 留白：目标比源「更扁」→ 左右留白、垂直铺满")
    func aspectFitLetterboxesHorizontally() {
        let map = PageLayoutMapper.map(pageSize: CGSize(width: 100, height: 2000), targetSize: CGSize(width: 2000, height: 1000))
        #expect(abs(map.scale - 0.5) < accuracy) // min(2000/100, 1000/2000)
        #expect(abs(map.offset.x - 975) < accuracy) // (2000 - 100*0.5)/2
        #expect(abs(map.offset.y) < accuracy)
    }

    @Test("退化输入：零尺寸页不产生 NaN/Inf")
    func degeneratePageSizeIsSafe() {
        let map = PageLayoutMapper.map(pageSize: .zero, targetSize: CGSize(width: 100, height: 100))
        let mapped = map.rect(CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5))
        #expect(mapped.width.isFinite && mapped.height.isFinite)
        #expect(mapped.isNull || (mapped.width >= 0 && mapped.height >= 0))
    }

    // MARK: - 数值断言（y 翻转集中在此）

    @Test("整页归一化框 (0,0,1,1) 映射为整个目标区域")
    func fullNormalizedRectMapsToTarget() {
        let map = PageLayoutMapper.map(pageSize: CGSize(width: 869, height: 1024), targetSize: CGSize(width: 434.5, height: 512))
        let rect = map.rect(CGRect(x: 0, y: 0, width: 1, height: 1))
        #expect(abs(rect.minX) < accuracy)
        #expect(abs(rect.minY) < accuracy)
        #expect(abs(rect.width - 434.5) < accuracy)
        #expect(abs(rect.height - 512) < accuracy)
    }

    @Test("Vision y 向上 → 目标 y 向下：顶部行映射到目标上方（数值断言）")
    func visionYFlip() {
        let size = CGSize(width: 1000, height: 2000)
        let map = PageLayoutMapper.map(pageSize: size, targetSize: size)
        // Vision 归一化：y ∈ [0.75, 1] 是**页面上方 1/4** 的行
        let topQuarter = map.rect(CGRect(x: 0, y: 0.75, width: 1, height: 0.25))
        #expect(abs(topQuarter.minY) < accuracy)
        #expect(abs(topQuarter.height - 500) < accuracy)
        // y ∈ [0, 0.25] 是页面下方 1/4
        let bottomQuarter = map.rect(CGRect(x: 0, y: 0, width: 1, height: 0.25))
        #expect(abs(bottomQuarter.minY - 1500) < accuracy)
        #expect(abs(bottomQuarter.height - 500) < accuracy)
    }

    @Test("水平坐标不受 y 翻转影响")
    func xAxisIsLinear() {
        let size = CGSize(width: 800, height: 600)
        let map = PageLayoutMapper.map(pageSize: size, targetSize: size)
        let rect = map.rect(CGRect(x: 0.25, y: 0, width: 0.5, height: 1))
        #expect(abs(rect.minX - 200) < accuracy)
        #expect(abs(rect.width - 400) < accuracy)
    }

    @Test("flipsY=false：直接线性（无翻转），供已翻转过的调用方复用")
    func optionalFlipDisabled() {
        let size = CGSize(width: 1000, height: 2000)
        let map = PageLayoutMapper.map(pageSize: size, targetSize: size, flipsY: false)
        let rect = map.rect(CGRect(x: 0, y: 0.75, width: 1, height: 0.25))
        #expect(abs(rect.minY - 1500) < accuracy)
        #expect(abs(rect.height - 500) < accuracy)
    }

    // MARK: - 可逆（往返恒等）

    @Test("可逆：归一化框 → 目标 → 归一化，往返还原")
    func rectRoundTrip() {
        let map = PageLayoutMapper.map(pageSize: CGSize(width: 869, height: 1024), targetSize: CGSize(width: 1000, height: 750))
        let original = CGRect(x: 0.137, y: 0.222, width: 0.444, height: 0.333)
        let roundTrip = map.normalizedRect(map.rect(original))
        #expect(abs(roundTrip.minX - original.minX) < accuracy)
        #expect(abs(roundTrip.minY - original.minY) < accuracy)
        #expect(abs(roundTrip.width - original.width) < accuracy)
        #expect(abs(roundTrip.height - original.height) < accuracy)
    }

    @Test("可逆：点坐标往返（含 aspect-fit offset）")
    func pointRoundTripWithLetterbox() {
        let map = PageLayoutMapper.map(pageSize: CGSize(width: 2000, height: 100), targetSize: CGSize(width: 1000, height: 2000))
        let original = CGPoint(x: 0.31, y: 0.87)
        let roundTrip = map.normalizedPoint(map.point(original))
        #expect(abs(roundTrip.x - original.x) < accuracy)
        #expect(abs(roundTrip.y - original.y) < accuracy)
    }

    // MARK: - EMU 页尺寸（DOCX 动态 sectPr 用）

    @Test("像素 → EMU：1 px @96dpi = 9525 EMU（与 DocxExportService 既有约定一致）")
    func emuPageSizeMatchesDocxConvention() {
        let emu = PageLayoutMapper.emuPageSize(for: CGSize(width: 869, height: 1024))
        #expect(abs(emu.width - 8_277_225) < 0.5) // 869 × 9525
        #expect(abs(emu.height - 9_753_600) < 0.5) // 1024 × 9525
    }

    @Test("EMU 页尺寸：夹在 Word 最大页（22in = 20116800 EMU）内且保比例")
    func emuPageSizeClampsToWordMaximum() {
        // 4224 px = 44in @96dpi → 超限一倍，等比缩到 22in：4224→20116800、2112→10058400
        let emu = PageLayoutMapper.emuPageSize(for: CGSize(width: 4224, height: 2112))
        #expect(abs(emu.width - 20_116_800) < 0.5)
        #expect(abs(emu.height - 10_058_400) < 0.5)
    }

    @Test("EMU 页尺寸：恰好 22in 不触发缩放")
    func emuPageSizeAtLimitUnchanged() {
        let emu = PageLayoutMapper.emuPageSize(for: CGSize(width: 2112, height: 1056))
        #expect(abs(emu.width - 20_116_800) < 0.5)
        #expect(abs(emu.height - 10_058_400) < 0.5)
    }
}
