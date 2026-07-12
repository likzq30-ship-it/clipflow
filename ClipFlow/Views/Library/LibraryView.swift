import SwiftUI

struct LibraryView: View {
    @ObservedObject var store: ClipboardStore
    @ObservedObject var jobs: AIJobCoordinator

    private let aiActions: AIActionCoordinator
    private let recoveryHandler: RecoveryActionHandler?
    private let detailActions: ClipDetailActionAdapter

    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var selectedSection: LibrarySection = .all
    @State private var searchText = ""

    init(
        store: ClipboardStore,
        aiActions: AIActionCoordinator,
        jobs: AIJobCoordinator,
        recoveryHandler: RecoveryActionHandler?
    ) {
        self.store = store
        self.jobs = jobs
        self.aiActions = aiActions
        self.recoveryHandler = recoveryHandler
        self.detailActions = ClipDetailActionAdapter(
            store: store,
            aiActions: aiActions,
            allowedCategories: { store.customCategories }
        )
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            LibrarySidebar(
                selection: $selectedSection,
                customCategories: store.customCategories
            )
        } content: {
            ClipListView(
                store: store,
                actions: detailActions
            )
            .searchable(text: $searchText, placement: .toolbar, prompt: "Search clips")
        } detail: {
            if let item = selectedDetailItem {
                ClipDetailView(
                    item: item,
                    actions: detailActions,
                    jobs: jobs
                )
                .id(item.id)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "doc.on.clipboard")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("Select a clip")
                        .font(.headline)
                    Text("Choose a clipboard item to inspect and act on it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("library.detail")
            }
        }
        .frame(minWidth: 760, minHeight: 520)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    toggleSidebar()
                } label: {
                    Label("Toggle Sidebar", systemImage: "sidebar.leading")
                }
                .accessibilityIdentifier("library.sidebarToggle")
            }
        }
        .safeAreaInset(edge: .top) {
            if let banner = readOnlyRecoveryPresentation(for: store.repositoryStartup) {
                ErrorBanner(
                    presentation: banner,
                    isUndismissable: true,
                    onRecoveryAction: handleRecovery
                )
                .accessibilityIdentifier("library.recoveryBanner")
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
        .task {
            searchText = store.session(for: .library).query.searchText
            await applyCurrentQuery()
        }
        .onChange(of: selectedSection) { _ in
            Task { await applyCurrentQuery() }
        }
        .onChange(of: searchText) { _ in
            Task { await applyCurrentQuery() }
        }
    }
}

private extension LibraryView {
    var selectedDetailItem: ClipboardItem? {
        let selectedID = store.session(for: .library).selectedItemID
        guard let selectedID else { return nil }
        if let item = store.itemCache[selectedID] {
            return item
        }
        return store.session(for: .library).items.first { $0.id == selectedID }
    }

    func applyCurrentQuery() async {
        await store.updateQuery(
            ClipQuery(
                searchText: searchText,
                scope: selectedSection.clipScope,
                limit: 100,
                offset: 0
            ),
            for: .library
        )
    }

    func toggleSidebar() {
        columnVisibility = columnVisibility == .detailOnly ? .automatic : .detailOnly
    }

    func handleRecovery(_ action: RecoveryAction) async {
        await recoveryHandler?.handle(action)
    }
}
