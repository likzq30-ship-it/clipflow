import SwiftUI

struct QuickPanelView: View {
    @ObservedObject var store: ClipboardStore
    let commandHandler: QuickPanelCommandHandler
    let recoveryHandler: RecoveryActionHandler?
    let shortcutDisplay: String
    let onReady: (() -> Void)?
    let onOpenSettings: () -> Void

    @State private var searchText = ""
    @State private var favoritesOnly = false
    @State private var didCompleteAppearPass = false
    @State private var didCompleteLayoutPass = false
    @State private var didFocusSearch = false
    @State private var didRenderListContent = false
    @State private var didNotifyReady = false
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

            Divider()

            VStack(spacing: 10) {
                TextField("Search copied text", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .focused($isSearchFocused)
                    .accessibilityIdentifier("quick.search")
                    .onSubmit {
                        Task { await commandHandler.handle(.copySelection) }
                    }
                    .onChange(of: searchText) { newValue in
                        Task { await updateQuery(searchText: newValue, favoritesOnly: favoritesOnly) }
                    }

                Picker("Scope", selection: $favoritesOnly) {
                    Text("Recent").tag(false)
                    Text("Favorites").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .onChange(of: favoritesOnly) { newValue in
                    Task { await updateQuery(searchText: searchText, favoritesOnly: newValue) }
                }

                pendingUndoBar

                list
                    .frame(maxHeight: .infinity)

                footer
            }
            .padding(12)
        }
        .frame(width: 440, height: 520)
        .background(.regularMaterial)
        .background(readyLayoutProbe)
        .overlay(alignment: .topLeading) {
            QuickPanelKeyboardBridge { command in
                Task { await commandHandler.handle(command) }
            }
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
        .onAppear {
            synchronizeLocalQueryState()
            validateQuickPanelSelection()
            commandHandler.focusSearch = { isSearchFocused = true }
            commandHandler.focusList = { isSearchFocused = false }
            resetReadyProbe()
            DispatchQueue.main.async {
                didCompleteAppearPass = true
                isSearchFocused = true
                didFocusSearch = true
                markEmptyListReadyIfNeeded()
                notifyReadyIfNeeded()
                DispatchQueue.main.async {
                    markEmptyListReadyIfNeeded()
                    notifyReadyIfNeeded()
                }
            }
        }
        .onChange(of: store.session(for: .quickPanel).query.searchText) { newValue in
            if searchText != newValue {
                searchText = newValue
            }
        }
        .onChange(of: store.session(for: .quickPanel).query.scope) { newValue in
            let newFavoritesOnly = newValue == .favorites
            if favoritesOnly != newFavoritesOnly {
                favoritesOnly = newFavoritesOnly
            }
        }
    }
}

private extension QuickPanelView {
    var session: ClipQuerySession {
        store.session(for: .quickPanel)
    }

    var visibleItems: [ClipboardItem] {
        Array(session.items.prefix(50))
    }

    var oldestPendingDelete: PendingDelete? {
        store.pendingDeletes.values.sorted {
            if $0.deletedAt != $1.deletedAt { return $0.deletedAt < $1.deletedAt }
            return $0.itemID.uuidString < $1.itemID.uuidString
        }.first
    }

