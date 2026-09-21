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
