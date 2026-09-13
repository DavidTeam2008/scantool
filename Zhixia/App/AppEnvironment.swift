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
