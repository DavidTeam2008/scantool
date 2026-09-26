import Foundation

/// 流式档段落切分（wps-parity-layout US4 / T018 / FR「导出文本的段落粒度对齐 WPS」）。
///
/// ## 为什么在导出侧而不是 `clusterParagraphs`
///
/// `clusterParagraphs` 的块级合并粒度是被钉住的**刻意粗粒度**：对话区 4 视觉行
/// 一整块是 scan-fidelity T014/T015 的断言基准（`DialogueRowFixture`），块序还是
/// `assemble` 按 maxY 装配的输入（拆块会改变 figure 与文本块的相对序，漫画条
/// 内联的阅读序原位随之漂移）。而金标准对照（42 段量级）证明这个粒度直接导出
/// 太粗——左栏 41 行一整块。**块不动，段落在导出侧细化**：块内 `BlockLine`
/// （text / leadingOffset）携带全部所需信号，spec FR 的落点本来就是「导出文本」
/// 的段落粒度（2026-09-21 取证的 83 段也是导出侧计数）。
///
/// ## 切分判据（2026-09-23 金标准取证，/tmp/probe-default-rows.txt 逐点对齐）
///
/// - **条目号起始**：行文本以 1~2 位数字 + 分隔符（`.`/`、`/空白）开头
///   （"1 I used to…"、"2 A: My sister…"）→ 该行起段。两位上限避开年份
///   （"2010 年"不切）；金标准第 2 节条目 3~8 的行间距只有 0.002~0.006，
///   行首回撤（0.054→0.027）与条目号是仅有的两个信号，条号更稳。
/// - **行首回撤**：行首偏移比上一行左移超过阈值 → 该行起段。对话轮换
///   （续行 0.076 → 轮首 0.052，回撤 0.022~0.027）与节标题（0.052 → 0.000）
///   的信号；OCR 行首抖动 ≤ 0.006，阈值 0.012 留 2 倍裕度。
/// - **前句完结**：上一行以句末标点收尾（复用 `OCRNoiseFilter` 同口径，
///   `.!?。！？…`）→ 当前行起段。故事块的句界信号（"…to go to school."、
///   "…sat down."）；金标准故事区本身就被 WPS 按行切成 13 段（行渲染产物），
///   句界切分是语义上站得住的近似。
///
/// ## 不变量
///
/// - 无 `lines` 的块（旧持久化 / 既有夹具 / 旧测试）恒等返回 `[block.text]`
///   ——导出字节与改造前完全一致；
/// - 组文本按 "\n" 连接后与 `block.text` 不一致时同样回退整块单段
///   （防御任何 text/lines 失配的生产方），**文本零丢失**只改分组；
/// - 只在块内切分，不动块序 / 块几何——2026-09-12 教材行距错序教训的
///   红线（排序行为）在构造上就不可能被触碰。
enum FlowParagraphSplitter {
    /// 行首回撤阈值（归一化页宽）：金标准轮换回撤 0.022~0.027、抖动 ≤ 0.006。
    static let leadRetreatThreshold: Double = 0.012

    /// 把文本块切成流式档的分段组文本（组内行以 "\n" 连接，与块文本口径一致，
    /// `paragraphXML` 对 "\n" 的 w:br 处理不变）。
    static func paragraphTexts(in block: ReconstructBlock) -> [String] {
        guard let lines = block.lines, lines.count > 1 else {
            return [block.text]
        }
        var groups: [[BlockLine]] = [[lines[0]]]
        for index in 1..<lines.count {
            if startsParagraph(lines[index], after: lines[index - 1]) {
                groups.append([lines[index]])
            } else {
                groups[groups.count - 1].append(lines[index])
            }
        }
        let texts = groups.map { $0.map(\.text).joined(separator: "\n") }
        // 防御：分组拼回应与块文本一致（生产方 text/lines 失配时回退旧行为）。
        guard texts.joined(separator: "\n") == block.text else {
            return [block.text]
        }
        return texts
    }

    /// 三判据任一命中即起段（顺序：条目号 → 行首回撤 → 前句完结）。
    private static func startsParagraph(_ current: BlockLine, after previous: BlockLine) -> Bool {
        if hasItemMarker(current.text) { return true }
        if previous.leadingOffset - current.leadingOffset > leadRetreatThreshold { return true }
        return OCRNoiseFilter.endsWithSentencePunctuation(previous.text)
    }

    /// 行首条目号："1 I used to…" / "2 A:…" / "3、…"；"2010 年"这类年份不命中。
    private static func hasItemMarker(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.range(of: #"^\d{1,2}[\.\、\s]"#, options: .regularExpression) != nil
    }
}
