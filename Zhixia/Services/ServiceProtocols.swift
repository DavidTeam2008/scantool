import CoreGraphics
import Foundation

struct VideoFrame: @unchecked Sendable {
    let cgImage: CGImage
    let timestamp: TimeInterval
}

struct CapturedPhoto: Sendable {
    let jpegData: Data
    let pixelSize: CGSize
}

enum PageFileKind: String, Sendable {
    case original
    case rendered
    case thumbnail
}

enum CameraAuthorization: Sendable, Equatable {
    case authorized
    case denied
    case notDetermined
}

/// 「照片空间 → 屏幕」的实测线性映射（plan D3）：预览层探针用全幅矩形标定出的
/// 逐轴缩放与偏移。照片空间归一化点 (x, y) ↦ `(x·scaleX + offsetX, y·scaleY + offsetY)`。
///
/// 由 `CameraPreviewAttaching.overlayTransform(forViewSize:)` 产出；**T022 起
/// 仅作诊断对照**（渲染真值 = `OverlaySpaceMap` 解析链，SC-004 比对证据）。
/// 轻量值类型，随协议定义（plan「Contracts」）。
struct QuadSpaceTransform: Sendable, Equatable {
    var scaleX: CGFloat
    var scaleY: CGFloat
    var offsetX: CGFloat
    var offsetY: CGFloat

    init(scaleX: CGFloat, scaleY: CGFloat, offsetX: CGFloat, offsetY: CGFloat) {
        self.scaleX = scaleX
        self.scaleY = scaleY
        self.offsetX = offsetX
        self.offsetY = offsetY
    }

    /// 照片空间归一化点 → 屏幕坐标。
    func apply(to point: CGPoint) -> CGPoint {
        CGPoint(x: point.x * scaleX + offsetX, y: point.y * scaleY + offsetY)
    }

    /// 照片空间四边形 → 屏幕坐标四边形。
    func apply(to quad: Quad) -> Quad {
        Quad(
            topLeft: apply(to: quad.topLeft),
            topRight: apply(to: quad.topRight),
            bottomRight: apply(to: quad.bottomRight),
            bottomLeft: apply(to: quad.bottomLeft)
        )
    }
}

protocol CameraCapturing: Sendable {
    func start() async throws
    func stop() async
    func capturePhoto() async throws -> CapturedPhoto
    func setTorch(enabled: Bool) async throws
    func setFlashAuto(_ enabled: Bool) async
    var frames: AsyncStream<VideoFrame> { get }
    /// 运行时测量的取景几何（plan D2）：视频流帧与照片输出的竖屏宽高比。
    /// 未配置会话时返回 `CaptureGeometry.identity`（恒等换算，调用方不崩溃、不变形）。
    func geometry() async -> CaptureGeometry
}

@MainActor
protocol CameraPreviewAttaching: AnyObject {
    func attachPreview(to layer: AnyObject)
    /// 「照片空间 → 该视图尺寸屏幕坐标」的实测映射（plan D3，FR-006）。
    /// **T022 起降级为诊断对照源**：overlay 渲染真值改走解析链（`OverlaySpaceMap`），
    /// 本探针仅用于输出与解析式值的比对日志（`ZhixiaLog.overlayProbeAnalytic`，
    /// SC-004 证据链）。基于预览层实际显示的视野标定；无有效预览层
    ///（未 attach / 无连接 / 尺寸非法）时返回 nil。
    func overlayTransform(forViewSize: CGSize) -> QuadSpaceTransform?
}

protocol EdgeDetecting: Sendable {
    func detect(frame: VideoFrame, idCardWindow: Quad?) async -> Quad?
    func detect(imageData: Data, idCardWindow: Quad?) async -> Quad?
}

protocol PerspectiveCorrecting: Sendable {
    func correct(original: URL, quad: Quad, rotationTurns: Int) async throws -> Data
}

protocol Enhancing: Sendable {
    func apply(imageData: Data, enhancement: Enhancement) async throws -> Data
}

protocol Thumbnailing: Sendable {
    func makeThumbnail(imageData: Data, maxWidth: CGFloat) async throws -> Data
}

protocol ImageRendering: Sendable {
    func renderPage(original: URL, draft: PageDraft) async throws -> RenderedPageData
}

struct RenderedPageData: Sendable {
    var jpeg: Data
    var thumbnail: Data
    var pixelSize: CGSize
}

protocol TextRecognizing: Sendable {
    func recognize(imageURL: URL, pageID: UUID) async throws -> OCRPageText
}

protocol DocumentParsing: Sendable {
    func parse(imageURL: URL, pageID: UUID, scene: ReconstructScene) async throws -> ReconstructPage
}

