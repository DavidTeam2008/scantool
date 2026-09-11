import SwiftUI

struct LibraryView: View {
    @Bindable var viewModel: LibraryViewModel
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(AppEnvironment.self) private var environment
    @State private var documentPendingRename: ScanDocument?
    @State private var renameText = ""
    @State private var documentPendingMove: ScanDocument?
    @State private var newFolderName = ""
    @State private var isCreatingFolder = false

    var body: some View {
        VStack(spacing: 0) {
            searchField
            tabs
            content
        }
        .background(Tokens.paper.ignoresSafeArea())
        .navigationTitle("library.title")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("settings.title") {
                    coordinator.showSettings = true
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            ScanButton {
                coordinator.startCapture()
            }
            .padding(.bottom, 8)
        }
        .task {
            await viewModel.reload()
        }
        .alert("library.rename", isPresented: renamePresented) {
            TextField("library.rename", text: $renameText)
            Button("common.save") {
                if let documentPendingRename {
                    Task { await viewModel.rename(documentPendingRename, title: renameText) }
                }
            }
            Button("common.cancel", role: .cancel) {}
        }
        .sheet(isPresented: $isCreatingFolder) {
            NewFolderSheet(name: $newFolderName) { name in
                Task {
                    await viewModel.createFolder(name: name)
                    newFolderName = ""
                    isCreatingFolder = false
                }
            } onCancel: {
                newFolderName = ""
                isCreatingFolder = false
            }
        }
        .sheet(item: $documentPendingMove) { document in
            FolderPicker(
                folders: viewModel.folders,
                onSelect: { folderID in
                    Task { await viewModel.move(document, to: folderID) }
                    documentPendingMove = nil
                },
                onCancel: { documentPendingMove = nil }
            )
        }
    }

    private var searchField: some View {
        TextField("library.search", text: $viewModel.query)
            .textFieldStyle(.plain)
            .padding(10)
            .background(Color(hex: 0xEBE4D8), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.horizontal, Tokens.horizontalPadding)
            .padding(.bottom, 8)
            .onChange(of: viewModel.query) { _, _ in
                Task { await viewModel.reload() }
            }
    }

    private var tabs: some View {
        HStack(spacing: 18) {
            ForEach(LibraryTab.allCases, id: \.self) { tab in
                Button {
                    viewModel.tab = tab
                    Task { await viewModel.reload() }
                } label: {
                    Text(tab.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(viewModel.tab == tab ? Tokens.ink : Tokens.muted)
                        .padding(.bottom, 6)
                        .overlay(alignment: .bottom) {
                            if viewModel.tab == tab {
                                Tokens.seal.frame(height: 2)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, Tokens.horizontalPadding)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .loading:
            ProgressView().frame(maxHeight: .infinity)
        case .failed(let error):
            ContentUnavailableView(error.userMessage, systemImage: "exclamationmark.triangle")
        case .empty:
            if viewModel.tab == .folders {
                folderList
            } else {
                VStack {
                    Spacer()
                    Text("library.empty")
                        .foregroundStyle(Tokens.muted)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
        case .ready:
            if viewModel.tab == .folders, viewModel.selectedFolderID == nil {
                folderList
            } else {
                documentGrid
            }
        }
    }

    private var documentGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ForEach(viewModel.documents) { document in
                    Button {
                        coordinator.openDocument(document.id)
                    } label: {
                        DocumentCard(
                            title: document.title,
                            subtitle: subtitle(for: document),
                            imageURL: viewModel.coverURL(for: document)
                        )
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("library.favorite") {
                            Task { await viewModel.toggleFavorite(document) }
                        }
                        Button("library.rename") {
                            documentPendingRename = document
                            renameText = document.title
                        }
                        Button("library.move") {
                            documentPendingMove = document
                        }
                        Button("common.delete", role: .destructive) {
                            Task { await viewModel.delete(document) }
                        }
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            Task { await viewModel.delete(document) }
                        } label: {
                            Text("common.delete")
                        }
                    }
                }
            }
            .padding(.horizontal, Tokens.horizontalPadding)
            .padding(.bottom, 96)
        }
    }

    private var folderList: some View {
        VStack(spacing: 0) {
            Button {
                isCreatingFolder = true
            } label: {
                Label("library.newFolder", systemImage: "folder.badge.plus")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Tokens.forest)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Tokens.horizontalPadding)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.plain)

            if viewModel.folders.isEmpty {
                Spacer()
                Text("library.noFolders")
                    .foregroundStyle(Tokens.muted)
                Spacer()
            } else {
                List {
                    ForEach(viewModel.folders) { folder in
                        Button {
                            viewModel.selectedFolderID = folder.id
                            viewModel.tab = .folders
                            Task { await viewModel.reload() }
                        } label: {
                            HStack {
                                Text(folder.name)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(Tokens.muted)
                            }
                        }
                        .listRowBackground(Tokens.card)
                        .swipeActions {
                            Button(role: .destructive) {
                                Task { await viewModel.deleteFolder(folder) }
                            } label: {
                                Text("common.delete")
                            }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
        }
    }

    private var renamePresented: Binding<Bool> {
        Binding(
            get: { documentPendingRename != nil },
            set: { if !$0 { documentPendingRename = nil } }
        )
    }

    private func subtitle(for document: ScanDocument) -> String {
        let pages = String(localized: "library.pages \(document.pageCount)")
        return "\(pages) · \(document.updatedAt.formatted(.relative(presentation: .named)))"
    }
}

struct NewFolderSheet: View {
    @Binding var name: String
    var onSave: (String) -> Void
    var onCancel: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                TextField("library.folderName", text: $name)
                    .textInputAutocapitalization(.words)
            }
            .navigationTitle("library.newFolder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.save") {
                        onSave(name)
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}

private extension LibraryTab {
    var title: LocalizedStringResource {
        switch self {
        case .all: "library.tab.all"
        case .folders: "library.tab.folders"
        case .favorites: "library.tab.favorites"
        }
    }
}

#Preview("空库") {
    NavigationStack {
        LibraryView(viewModel: .previewEmpty)
    }
    .environment(AppEnvironment.preview())
    .environment(AppCoordinator())
}

#Preview("有文档") {
    NavigationStack {
        LibraryView(viewModel: .previewFilled)
    }
    .environment(AppEnvironment.preview())
    .environment(AppCoordinator())
}
