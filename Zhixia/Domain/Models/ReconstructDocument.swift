import CoreGraphics
import Foundation

enum ReconstructScene: String, Sendable, Codable, Equatable, Hashable, CaseIterable {
    case auto
    case plain
    case exam
    case table
    case packaging
}

enum ReconstructBlockKind: String, Sendable, Codable, Equatable, Hashable {
    case heading
    case paragraph
    case list
    case table
    case figure
    case barcode
    case checkbox
    case handwrittenBlank
    /// 版面还原档（spec/layout-restore plan D2/D4）：无法准确识别为纯文本的保留区域
    /// （艺术字/手绘字/图画/图章）。无文本、无独立裁图——预览与 DOCX 都靠**底座原像素**
    /// 透出（srcRect / 不进覆盖 mask），乱码文本行已从文字层剔除。
    case artwork
}

enum ReconstructAlignment: String, Sendable, Codable, Equatable {
    case leading
    case center
    case trailing
}

struct ReconstructStyle: Sendable, Equatable, Codable, Hashable {
    var relativeFontSize: Double
    var isBold: Bool
    var alignment: ReconstructAlignment

    static let body = ReconstructStyle(relativeFontSize: 1, isBold: false, alignment: .leading)
    static let heading = ReconstructStyle(relativeFontSize: 1.4, isBold: true, alignment: .leading)
}

struct ReconstructTable: Sendable, Equatable, Codable, Hashable {
    var rows: [[String]]
    /// 实测列宽比例（spec/layout-engine plan D8，结构化识别通路产出，和 = 1）。
    /// nil = 几何回退通路（无列信息）→ 渲染端均分兜底。Optional 默认 nil，旧数据零破坏。
    var columnRatios: [Double]? = nil

    var columnCount: Int {
        rows.map(\.count).max() ?? 0
    }
}

/// 行内分段（spec/scan-fidelity T002 / FR-005）：同行多段 OCR 碎片的水平几何，
/// 预览分段定位渲染（T013）与 DOCX 多 run 下划线占位（T012）共用的数据载体。
/// 坐标为归一化页宽比例，与 `BlockLine.leadingOffset` 同基准（块相对 minX）。
struct LineSegment: Sendable, Equatable, Codable, Hashable {
    /// 分段文本
    var text: String
    /// 分段左缘 = 分段 minX − 块 minX（归一化页宽比例）
    var offset: Double
    /// 分段水平延伸 = 分段 maxX − 分段 minX（归一化页宽比例）
    var width: Double

    init(text: String, offset: Double, width: Double) {
        self.text = text
        self.offset = offset
        self.width = width
    }
}

/// 块内单行几何（spec/layout-engine plan D3/D7）：随块上 IR 的实测行几何，
/// 预览逐行定位与 Word 每行一段共用的数据载体。坐标全归一化（与 bbox 同基准）。
struct BlockLine: Sendable, Equatable, Codable, Hashable {
    /// 该行文本（来自既有 Row.lines join 产物，拼接规则不变——T005 只附加几何）
    var text: String
    /// 实测行高（归一化）
    var height: Double
    /// 与上一行的间距（块首行 = 0；归一化）
    var gapToPrevious: Double
    /// 行首偏移 = 行 minX − 块 minX（归一化）
    var leadingOffset: Double
    /// 行水平延伸 = 行 maxX − 行 minX（归一化）。plan D3 四字段之外的实施期增补：
    /// 引擎「成员行 midX 双峰」跨栏拆分（plan D2②）需要行水平中点
    /// midX = leadingOffset + width / 2，且溢出换行估算需要行宽——无此字段两者皆不可算。
    var width: Double
    /// 行内分段（spec/scan-fidelity T002 / FR-005）：nil = 无分段信息（旧数据 /
    /// 单段行）→ 渲染端走整行文本路径，行为不变；非 nil 时按段定位渲染 +
    /// 空隙下划线占位。Codable 旧档缺键 → `decodeIfPresent` → nil，零破坏。
    var segments: [LineSegment]?

    init(
        text: String,
        height: Double,
        gapToPrevious: Double,
        leadingOffset: Double,
        width: Double,
        segments: [LineSegment]? = nil
    ) {
        self.text = text
        self.height = height
        self.gapToPrevious = gapToPrevious
        self.leadingOffset = leadingOffset
        self.width = width
        self.segments = segments
    }
}

