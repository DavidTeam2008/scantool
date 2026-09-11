import Foundation
import UIKit

@MainActor
@Observable
final class CaptureViewModel {
    var phase: CapturePhase = .idle
    var imageQuad: Quad?
    var frameSize: CGSize = CGSize(width: 720, height: 1280)
    var drafts: [PageDraft] = []
    var mode: ScanMode = .document
    var idFace: IDCardFace = .front
    var torchOn = false
    var error: ZhixiaError?
    var isFlashVisible = false
    var permission: CameraAuthorization = .notDetermined
    var replacePageID: UUID?

    let sessionID: UUID
    let appendToDocumentID: UUID?

    private let camera: any CameraCapturing
    private let detector: any EdgeDetecting
    private let fileStore: any PageFileStoring
    private let permissions: any PermissionGranting
    private let preferences: PreferencesStore
    private var smoother = QuadSmoother()
    private var frameTask: Task<Void, Never>?
    private var isDetecting = false
    private var didAutoCaptureThisLock = false
    private let impact = UIImpactFeedbackGenerator(style: .light)

    init(
        launch: CaptureLaunch,
        camera: any CameraCapturing,
        detector: any EdgeDetecting,
        fileStore: any PageFileStoring,
        permissions: any PermissionGranting,
        preferences: PreferencesStore
    ) {
        self.sessionID = UUID()
        self.appendToDocumentID = launch.documentID
        self.camera = camera
        self.detector = detector
        self.fileStore = fileStore
        self.permissions = permissions
        self.preferences = preferences
    }

    var canFinish: Bool { !drafts.isEmpty }
    var overlayIsLocked: Bool {
        if case .locked = phase { return true }
        return false
    }

    func start() async {
        permission = await permissions.cameraStatus()
        if permission == .notDetermined {
            permission = await permissions.requestCamera()
        }
        guard permission == .authorized else {
            if permission == .denied {
                error = .cameraDenied
            }
            return
        }
        do {
            try await camera.start()
            phase = .previewing
            UIApplication.shared.isIdleTimerDisabled = true
            listenToFrames()
        } catch let zhixia as ZhixiaError {
            error = zhixia
        } catch {
            self.error = .cameraUnavailable
        }
    }

    func stop() async {
        frameTask?.cancel()
        frameTask = nil
        await camera.stop()
        UIApplication.shared.isIdleTimerDisabled = false
        if case .capturing = phase {
            return
        }
        if !drafts.isEmpty {
            return
        }
        phase = .idle
    }

    func setMode(_ mode: ScanMode) {
        self.mode = mode
        idFace = .front
        smoother.reset()
        didAutoCaptureThisLock = false
        imageQuad = mode == .idCard ? Quad.idCardWindow : nil
        phase = .previewing
    }

    func toggleTorch() async {
        do {
            try await camera.setTorch(enabled: !torchOn)
            torchOn.toggle()
        } catch {
            self.error = .cameraUnavailable
        }
    }

    func capture() async {
        guard phase != .capturing else { return }
        phase = .capturing
        isFlashVisible = true
        do {
            let photo = try await camera.capturePhoto()
            let pageID = replacePageID ?? UUID()
            _ = try await fileStore.writeOriginal(session: sessionID, page: pageID, data: photo.jpegData)
            let detected = await detector.detect(
                imageData: photo.jpegData,
                idCardWindow: mode == .idCard ? Quad.idCardWindow : nil
            )
            let quad = detected ?? imageQuad ?? .fullImage
            let draft = PageDraft(
                id: pageID,
                sessionID: sessionID,
                quad: quad,
                enhancement: preferences.defaultEnhancement
            )
            if let replacePageID, let index = drafts.firstIndex(where: { $0.id == replacePageID }) {
                drafts[index] = draft
                self.replacePageID = nil
            } else {
                drafts.append(draft)
            }
            if mode == .idCard {
                idFace = drafts.count >= 1 ? .back : .front
            }
            impact.impactOccurred()
        } catch let zhixia as ZhixiaError {
            error = zhixia
        } catch {
            self.error = .captureFailed
        }
        isFlashVisible = false
        smoother.reset()
        didAutoCaptureThisLock = false
        phase = .previewing
        imageQuad = mode == .idCard ? Quad.idCardWindow : nil
    }

    func importImageData(_ data: Data) async {
        let pageID = UUID()
        do {
            let jpeg = ImportedImage.jpeg(from: data) ?? data
            _ = try await fileStore.writeOriginal(session: sessionID, page: pageID, data: jpeg)
            let detected = await detector.detect(
                imageData: jpeg,
                idCardWindow: mode == .idCard ? Quad.idCardWindow : nil
            )
            drafts.append(
                PageDraft(
                    id: pageID,
                    sessionID: sessionID,
                    quad: detected ?? .fullImage,
                    enhancement: preferences.defaultEnhancement
                )
            )
        } catch {
            self.error = .storeFailed
        }
    }

    func deleteDraft(at index: Int) {
        guard drafts.indices.contains(index) else { return }
        drafts.remove(at: index)
        if mode == .idCard {
            idFace = drafts.isEmpty ? .front : .back
        }
    }

    func finish() -> [PageDraft]? {
        guard canFinish else { return nil }
        return drafts
    }

    func discardSession() async {
        await fileStore.removeSession(session: sessionID)
        drafts = []
    }

    func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private func listenToFrames() {
        frameTask?.cancel()
        frameTask = Task { [weak self] in
            guard let self else { return }
            for await frame in camera.frames {
                if Task.isCancelled { break }
                await self.consume(frame)
            }
        }
    }

    private func consume(_ frame: VideoFrame) async {
        guard phase != .capturing, !isDetecting else { return }
        isDetecting = true
        defer { isDetecting = false }
        frameSize = CGSize(width: frame.cgImage.width, height: frame.cgImage.height)
        let window = mode == .idCard ? Quad.idCardWindow : nil
        let detected = await detector.detect(frame: frame, idCardWindow: window)
        let track = smoother.ingest(detected)
        switch track {
        case .searching:
            imageQuad = window
            if phase != .capturing {
                phase = .previewing
            }
            didAutoCaptureThisLock = false
        case .tracking(let quad):
            imageQuad = quad
            if phase != .capturing {
                phase = .previewing
            }
        case .locked(let quad):
            let wasLocked = overlayIsLocked
            imageQuad = quad
            if phase != .capturing {
                phase = .locked(quad)
            }
            if !wasLocked {
                impact.impactOccurred()
            }
            if preferences.autoCapture, !didAutoCaptureThisLock {
                didAutoCaptureThisLock = true
                await capture()
            }
        }
    }
}
