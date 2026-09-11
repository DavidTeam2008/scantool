import SwiftUI

struct FolderPicker: View {
    let folders: [Folder]
    var onSelect: (UUID?) -> Void
    var onCancel: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Button("library.all") {
                    onSelect(nil)
                }
                ForEach(folders) { folder in
                    Button(folder.name) {
                        onSelect(folder.id)
                    }
                }
            }
            .navigationTitle("library.move")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel", action: onCancel)
                }
            }
        }
        .presentationDetents([.medium])
    }
}
