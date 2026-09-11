import SwiftUI

@main
struct ZhixiaApp: App {
    @State private var environment = AppEnvironment()
    @State private var coordinator = AppCoordinator()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(environment)
                .environment(coordinator)
                .tint(Tokens.seal)
        }
    }
}