struct ReconstructBlock: Identifiable, Sendable, Equatable, Codable, Hashable {
    var id: UUID
    var kind: ReconstructBlockKind
    var bbox: CGRect
    var text: String
    var style: ReconstructStyle
    var table: ReconstructTable?
    var figureRelativePath: String?
    var barcodePayload: String?
    var isChecked: Bool?
    // IR v2 新增（2026-09-07）：语义标签 / 锚点 / 置信度。
    // 旧调用方不传这些字段也能编译；现有解析器只填 text/table/path 时这些字段保持默认。
    var semantic: ReconstructSemanticTag?
    var anchors: [LayoutAnchor]
    var confidence: Double
    // 版面布局引擎（spec/layout-engine plan D3）：块内行几何 + 块级实测中位行高。
    // 全 Optional 默认 nil：旧持久化数据 / 既有夹具 / 既有测试零破坏；
    // lines 为 nil 的块在两渲染端回退现有整块单段路径（行为不劣化）。
    var lines: [BlockLine]?
    var measuredLineHeight: Double?

    init(
        id: UUID = UUID(),
        kind: ReconstructBlockKind,
        bbox: CGRect,
        text: String,
        style: ReconstructStyle = .body,
        table: ReconstructTable? = nil,
        figureRelativePath: String? = nil,
        barcodePayload: String? = nil,
        isChecked: Bool? = nil,
        semantic: ReconstructSemanticTag? = nil,
        anchors: [LayoutAnchor] = [],
        confidence: Double = 1,
        lines: [BlockLine]? = nil,
        measuredLineHeight: Double? = nil
    ) {
        self.id = id
        self.kind = kind
        self.bbox = bbox
        self.text = text
        self.style = style
        self.table = table
        self.figureRelativePath = figureRelativePath
        self.barcodePayload = barcodePayload
        self.isChecked = isChecked
        self.semantic = semantic
        self.anchors = anchors
        self.confidence = confidence
        self.lines = lines
        self.measuredLineHeight = measuredLineHeight
    }

    var displayText: String {
        if kind == .table, let table {
            return table.rows.map { $0.joined(separator: "\t") }.joined(separator: "\n")
        }
        return text
    }

