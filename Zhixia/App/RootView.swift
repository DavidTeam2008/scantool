import SwiftUI

struct RootView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.scenePhase) private var scenePhase
    @State private var libraryViewModel: LibraryViewModel?
    @State private var captureViewModel: CaptureViewModel?
    @State private var reviewViewModel: ReviewViewModel?
    @State private var showReview = false

    var body: some View {
        @Bindable var coordinator = coordinator
        NavigationStack(path: $coordinator.path) {
            Group {
                if let libraryViewModel {
                    LibraryView(viewModel: libraryViewModel)
                } else {
                    Tokens.paper.ignoresSafeArea()
                }
            }
            .navigationDestination(for: AppRoute.self) { route in
                switch route {
                case .document(let id):
                    DocumentView(
                        viewModel: DocumentViewModel(
                            documentID: id,
                            store: environment.documentStore,
                            fileStore: environment.fileStore
                        )
                    )
                }
            }
        }
        .fullScreenCover(item: $coordinator.capture) { launch in
            captureCover(launch)
        }
        .sheet(isPresented: $coordinator.showSettings) {
            SettingsSheet()
        }
        .fullScreenCover(isPresented: onboardingPresented) {
            OnboardingView()
        }
        .onAppear {
            if libraryViewModel == nil {
                libraryViewModel = LibraryViewModel(
                    store: environment.documentStore,
                    fileStore: environment.fileStore
                )
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                Task { await captureViewModel?.stop() }
            }
        }
        .preferredColorScheme(.light)
    }

    private var onboardingPresented: Binding<Bool> {
        Binding(
            get: { !environment.preferences.hasCompletedOnboarding },
            set: { presented in
                if !presented {
                    environment.preferences.hasCompletedOnboarding = true
                }
            }
        )
    }

    @ViewBuilder
    private func captureCover(_ launch: CaptureLaunch) -> some View {
        NavigationStack {
            Group {
                if showReview, let liveReview = reviewViewModel {
                    ReviewView(
                        viewModel: liveReview,
                        onSaved: { documentID in
                            dismissCapture()
                            Task { await libraryViewModel?.reload() }
                            coordinator.openDocument(documentID)
                        },
                        onRetake: { pageID in
                            captureViewModel?.replacePageID = pageID
                            showReview = false
                        },
                        onCancel: {
                            showReview = false
                        }
                    )
                    .toolbar(.hidden, for: .navigationBar)
                } else if let liveCapture = captureViewModel {
                    CaptureView(
                        viewModel: liveCapture,
                        onFinish: { drafts in
                            Task { await liveCapture.stop() }
                            if let existing = reviewViewModel {
                                existing.replaceDrafts(drafts)
                            } else {
                                reviewViewModel = ReviewViewModel(
                                    drafts: drafts,
                                    sessionID: liveCapture.sessionID,
                                    appendToDocumentID: liveCapture.appendToDocumentID,
                                    renderer: environment.renderer,
                                    detector: environment.detector,
                                    fileStore: environment.fileStore,
                                    documentStore: environment.documentStore,
                                    preferences: environment.preferences
                                )
                            }
                            showReview = true
                        },
                        onCancel: {
                            dismissCapture()
                        }
                    )
                    .toolbar(.hidden, for: .navigationBar)
                } else {
                    Tokens.preview.ignoresSafeArea()
                }
            }
        }
        .onAppear {
            if captureViewModel == nil {
                captureViewModel = CaptureViewModel(
                    launch: launch,
                    camera: environment.camera,
                    detector: environment.detector,
                    fileStore: environment.fileStore,
                    permissions: environment.permissions,
                    preferences: environment.preferences
                )
            }
        }
    }

    private func dismissCapture() {
        coordinator.capture = nil
        captureViewModel = nil
        reviewViewModel = nil
        showReview = false
    }
}
