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

    /// 回归（2026-09-12 真机反馈）。
    ///
    /// 原判据是「去掉空格后同时含 `.` 和 `/` 就算 URL」，于是把练习册的
    /// **选项句**整条降级成条码块 —— 「A / B 选出正确形式」是教材/练习册的通用句式，
    /// 误伤面很大。而且被降级的行既不在正文里、又统一排在正文之后，正文顺序也跟着乱。
    ///
    /// 真 URL 的判据应该是**不含空白**（URL 里不会有空格，英文句子里到处是空格）。
    @Test("选项句里的斜杠不能被当成链接")
    func optionSlashIsNotAURL() {
        #expect(isKept("stopped / was stopping working."))
        #expect(isKept("later the sun came / was coming out."))
        #expect(isKept("I used to enjoy / was enjoying history when I was in"))
        #expect(isKept("7 The children made / were making so much noise in the"))
        #expect(isKept("while we used to shop / were shopping in the city"))
    }

    @Test("不含空格的裸域名仍然要被降级")
    func bareDomainStillDemoted() {
        for text in ["qrcode.5rs.me/B8vPhXfLxUMzVI2X", "www.example.com/a", "example.org/path"] {
            if case .demoteToBarcode = verdict(text) {
                // pass
            } else {
                Issue.record("\(text) 应被降级为 .demoteToBarcode")
            }
        }
    }

    // MARK: - wps-parity-layout T010（FR-005 页缘 chrome 收紧）

    @Test("拉丁界面词整词匹配：含 chrome 词的正文词不被误杀")
    func latinChromeWordsMatchWholeWordOnly() {
        // 旧子串规则："homework" 含 "home"、"saved" 含 "save" → 靠边短行被误杀。
        // `\b` 整词边界下它们是正文，不是 UI 按钮。
        #expect(isKept("homework", top: true))
        #expect(isKept("saved", bottom: true))
        #expect(isKept("homework.", top: true), "句末标点再兜一层")
    }

    @Test("句末标点守卫：带标点的靠边短行按正文处理")
    func punctuatedShortEdgeLineIsContent() {
        // "wrong bus!" = 10 字符踩线教训的一致化：界面按钮文案不带句末标点，
        // 正文短句带。旧规则下这两条都会被当 UI chrome 丢掉。
        #expect(isKept("Done!", top: true))
        #expect(isKept("保存成功。", bottom: true))
    }

    @Test("真 UI chrome 仍然被丢：无标点的短标签")
    func realChromeStillDropped() {
        #expect(isKept("done", top: true) == false)
        #expect(isKept("back", top: true) == false)
        // CJK 保持子串语义（「文本分享加页」式拼接文案）
        #expect(isKept("分享好物", bottom: true) == false)
    }

    @Test("句末标点判定（页眉规则与 chrome 规则共用的判据）")
    func sentencePunctuationDetector() {
        #expect(OCRNoiseFilter.endsWithSentencePunctuation("wrong bus!"))
        #expect(OCRNoiseFilter.endsWithSentencePunctuation("稍等。"))
        #expect(OCRNoiseFilter.endsWithSentencePunctuation("wait? "), "尾随空白先 trim")
        #expect(OCRNoiseFilter.endsWithSentencePunctuation("真的吗…"))
        #expect(!OCRNoiseFilter.endsWithSentencePunctuation("Test 4"))
        #expect(!OCRNoiseFilter.endsWithSentencePunctuation("done"))
        #expect(!OCRNoiseFilter.endsWithSentencePunctuation(""))
    }
}