    var hasContent: Bool {
        switch kind {
        case .figure:
            if let figureRelativePath, FileManager.default.fileExists(atPath: figureRelativePath) {
                return true
            }
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .barcode:
            return true
        case .artwork:
            // 版面还原档的保留区域：无独立裁图（底座透出），区域本身即内容。
            return !bbox.isEmpty
        case .table:
            return table.map { !$0.rows.isEmpty } ?? false
        default:
            return !displayText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}

struct ReconstructPage: Sendable, Equatable, Codable, Hashable {
    var pageID: UUID
    var size: CGSize
    var scene: ReconstructScene
    var usedCloud: Bool
    var blocks: [ReconstructBlock]
    // IR v2 新增（2026-09-07）：M1 的版面分析产物。Optional，向后兼容。
    var layout: PageLayout?
    // 该页上所有块的锚点汇总（block.anchors 的扁平视图）。
    var anchors: [LayoutAnchor]
    /// 版面还原档的**底座**（spec/layout-restore plan D2）：矫正+增强后的整页 rendered 图
    /// 在 `PageFileStore` 下的相对路径（与预览衬底同源）。nil = 无底座，画布退化纯白底渲染。
    /// IR 从不编码落盘，新增字段无持久化兼容问题。
    var baseImageRelativePath: String?
    /// 版面还原档的**布局后块集**（spec/layout-engine plan D1/D3，FR-012）：
    /// 区域布局引擎（跨栏拆分 / 碰撞消解 / 溢出扩展）的输出。nil = 无引擎产物（旧数据）
    /// → 退化用 blocks。版面还原档渲染与 mask 消费 `restoredBlocks ?? blocks`；
    /// 结构化档恒读 blocks——拆分与位移对结构化档零扰动（双档隔离铁律）。
    var restoredBlocks: [ReconstructBlock]?

    init(
        pageID: UUID,
        size: CGSize,
        scene: ReconstructScene,
        usedCloud: Bool,
        blocks: [ReconstructBlock],
        layout: PageLayout? = nil,
        anchors: [LayoutAnchor] = [],
        baseImageRelativePath: String? = nil,
        restoredBlocks: [ReconstructBlock]? = nil
    ) {
        self.pageID = pageID
        self.size = size
        self.scene = scene
        self.usedCloud = usedCloud
        self.blocks = blocks
        self.layout = layout
        self.anchors = anchors
        self.baseImageRelativePath = baseImageRelativePath
        self.restoredBlocks = restoredBlocks
    }

    var hasContent: Bool {
        blocks.contains { $0.hasContent }
    }

    var hasLocalTable: Bool {
        blocks.contains { $0.kind == .table && ($0.table?.rows.isEmpty == false) }
    }

    var hasLocalFigure: Bool {
        blocks.contains { $0.kind == .figure || $0.kind == .barcode || $0.kind == .artwork }
    }
}

struct ReconstructDocument: Sendable, Equatable, Codable, Hashable {
    var documentID: UUID
    var title: String
    var pages: [ReconstructPage]
    // IR v2 新增（2026-09-07）。=1 = 老格式（默认）；=2 = 携带 PageLayout / anchors / semantic。
    var version: Int

    init(
        documentID: UUID,
        title: String,
        pages: [ReconstructPage],
        version: Int = 2
    ) {
        self.documentID = documentID
        self.title = title
        self.pages = pages
        self.version = version
    }

    var hasContent: Bool {
        pages.contains { $0.hasContent }
    }

    var needsCloudParsing: Bool {
        pages.contains { page in
            switch page.scene {
            case .table:
                return !page.hasLocalTable
            case .exam:
                return !page.hasLocalFigure
            case .packaging:
                return !page.hasLocalTable && !page.hasLocalFigure
            default:
                return false
            }
        }
    }
}

// MARK: - 导出档位（用户面语义，spec/wps-parity-layout plan D1 / FR-001、FR-009）

/// 导出档位的**用户面**语义（spec/wps-parity-layout plan D1；spec/word-fidelity T004）。
///
/// 内部 `R2OutputTier` 枚举命名保留（pageImage/restored/structured），用户面语义：
/// - `pageImage`（**高保真**·图片版，**默认**）：整页增强图铺满页面 —— 即现 `.pageImage` 产物。
///   WPS 实测（docs/16 §二）：竞品的「扫描件 → Word」产物**就是页面本身**；
/// - `layoutEditable`（版面还原·可编辑）：底图 + 遮罩 + 文本框原位重排 —— 即现 `.restored` 产物。
///   **实测保真度不达标**（SSIM 0.767 vs 门限 0.90，docs/16 §五）——文本框与底图
///   叠字、错位；保留为「可编辑 + 版面」选项，迭代见 spec/word-fidelity T010；
/// - `flow`（流式·可编辑）：阅读序段落流 + 内联图 + 原生表格 —— 即现 `.structured` 产物。
///
/// ## 命名迁移（2026-10-22）
/// 旧版本把「高保真」这个名字给了**可编辑的版面还原**档（`rawValue == "highFidelity"`），
/// 而真正「看起来就是原页」的是新增的图片版档。名字按直觉重新分配后：
/// - 旧持久化值 `"highFidelity"` → 迁移到 `layoutEditable`（**行为不变**，只是显示名变了）；
/// - 图片版用新 rawValue `"pageImage"`，显示名「高保真」。
///
/// 档位同时作用于预览渲染与导出产物（预览/导出同源，FR-009）；用户选择经
/// `ExportTier.preferenceKey` 持久化，未设置/非法值一律回退默认档（FR-001）。
enum ExportTier: String, Sendable, Codable, CaseIterable, Equatable, Hashable {
    /// 流式（可编辑）：段落流重排。
    case flow
    /// 版面还原（可编辑）：底图 + 遮罩 + 文本框原位重排。
    ///
    /// 旧 rawValue `"highFidelity"`（旧版把「高保真」这个名字给了本档）由
    /// `init(persistedRawValue:)` 迁移过来 → 老用户的选择**行为不变**。
    case layoutEditable
    /// **图片版**（spec/word-fidelity T002 / FR-002）：整页增强图铺满页面。
    ///
    /// WPS 实测（`docs/media/3ca8ce818cf785798a1661a3eef67730.mp4`，docs/16 §二）：
    /// 「扫描件 → 导出 Word」的产物**就是页面本身**（导出预览渲染页面图、
    /// 文档提示「只读」），可编辑文字是另一个独立动作（提取文字）。本档位与之
    /// 对齐，并把「样式乱掉」从根上消掉（没有浮动文本框可乱）。
    case pageImage

    /// 档位偏好持久化键（@AppStorage / UserDefaults，命名对齐 `PreferencesStore.Key`）。
    static let preferenceKey = "zhixia.reconstruct.exportTier"

    /// 默认档 = **图片版**（spec/word-fidelity plan D2 / FR-002）。
    ///
    /// 依据：① WPS 的 Word 导出实测就是页面图（docs/16 §二）；② 用户实测反馈
    /// 「稍微复杂一点的图片内容，最后生成 word 的样式会乱掉」（docs/16 §一）——
    /// 浮点重建在复杂页面上不可靠，图片版不可能乱；③ 文字检索由 App 自身的
    /// OCR 索引承担（`applyOCRBlob`），不依赖 Word 里的可编辑文字。
    /// 可编辑两档（流式 / 版面还原）仍在设置里一键切换。
    static let defaultTier: ExportTier = .pageImage

    /// 从持久化原始值还原档位；未设置/非法值回退默认档（老版本数据零破坏）。
    ///
    /// 迁移：旧版 rawValue `"highFidelity"`（= 旧的可编辑版面还原档）→ `layoutEditable`。
    init(persistedRawValue: String?) {
        guard let raw = persistedRawValue else {
            self = ExportTier.defaultTier
            return
        }
        if raw == "highFidelity" {
            self = .layoutEditable
            return
        }
        self = ExportTier(rawValue: raw) ?? ExportTier.defaultTier
    }

    /// 映射内部导出档位（协议层 `R2OutputTier`，导出调用点消费）。
    var outputTier: R2OutputTier {
        switch self {
        case .flow: .structured
        case .layoutEditable: .restored
        case .pageImage: .pageImage
        }
    }

    /// 反向映射（wps-parity-layout US5 / T020：UI 层持久化用）—— 内部导出
    /// 档位 → 用户档位。与 `outputTier` 互逆，`ExportTier(outputTier:).outputTier == self`。
    init(outputTier: R2OutputTier) {
        switch outputTier {
        case .structured: self = .flow
        case .restored: self = .layoutEditable
        case .pageImage: self = .pageImage
        }
    }

    /// 档位显示名（双语，Localizable.xcstrings `reconstruct.tier.flow` /
    /// `reconstruct.tier.layoutEditable` / `reconstruct.tier.pageImage`）。
    /// `Text(String)` 是 verbatim 渲染，
    /// 本地化必须在这里发生（与 `R2OutputTier.displayName` 同模式）。
    var displayName: String {
        switch self {
        case .flow: return String(localized: "reconstruct.tier.flow")
        case .layoutEditable: return String(localized: "reconstruct.tier.layoutEditable")
        case .pageImage: return String(localized: "reconstruct.tier.pageImage")
        }
    }
}

// MARK: - 墨迹-文本对账类型（spec/wps-parity-layout plan D5 / FR-006 / T012）

/// 对账缺口的原因分类（plan D5）。
enum InkGapCategory: String, Sendable, Codable, CaseIterable, Equatable, Hashable {
    /// 图形区（figure/artwork 块 bbox）内的墨 —— 预期，不是丢字。
    case figureOverlap
    /// 结构（表格/条码块 bbox）吞噬的墨 —— 归因给结构；其携带文本由解析期
    /// containment 不变量（T009 `splitCarriedLines`）保障，违规在那边计数。
    case structureSwallow
    /// 页缘带（页眉/页脚/系统 chrome）的墨 —— 预期噪声。
    case edgeBand
    /// 无文字覆盖、无结构归因、不在页缘 —— **疑似 OCR 漏识**，
    /// 丢字哨兵（FR-006）的核心证据类。
    case likelyMissed
}

/// 单个墨迹缺口（plan「InkGap」）：归一化矩形 + 面积占比 + 原因分类。
struct InkGap: Sendable, Equatable, Codable, Hashable {
    /// 墨迹区域外接框（Vision 归一化，原点左下）。
    var frame: CGRect
    /// 面积占比 = width × height（页面 = 1×1）。
    var areaFraction: Double
    var category: InkGapCategory

    init(frame: CGRect, category: InkGapCategory) {
        self.frame = frame
        self.areaFraction = Double(frame.width) * Double(frame.height)
        self.category = category
    }
}

/// 一页的墨迹-文本对账报告（FR-006：只记不阻断导出）。
/// 由 `InkTextReconciler` 纯函数产出，`ZhixiaLog.textSentinel` 消费汇总计数。
struct MissingTextReport: Sendable, Equatable, Codable, Hashable {
    /// 全部缺口（含预期类 figureOverlap/structureSwallow/edgeBand），
    /// 保持墨迹区域输入序。
    var gaps: [InkGap]

    init(gaps: [InkGap] = []) {
        self.gaps = gaps
    }

    var isEmpty: Bool { gaps.isEmpty }

    /// 指定分类的缺口数。
    func count(of category: InkGapCategory) -> Int {
        gaps.lazy.filter { $0.category == category }.count
    }

    /// 疑似漏识缺口（哨兵核心证据），按面积降序 —— 排查丢字先看这里。
    var likelyMissedGaps: [InkGap] {
        gaps.filter { $0.category == .likelyMissed }
            .sorted { $0.areaFraction > $1.areaFraction }
    }
}