/// 结构化文档识别（iOS 26 的 `RecognizeDocumentsRequest`）。
///
/// 与 `TextRecognizing` 的关键差别：它**直接给表格的行列结构**，不需要「按 OCR 行的 midX
/// 聚类推列」——后者在真机上已被证伪（Vision 只给 line 级 bbox，真机常把整行单元格合并成一行，
/// 见 docs/08 §2.3 / docs/09 §6.2/§6.3）。这是目前唯一能根治「真机 `w:tbl = 0`」的通路。
///
/// 契约：**系统不支持、识别不出结构、或抛错时一律返回 `nil`**，绝不 throw 给调用方。
/// 调用方（`OnDeviceDocumentParser`）必须准备好回退到几何管线 —— 在 iOS 18/25 上它恒为 nil。
protocol DocumentStructureRecognizing: Sendable {
    func recognize(imageURL: URL, pageID: UUID) async -> StructuredDocumentPage?
}

protocol ReconstructRepairing: Sendable {
    func repair(imageURL: URL, page: ReconstructPage, failures: [UUID]) async throws -> ReconstructPage
}

protocol DocxRendering: Sendable {
    func makeDocx(_ document: ReconstructDocument, fileName: String, tier: R2OutputTier) async throws -> URL
}

/// DOCX 导出档位（spec/layout-restore plan D1/D8）。
/// - `restored`（版面还原，默认）：整页原图统一底座 + 块级覆盖 mask + 元素原位渲染；
///   预览与导出同构（动态 sectPr + behindDoc 底图 + 浮动文本框 + srcRect 浮动图 + 浮动表格）。
/// - `structured`（结构化）：段落流 + 表格 + 内联图，最稳（行为与历史版本完全一致）。
///
/// 历史：曾经还有 `.anchored`（B 档重排版）/`.background`（C 档衬底图）两个 case，
/// 2026-09-12 因 bbox 不准被下架（`selectable` 收缩到只剩 `.structured`）；
/// 2026-09-18 随「版面还原」特性**删除**——它们从未对用户开放，且
/// `ReconstructDocument`（IR v2）从不编码落盘，无数据兼容风险（plan D1）。
/// 可复用的 XML 部件（EMU 换算、y 翻转、锚定图结构）已并入 `.restored` 实现。
enum R2OutputTier: String, Sendable, Codable, CaseIterable, Equatable, Hashable {
    case restored
    case structured

    /// UI 里用户可选择的档位。`.restored` 在前 = 默认档（版面还原）。
    static let selectable: [R2OutputTier] = [.restored, .structured]

    /// 档位显示名（双语，Localizable.xcstrings `reconstruct.tier.*`，spec layout-restore T017）。
    /// `Text(String)` 是 verbatim 渲染，本地化必须在这里发生（`String(localized:)`）。
    var displayName: String {
        switch self {
        case .restored: return String(localized: "reconstruct.tier.restored")
        case .structured: return String(localized: "reconstruct.tier.structured")
        }
    }
}

protocol SearchablePDFRendering: Sendable {
    func makeSearchablePDF(_ document: ReconstructDocument, fileName: String) async throws -> URL
}

protocol PDFRendering: Sendable {
    func makePDF(imageURLs: [URL], fileName: String) async throws -> URL
}

@MainActor
protocol DocumentStore: AnyObject {
    func documents(query: String, folderID: UUID?, favoritesOnly: Bool) async throws -> [ScanDocument]
    func document(id: UUID) async throws -> ScanDocument?
    func pages(for documentID: UUID) async throws -> [ScanPage]
    func folders() async throws -> [Folder]
    func create(document: ScanDocument, pages: [ScanPage]) async throws
    func appendPages(documentID: UUID, pages: [ScanPage]) async throws
    func updateDocument(_ document: ScanDocument) async throws
    func updatePage(_ page: ScanPage) async throws
    func deleteDocument(id: UUID) async throws
    func createFolder(name: String) async throws -> Folder
    func deleteFolder(id: UUID) async throws
    func knownDocumentIDs() async throws -> Set<UUID>
}

protocol PageFileStoring: Sendable {
    func writeOriginal(session: UUID, page: UUID, data: Data) async throws -> URL
    func originalURL(session: UUID, page: UUID) -> URL
    func commit(
        document: UUID,
        drafts: [PageDraft],
        rendered: [UUID: Data],
        thumbs: [UUID: Data],
        keepOriginals: Bool
    ) async throws -> [ScanPage]
    func url(document: UUID, page: UUID, kind: PageFileKind) -> URL
    func removeDocument(document: UUID) async throws
    func removeSession(session: UUID) async
    func sweep(knownDocumentIDs: Set<UUID>) async
    func storageByteCount() async -> Int64
}

protocol PermissionGranting: Sendable {
    func cameraStatus() async -> CameraAuthorization
    func requestCamera() async -> CameraAuthorization
}
