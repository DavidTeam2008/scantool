import Foundation
import SwiftData

@MainActor
@Observable
final class AppEnvironment {
    let preferences: PreferencesStore
    let permissions: any PermissionGranting
    let camera: any CameraCapturing
    let previewAttacher: any CameraPreviewAttaching
    let detector: any EdgeDetecting
    let renderer: any ImageRendering
    let pipeline: ImagePipeline
    let documentStore: any DocumentStore
    let fileStore: any PageFileStoring
    let recognizer: any TextRecognizing
    /// iOS 26 结构化文档识别（`RecognizeDocumentsRequest`）。为 nil 时还原链路全程走几何管线。
    let structureRecognizer: (any DocumentStructureRecognizing)?
    let parser: any DocumentParsing
    /// 显式注入的 parser（测试 / 预览）。非 nil 时 `makeReconstructParser` 原样返回，
    /// 尊重注入者自己的裁图路径约定。
    private let customParser: (any DocumentParsing)?
    let docx: any DocxRendering
    let searchablePDF: any SearchablePDFRendering
    let pdf: any PDFRendering

    init(
        preferences: PreferencesStore = PreferencesStore(),
        permissions: any PermissionGranting = PermissionService(),
        camera: (any CameraCapturing)? = nil,
        previewAttacher: (any CameraPreviewAttaching)? = nil,
        detector: any EdgeDetecting = VisionEdgeDetector(),
        pipeline: ImagePipeline = ImagePipeline(),
        documentStore: (any DocumentStore)? = nil,
        fileStore: any PageFileStoring = PageFileStore(),
        recognizer: any TextRecognizing = VisionTextRecognizer(),
        structureRecognizer: (any DocumentStructureRecognizing)? = VisionDocumentStructureRecognizer(),
        parser: (any DocumentParsing)? = nil,
        docx: any DocxRendering = DocxExportService(),
        searchablePDF: any SearchablePDFRendering = SearchablePDFExportService(),
        pdf: any PDFRendering = PDFExportService()
    ) {
        self.preferences = preferences
        self.permissions = permissions
        let resolvedCamera = camera ?? AVCameraSession()
        self.camera = resolvedCamera
        if let previewAttacher {
            self.previewAttacher = previewAttacher
        } else if let session = resolvedCamera as? AVCameraSession {
            self.previewAttacher = CameraPreviewBinder(camera: session)
        } else {
            self.previewAttacher = CameraPreviewBinder { _ in }
        }
        self.detector = detector
        self.renderer = pipeline
        self.pipeline = pipeline
        self.documentStore = documentStore ?? Self.makeStore()
        self.fileStore = fileStore
        self.recognizer = recognizer
        self.structureRecognizer = structureRecognizer
        self.customParser = parser
        self.parser = parser ?? CompositeDocumentParser(
            onDevice: OnDeviceDocumentParser(
                recognizer: recognizer,
                structureRecognizer: structureRecognizer
            )
        )
        self.docx = docx
        self.searchablePDF = searchablePDF
        self.pdf = pdf
    }

    /// 按文档构造还原解析器（spec/layout-restore plan D2 / FR-010）。
    ///
    /// figure / barcode 裁图不再落 `temporaryDirectory`（系统随时清理 →
    /// 「还原完成后过一阵再导出」缺图），改落 PageFileStore 的文档级持久目录
    /// `files/<document>/reconstruct/<page>/`：随 `removeDocument` 走、被 `sweep` 回收。
    ///
    /// - 默认（未显式注入 parser / fileStore 为具体 PageFileStore）：构造一个
    ///   文档作用域的解析器。OnDeviceDocumentParser 是轻量 actor（只持引用），
    ///   按文档构造无性能代价；`DocumentParsing` 协议签名不变（plan D8），
    ///   documentID 由闭包捕获。
    /// - 显式注入 parser（测试 / 预览）：原样返回注入实例。
    /// - fileStore 是自定义替身但未注入 parser：退回共享 `parser`（旧 tmp 裁图路径），
    ///   不强行假设替身支持持久目录。
    func makeReconstructParser(documentID: UUID) -> any DocumentParsing {
        if customParser != nil { return parser }
        guard let store = fileStore as? PageFileStore else { return parser }
        return CompositeDocumentParser(
            onDevice: OnDeviceDocumentParser(
                recognizer: recognizer,
                structureRecognizer: structureRecognizer,
                cropDirectory: { pageID in
                    store.reconstructCropDirectory(document: documentID, page: pageID)
                }
            )
        )
    }

    static func makeStore() -> any DocumentStore {
        do {
            let schema = Schema([DocumentEntity.self, PageEntity.self, FolderEntity.self])
            let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
            let container = try ModelContainer(for: schema, configurations: [configuration])
            return SwiftDataDocumentStore(container: container)
        } catch {
            ZhixiaLog.store.error("SwiftData unavailable, using memory: \(error.localizedDescription, privacy: .public)")
            return InMemoryDocumentStore()
        }
    }
}
