import SwiftUI

struct SettingsSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var bytes: Int64 = 0

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
        }
    }
}
