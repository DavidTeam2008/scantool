import Foundation
import SwiftUI
import UIKit

struct PreviewPermissions: PermissionGranting {
    var status: CameraAuthorization = .authorized
    func cameraStatus() async -> CameraAuthorization { status }
    func requestCamera() async -> CameraAuthorization { status }
}

final class PreviewCamera: CameraCapturing, @unchecked Sendable {
    func start() async throws {}
    func stop() async {}
    func capturePhoto() async throws -> CapturedPhoto {
        CapturedPhoto(jpegData: PreviewImages.jpeg(), pixelSize: CGSize(width: 80, height: 100))
    }
    func setTorch(enabled: Bool) async throws { _ = enabled }
    func setFlashAuto(_ enabled: Bool) async { _ = enabled }
    var frames: AsyncStream<VideoFrame> {
        AsyncStream { $0.finish() }
    }
    /// 预览/测试环境无真实会话可测量：恒等几何（协议契约）→ FOVLayout 换算为 no-op，
    /// 既有测试语义保持不变。
    func geometry() async -> CaptureGeometry { .identity }
}

actor PreviewDetector: EdgeDetecting {
    func detect(frame: VideoFrame, idCardWindow: Quad?) async -> Quad? { .fullImage }
    func detect(imageData: Data, idCardWindow: Quad?) async -> Quad? { Quad(
        topLeft: CGPoint(x: 0.1, y: 0.1),
        topRight: CGPoint(x: 0.9, y: 0.12),
        bottomRight: CGPoint(x: 0.88, y: 0.9),
        bottomLeft: CGPoint(x: 0.08, y: 0.88)
    )}
}

actor PreviewRecognizer: TextRecognizing {
    func recognize(imageURL: URL, pageID: UUID) async throws -> OCRPageText {
        OCRPageText(pageID: pageID, lines: [OCRLine(text: "房屋租赁合同", boundingBox: .zero)])
    }
}

actor PreviewPDF: PDFRendering {
    func makePDF(imageURLs: [URL], fileName: String) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: fileName)
        try Data("pdf".utf8).write(to: url)
        return url
    }
}

enum PreviewImages {
    static func jpeg() -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 100))
        let image = renderer.image { context in
            UIColor(red: 0.96, green: 0.94, blue: 0.90, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 80, height: 100))
            UIColor(red: 0.76, green: 0.29, blue: 0.20, alpha: 0.35).setStroke()
            UIBezierPath(rect: CGRect(x: 8, y: 8, width: 64, height: 84)).stroke()
        }
        return image.jpegData(compressionQuality: 0.85) ?? Data()
    }
}

extension AppEnvironment {
    @MainActor
    static func preview(
        store: (any DocumentStore)? = nil,
        fileStore: (any PageFileStoring)? = nil
    ) -> AppEnvironment {
        let defaults = UserDefaults(suiteName: "zhixia.preview.\(UUID().uuidString)") ?? .standard
        let preferences = PreferencesStore(defaults: defaults)
        preferences.hasCompletedOnboarding = true
        return AppEnvironment(
            preferences: preferences,
            permissions: PreviewPermissions(),
            camera: PreviewCamera(),
            detector: PreviewDetector(),
            pipeline: ImagePipeline(),
            documentStore: store ?? InMemoryDocumentStore(),
            fileStore: fileStore ?? PageFileStore(root: FileManager.default.temporaryDirectory.appending(path: "zhixia-preview-\(UUID().uuidString)")),
            recognizer: PreviewRecognizer(),
            pdf: PreviewPDF()
        )
    }
}

extension LibraryViewModel {
    @MainActor
    static var previewEmpty: LibraryViewModel {
        LibraryViewModel(store: InMemoryDocumentStore(), fileStore: PageFileStore(root: FileManager.default.temporaryDirectory))
    }

    @MainActor
    static var previewFilled: LibraryViewModel {
        let store = InMemoryDocumentStore()
        let viewModel = LibraryViewModel(store: store, fileStore: PageFileStore(root: FileManager.default.temporaryDirectory))
        let document = ScanDocument(
            id: UUID(),
            title: "租赁合同",
            folderID: nil,
            createdAt: Date(),
            updatedAt: Date(),
            isFavorite: false,
            pageIDs: [UUID()],
            ocrSearchBlob: ""
        )
        Task {
            try? await store.create(document: document, pages: [])
            await viewModel.reload()
        }
        return viewModel
    }
}
