import Testing
import CoreGraphics

@testable import Zhixia

/// OCR 噪声过滤（2026-09-07 真机回归）。
///
/// 真机产物里曾出现这些非文档内容被当正文导出：
/// `20:14C`（状态栏）、`<1to you更多`（导航栏）、`文本分享加页`（底部工具栏）、
/// `https://qrcode.5rs.me/...`（二维码，练习册里出现 3 次）。
struct OCRNoiseFilterTests {

    private func verdict(_ text: String, top: Bool = false, bottom: Bool = false) -> OCRNoiseFilter.Verdict {
        OCRNoiseFilter.verdict(
            for: text,
            context: .init(medianLineHeight: 0.02, isNearTopEdge: top, isNearBottomEdge: bottom)
        )
    }

    private func isKept(_ text: String, top: Bool = false, bottom: Bool = false) -> Bool {
        if case .keep = verdict(text, top: top, bottom: bottom) { return true }
        return false
    }

    @Test("状态栏「20:14C」要被丢掉")
    func statusBarIsDropped() {
        #expect(isKept("20:14C") == false)
        #expect(isKept("9:41") == false)
        #expect(isKept("20:14 5G") == false)
    }

    @Test("顶部导航栏「<1to you更多」要被丢掉")
    func topNavBarIsDropped() {
        #expect(isKept("<1to you更多", top: true) == false)
    }

    @Test("底部工具栏「文本分享加页」要被丢掉")
    func bottomToolbarIsDropped() {
        #expect(isKept("文本分享加页", bottom: true) == false)
    }

    @Test("二维码 URL 降级为链接块，而不是混进正文")
    func qrURLIsDemoted() {
        #expect(isKept("https://qrcode.5rs.me/B8vPhXfLxUMzVI2X") == false)
        if case .demoteToBarcode = verdict("https://qrcode.5rs.me/jP091jkTW5ZMTG6J") {
            // pass
        } else {
            Issue.record("URL 应被降级为 .demoteToBarcode")
        }
    }

    @Test("真实文档内容不能误杀")
    func realContentSurvives() {
        // 营养表表头
        #expect(isKept("项目"))
        #expect(isKept("每 100克"))
        #expect(isKept("NRV%"))
        // 中文长句（含「分享」二字但不在边缘、也不短 → 不能杀）
        #expect(isKept("本品适合全家分享食用"))
        // 生产日期 / 编号
        #expect(isKept("2026/07/15"))
        #expect(isKept("GB/T 10782"))
        // 练习册题干
        #expect(isKept("Question 1. What is Becky going to take for the picnic？"))
        #expect(isKept("Section 2. Dictation, listen to the radio and fill in the blanks."))
    }

    @Test("边缘长句不算 UI chrome")
    func longEdgeTextIsNotChrome() {
        // 靠边但太长 → 不是界面元素
        let long = "这一行虽然靠近页面顶部但内容明显是正文而不是界面按钮文案"
        #expect(isKept(long, top: true))
    }
}
