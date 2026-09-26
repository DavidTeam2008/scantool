import Foundation

/// OCR 噪声过滤（docs/07 §6.1 补丁 · 2026-09-07 真机回归）。
///
/// ## 为什么需要它
/// 真机产物里混进了大量**非文档内容**：
/// ```
/// 20:14C                              ← iOS 状态栏（时间 + 电量）
/// <1to you更多                         ← App 导航栏
/// 文本分享加页                          ← App 底部工具栏
/// https://qrcode.5rs.me/B8vPhXfLxUMzVI2X  ← 二维码内容（×3）
/// ```
/// 用户扫描的原图常常是「对着另一块屏幕拍的截图」，或者照片带了 UI 边框。
/// Vision 会忠实地把这些都识别成文本，于是一股脑进正文 —— 这是「和扫描王差太多」
/// 最直观的一条：扫描王会先裁掉非文档区域。
///
/// ## 设计原则
/// - **只降级，不静默丢弃**（URL 除外）。误杀真实内容比漏掉噪声更糟。
/// - 判定必须**多条件 AND**：孤立 + 短 + 靠边。单靠关键词会在英文文档上误伤。
/// - 坐标一律用 Vision 归一化坐标（原点左下，y 向上），与 `OCRLine` 一致。
enum OCRNoiseFilter {

    /// 一条 OCR 行的处置结果。
    enum Verdict {
        /// 正常内容，走常规阅读顺序。
        case keep
        /// 噪声，直接丢弃（状态栏 / UI 工具栏）。
        case drop
        /// 有价值但不是正文：改成链接/条码类块，单独呈现。
        case demoteToBarcode
    }

    struct Context {
        /// 该行的行高（用于判断「短」）。
        var medianLineHeight: CGFloat = 0.02
        /// 是否位于页面顶部/底部边缘条带（Vision 坐标：y 越接近 1 越靠上）。
        var isNearTopEdge: Bool = false
        var isNearBottomEdge: Bool = false
    }

    static func verdict(for text: String, context: Context) -> Verdict {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .drop }

        // 1. URL / 二维码内容 → 降级（不是正文句子，但可能是有用的链接）
        if looksLikeURL(trimmed) { return .demoteToBarcode }

        // 2. 状态栏：HH:MM 开头且整体很短（"20:14C"、"9:41 "）
        if looksLikeStatusBar(trimmed) { return .drop }

        // 3. UI chrome：靠边 + 短 + 命中界面词。
        //    T010（wps-parity-layout FR-005）复核收紧两处：
        //    a) 句末带标点的短行按正文处理 —— 界面按钮文案不带句号/叹号，
        //       正文短句带（"wrong bus!" = 10 字符踩线教训的一致化）；
        //    b) 拉丁界面词改整词匹配（见 `looksLikeUIChrome`）。
        if (context.isNearTopEdge || context.isNearBottomEdge),
           trimmed.count <= 12,
           !Self.endsWithSentencePunctuation(trimmed),
           looksLikeUIChrome(trimmed) {
            return .drop
        }

        return .keep
    }

    /// 句末标点判定（wps-parity-layout FR-005）：正文短句带句末标点，
    /// UI 标签 / 页眉不带。短不短不可靠（"wrong bus!" 恰好 10 字符踩线），
    /// 像不像句子更可靠 —— 页眉短行规则与页缘 chrome 规则共用的兜底判据。
    static func endsWithSentencePunctuation(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return false }
        return ".!?。！？…".contains(last)
    }

    // MARK: - 判定

    private static func looksLikeURL(_ text: String) -> Bool {
        let lower = text.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") { return true }
        if lower.hasPrefix("www.") { return true }

        // 短域名形态：qrcode.5rs.me/B8vPhXfLxUMzVI2X
        //
        // ⚠️ 真机反馈（2026-09-12）：这里原本是「去掉空格后同时含 `.` 和 `/`」就算 URL，
        // 于是把练习册的选项句 `stopped / was stopping working.` 误判成链接、降级成条码块 ——
        // 「A / B 选出正确形式」是教材/练习册的**通用句式**，误伤面很大，
        // 而且降级后这些行既不在正文里、又排在正文之后，正文顺序也跟着乱。
        //
        // 真正的判据是**不含空白**：URL 里不会有空格，而英文句子里到处是空格。
        // 再叠加一个域名形态检查（`xxx.yy/`）做第二道闸。
        guard text.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return false }
        let compact = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard compact.count >= 8, compact.count <= 120 else { return false }
        guard compact.contains("/") else { return false }
        guard compact.range(
            of: #"[A-Za-z0-9][A-Za-z0-9-]*\.[A-Za-z]{2,6}(/|$)"#,
            options: .regularExpression
        ) != nil else {
            return false
        }
        // 不能含 CJK，否则是中文句子
        return !compact.contains { ch in
            (ch.unicodeScalars.first?.value ?? 0) > 0x2E80
        }
    }

    private static func looksLikeStatusBar(_ text: String) -> Bool {
        // "20:14"、"9:41"、"20:14C"、"20:14 5G"
        let pattern = #"^\d{1,2}:\d{2}\s*[A-Za-z0-9%]{0,3}$"#
        return text.range(of: pattern, options: .regularExpression) != nil
    }

    /// CJK 界面词（子串命中）。刻意保持短表 —— 宁可漏，不要误杀正文。
    private static let cjkChromeWords = [
        "更多", "分享", "加页", "收藏", "返回", "首页", "我的", "设置", "搜索",
        "完成", "取消", "保存", "编辑", "全选", "下一页", "上一页"
    ]

    /// 拉丁界面词（整词命中）。与 CJK 分列是因为匹配语义不同：
    /// T010（FR-005）复核发现子串匹配会误杀正文 —— "homework" 含 "home"、
    /// "moreover" 含 "more"、"saved" 含 "save"；`\b` 整词边界消除这类误伤，
    /// 真正的 UI 文案（"back"、"done"）不受影响。
    private static let latinChromeWords = [
        "back", "share", "more", "done", "cancel", "save", "edit", "home"
    ]

    private static func looksLikeUIChrome(_ text: String) -> Bool {
        let lower = text.lowercased()
        // CJK：子串命中（中文 UI 文案常是多词拼接，如「文本分享加页」里的「分享」「加页」）。
        if cjkChromeWords.contains(where: { lower.contains($0) }) { return true }
        // 拉丁：整词命中（\b 边界，"homework" ≠ "home"）。
        for word in latinChromeWords {
            if lower.range(of: "\\b\(word)\\b", options: .regularExpression) != nil {
                return true
            }
        }
        // 导航箭头 + 短串，如 "<1to you更多"、"〈 详情"
        if text.count <= 10, text.contains("<") || text.contains("〈") || text.contains("‹") {
            return true
        }
        return false
    }
}
