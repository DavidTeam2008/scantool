import Foundation

/// Local layout first. TextIn stays optional and unused until a key is configured.
actor CompositeDocumentParser: DocumentParsing {
    private let onDevice: OnDeviceDocumentParser
    private let cloud: TextInDocumentParser

    init(onDevice: OnDeviceDocumentParser, cloud: TextInDocumentParser = TextInDocumentParser()) {
        self.onDevice = onDevice
        self.cloud = cloud
    }

    func parse(imageURL: URL, pageID: UUID, scene: ReconstructScene) async throws -> ReconstructPage {
        let local = try await onDevice.parse(imageURL: imageURL, pageID: pageID, scene: scene)
        guard local.scene != .plain else { return local }
        guard await cloud.isConfigured else { return local }
        do {
            return try await cloud.parse(imageURL: imageURL, pageID: pageID, scene: local.scene)
        } catch {
            return local
        }
    }
}
