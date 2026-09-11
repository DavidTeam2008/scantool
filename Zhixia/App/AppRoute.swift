import Foundation

enum AppRoute: Hashable, Sendable {
    case document(UUID)
}

@MainActor
@Observable
final class AppCoordinator {
    var path = [AppRoute]()
    var capture: CaptureLaunch?
    var showSettings = false

    func openDocument(_ id: UUID) {
        path.append(.document(id))
    }

    func startCapture(appending documentID: UUID? = nil) {
        if let documentID {
            capture = .append(documentID)
        } else {
            capture = .fresh
        }
    }
}
