import Foundation

/// R2 hook. Not called until an API key is configured.
actor TextInDocumentParser: DocumentParsing {
    var apiKey: String?

    var isConfigured: Bool {
        !(apiKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    func parse(imageURL: URL, pageID: UUID, scene: ReconstructScene) async throws -> ReconstructPage {
        _ = imageURL
        _ = pageID
        _ = scene
        throw ZhixiaError.reconstructCloudUnavailable
    }
}
