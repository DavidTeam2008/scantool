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

protocol CameraCapturing: Sendable {
    func start() async throws
    func stop() async
    func capturePhoto() async throws -> CapturedPhoto
    func setTorch(enabled: Bool) async throws
    func setFlashAuto(_ enabled: Bool) async
    var frames: AsyncStream<VideoFrame> { get }
}

@MainActor
protocol CameraPreviewAttaching: AnyObject {
    func attachPreview(to layer: AnyObject)
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

protocol ReconstructRepairing: Sendable {
    func repair(imageURL: URL, page: ReconstructPage, failures: [UUID]) async throws -> ReconstructPage
}

protocol DocxRendering: Sendable {
    func makeDocx(_ document: ReconstructDocument, fileName: String, tier: R2OutputTier) async throws -> URL
}

/// DOCX 导出档位（docs/07 §3.1 / §6.6.1）。
/// - `structured`（默认）：A 档结构化 —— 段落流 + 表格 + 内联图，最稳。
/// - `anchored`：B 档重排版 —— 块按 anchor 位置浮于页面上，结构 + 视觉位置都保真；
///   Word 兼容性比 A 档略差，旧版 Word 可能 inline fallback。
/// - `background`：C 档衬底图 —— 原图作为 `wp:anchor behindDoc=1` 衬底，文字层正常流。
///   视觉最忠实（与扫描原图几乎一致），可检索性靠文字层。
enum R2OutputTier: String, Sendable, Codable, CaseIterable, Equatable, Hashable {
    case structured
    case anchored
    case background

    var displayName: String {
        switch self {
        case .structured: return "A · 结构化"
        case .anchored: return "B · 重排版"
        case .background: return "C · 衬底图"
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
