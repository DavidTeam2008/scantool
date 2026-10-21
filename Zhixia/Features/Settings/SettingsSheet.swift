import SwiftUI

struct SettingsSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var bytes: Int64 = 0
    #if DEBUG
    /// 诊断包导出状态（spec/guided-capture T003）——**debug 专属**，release
    /// 不出现该入口（整段编译期裁掉）。
    @State private var diagnosticPackage: DiagnosticPackage?
    @State private var isExportingDiagnostics = false
    @State private var diagnosticsError: String?
    #endif

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle("settings.autoCapture", isOn: Bindable(environment.preferences).autoCapture)
                    Picker("settings.defaultFilter", selection: Bindable(environment.preferences).defaultEnhancement) {
                        ForEach(Enhancement.allCases, id: \.self) { enhancement in
                            Text(enhancement.title).tag(enhancement)
                        }
                    }
                    Toggle("settings.keepOriginals", isOn: Bindable(environment.preferences).keepOriginals)
                }
                Section {
                    HStack {
                        Text("settings.storage")
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                            .foregroundStyle(Tokens.muted)
                    }
                }
                #if DEBUG
                diagnosticsSection
                #endif
                Section {
                    Text("settings.about")
                        .foregroundStyle(Tokens.muted)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Tokens.paper.ignoresSafeArea())
            .navigationTitle("settings.title")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.done") { dismiss() }
                }
            }
            .task {
                bytes = await environment.fileStore.storageByteCount()
            }
            #if DEBUG
            .sheet(item: $diagnosticPackage) { package in
                DiagnosticsShareSheet(items: [package.url])
            }
            .alert(
                "settings.diagnostics.failed",
                isPresented: Binding(
                    get: { diagnosticsError != nil },
                    set: { if !$0 { diagnosticsError = nil } }
                )
            ) {
                Button("common.done", role: .cancel) {}
            } message: {
                Text(diagnosticsError ?? "")
            }
            #endif
        }
    }

    #if DEBUG
    /// 诊断区（spec/guided-capture T003 / FR-007）——一键导出诊断包：
    /// JSON（逐帧事实 + 候选快照）+ 原图 + 最近 5s 低分辨率帧 + 截图，
    /// 走系统分享；**纯本地**，飞行模式可用。
    private var diagnosticsSection: some View {
        Section {
            Button {
                exportDiagnostics()
            } label: {
                HStack {
                    Text("settings.diagnostics.export")
                    Spacer()
                    if isExportingDiagnostics {
                        ProgressView()
                    }
                }
            }
            .disabled(isExportingDiagnostics)
            Text("settings.diagnostics.hint")
                .font(.footnote)
                .foregroundStyle(Tokens.muted)
        } header: {
            Text("settings.diagnostics")
        }
    }

    /// 生成诊断包并弹出分享面板。
    private func exportDiagnostics() {
        guard let recorder = environment.traceRecorder else { return }
        isExportingDiagnostics = true
        Task { @MainActor in
            defer { isExportingDiagnostics = false }
            let screenshot = CaptureDiagnosticsExporter.captureScreenshot()
            do {
                let package = try CaptureDiagnosticsExporter.build(
                    recorder: recorder,
                    screenshot: screenshot,
                    appVersion: Self.appVersion,
                    deviceModel: Self.deviceModel,
                    osVersion: UIDevice.current.systemVersion
                )
                diagnosticPackage = DiagnosticPackage(url: package.url)
            } catch {
                diagnosticsError = error.localizedDescription
            }
        }
    }

    /// App 版本号（Bundle；缺省空串）。
    private static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    /// 设备型号（`utsname` 的 machine 字段；模拟器返回架构串）。
    private static var deviceModel: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machine = withUnsafePointer(to: &systemInfo.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(cString: $0)
            }
        }
        return machine.isEmpty ? UIDevice.current.model : machine
    }
    #endif
}

#if DEBUG
/// 诊断包句柄（SwiftUI `sheet(item:)` 需要 Identifiable）。
private struct DiagnosticPackage: Identifiable {
    let id = UUID()
    let url: URL
}
#endif
