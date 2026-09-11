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

    var columnCount: Int {
        rows.map(\.count).max() ?? 0
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
        confidence: Double = 1
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

    init(
        pageID: UUID,
        size: CGSize,
        scene: ReconstructScene,
        usedCloud: Bool,
        blocks: [ReconstructBlock],
        layout: PageLayout? = nil,
        anchors: [LayoutAnchor] = []
    ) {
        self.pageID = pageID
        self.size = size
        self.scene = scene
        self.usedCloud = usedCloud
        self.blocks = blocks
        self.layout = layout
        self.anchors = anchors
    }

    var hasContent: Bool {
        blocks.contains { $0.hasContent }
    }

    var hasLocalTable: Bool {
        blocks.contains { $0.kind == .table && ($0.table?.rows.isEmpty == false) }
    }

    var hasLocalFigure: Bool {
        blocks.contains { $0.kind == .figure || $0.kind == .barcode }
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