    var header: some View {
        HStack(spacing: 10) {
            Text("ClipFlow")
                .font(.headline)

            MonitoringStatusView(pause: store.monitoringPause)

            Spacer()

            Menu {
                Button("Pause 5 Minutes") {
                    store.pauseMonitoring(.until(Date().addingTimeInterval(5 * 60)))
                }
                Button("Pause 1 Hour") {
                    store.pauseMonitoring(.until(Date().addingTimeInterval(60 * 60)))
                }
                Button("Pause Until Resumed") {
                    store.pauseMonitoring(.indefinitely)
                }
            } label: {
                Image(systemName: "pause.circle")
            }
            .menuStyle(.borderlessButton)
            .accessibilityIdentifier("quick.pauseMenu")

            Button {
                commandHandler.store.resumeMonitoring()
            } label: {
                Image(systemName: "play.circle")
            }
            .buttonStyle(.plain)
            .help("Resume Monitoring")

            Button {
                commandHandler.store.setSelection(session.selectedItemID, for: .quickPanel)
                commandHandler.store.setSelection(session.selectedItemID, for: .library)
                commandHandler.store.setSelection(session.selectedItemID, for: .quickPanel)
                Task { await commandHandler.handle(.openSelectionInLibrary) }
            } label: {
                Image(systemName: "clock.arrow.circlepath")
            }
            .buttonStyle(.plain)
            .help("Open History")
            .accessibilityIdentifier("quick.openLibrary")

            Button {
                onOpenSettings()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .help("Settings")
            .accessibilityIdentifier("quick.openSettings")
        }
    }

    @ViewBuilder
    var list: some View {
        if visibleItems.isEmpty {
            VStack(spacing: 8) {
                Spacer()
                Image(systemName: "tray")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("No clips yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("quick.emptyState")
            .onAppear {
                didRenderListContent = true
                notifyReadyIfNeeded()
            }
        } else {
            List(selection: selectionBinding) {
                ForEach(visibleItems) { item in
                    QuickClipRow(
                        item: item,
                        isSelected: item.id == session.selectedItemID,
                        isReadOnly: store.isReadOnlyRecovery,
                        onSelect: {
                            store.setSelection(item.id, for: .quickPanel)
                        },
                        onCopy: {
                            store.setSelection(item.id, for: .quickPanel)
                            Task { await commandHandler.handle(.copySelection) }
                        },
                        onToggleFavorite: {
                            store.setSelection(item.id, for: .quickPanel)
                            Task { await commandHandler.handle(.toggleFavorite) }
                        },
                        onOpenInHistory: {
                            store.setSelection(item.id, for: .quickPanel)
                            Task { await commandHandler.handle(.openSelectionInLibrary) }
                        },
                        onDelete: {
                            store.setSelection(item.id, for: .quickPanel)
                            Task { await commandHandler.handle(.deleteSelection) }
                        },
                        onUndo: {
                            Task { await store.undoDelete(id: item.id) }
                        },
                        canUndoDelete: store.pendingDeletes[item.id] != nil
                    )
                    .tag(item.id)
                    .onAppear {
                        if item.id == visibleItems.first?.id {
                            didRenderListContent = true
                            notifyReadyIfNeeded()
                        }
                    }
                }
            }
            .accessibilityIdentifier("quick.list")
        }
    }

    var footer: some View {
        VStack(spacing: 8) {
            HStack {
                Text(String(localized: "\(session.totalCount) results"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(shortcutDisplay)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }

            if case .readOnlyRecovery(_, let backupURL, _) = store.repositoryStartup {
                ErrorBanner(
                    presentation: AppErrorPresentation(
                        code: .databaseReadOnly,
                        message: backupURL.map {
                            String(localized: "ClipFlow is browsing a read-only database. Backup: \($0.lastPathComponent)")
                        } ?? String(localized: "ClipFlow is browsing a read-only database."),
                        severity: .warning,
                        recoveryTitle: backupURL == nil ? nil : String(localized: "Reveal Backup"),
                        recoveryAction: backupURL.map(RecoveryAction.revealBackup)
                    ),
                    isUndismissable: true,
                    onRecoveryAction: handleRecovery
                )
                .accessibilityIdentifier("quick.recoveryBanner")
            } else if let banner = store.banner {
                ErrorBanner(
                    presentation: banner,
                    onRecoveryAction: handleRecovery
                )
                .accessibilityIdentifier("quick.errorBanner")
            }
        }
    }

    @ViewBuilder
    var pendingUndoBar: some View {
        if let pendingDelete = oldestPendingDelete {
            HStack {
                Text("Clip deleted")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Undo") {
                    Task { await store.undoDelete(id: pendingDelete.itemID) }
                }
                .accessibilityIdentifier("quick.undo.\(pendingDelete.itemID.uuidString)")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    var selectionBinding: Binding<UUID?> {
        Binding(
            get: { session.selectedItemID },
            set: { store.setSelection($0, for: .quickPanel) }
        )
    }

    var readyLayoutProbe: some View {
        GeometryReader { _ in
            Color.clear
                .onAppear {
                    DispatchQueue.main.async {
                        didCompleteLayoutPass = true
                        notifyReadyIfNeeded()
                    }
                }
        }
    }

    func updateQuery(searchText: String, favoritesOnly: Bool) async {
        await store.updateQuery(
            .quickPanel(searchText: searchText, favoritesOnly: favoritesOnly),
            for: .quickPanel
        )
        validateQuickPanelSelection()
    }

    func synchronizeLocalQueryState() {
        let query = session.query
        searchText = query.searchText
        favoritesOnly = query.scope == .favorites
    }

    func validateQuickPanelSelection() {
        let selectedID = session.selectedItemID
        guard selectedID == nil || visibleItems.contains(where: { $0.id == selectedID }) else {
            store.setSelection(visibleItems.first?.id, for: .quickPanel)
            return
        }
        if selectedID == nil {
            store.setSelection(visibleItems.first?.id, for: .quickPanel)
        }
    }

    func handleRecovery(_ action: RecoveryAction) async {
        await recoveryHandler?.handle(action)
    }

    func resetReadyProbe() {
        didCompleteAppearPass = false
        didCompleteLayoutPass = false
        didFocusSearch = false
        didRenderListContent = false
        didNotifyReady = false
    }

    func markEmptyListReadyIfNeeded() {
        if visibleItems.isEmpty {
            didRenderListContent = true
        }
    }

    func notifyReadyIfNeeded() {
        guard !didNotifyReady,
              didCompleteAppearPass,
              didCompleteLayoutPass,
              didFocusSearch,
              didRenderListContent else {
            return
        }
        didNotifyReady = true
        onReady?()
    }
}
