import AppKit
import Foundation
import Observation
import PlanisphereCore

@MainActor
@Observable
final class VaultAppModel {
    var vaults: [VaultRecord] = []
    var selectedVaultID: UUID?
    var checkpoints: [Checkpoint] = []
    var selectedCheckpointID: UUID?
    var changes: [FileChange] = []
    var selectedChangePath: String?
    var beforeText: String?
    var afterText: String?
    var checkpointMessage = ""
    var historyReadError: String?
    var isBusy = false
    var busyDescription = ""
    var errorMessage: String?
    var notice: String?
    var noticeURL: URL?
    let historyURL: URL

    @ObservationIgnored private var store: VaultStore?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var startupError: String?

    init() {
        if let path = ProcessInfo.processInfo.environment["PLANISPHERE_DATA_DIR"], !path.isEmpty {
            historyURL = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            historyURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Planisphere", isDirectory: true)
        }
        do { store = try VaultStore(rootURL: historyURL) }
        catch { startupError = error.localizedDescription }
    }

    var selectedVault: VaultRecord? { vaults.first { $0.id == selectedVaultID } }
    var selectedCheckpoint: Checkpoint? { checkpoints.first { $0.id == selectedCheckpointID } }
    var selectedChange: FileChange? { changes.first { $0.path == selectedChangePath } }
    var canOpenObsidian: Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: "md.obsidian") != nil }

    func start() async {
        guard !started else { return }
        started = true
        if let startupError { errorMessage = startupError; return }
        await perform("Opening your vaults") { store in
            if let path = ProcessInfo.processInfo.environment["PLANISPHERE_DEMO_VAULT"], !path.isEmpty {
                _ = try await store.register(url: URL(fileURLWithPath: path, isDirectory: true), name: nil)
            }
            try await self.reloadVaults(store: store)
        }
    }

    func selectVault(_ id: UUID?) {
        guard !isBusy, id != selectedVaultID else { return }
        Task {
            await perform("Reading local history") { store in
                self.selectedVaultID = id
                self.checkpointMessage = ""
                self.clearHistory()
                try await self.reloadHistory(store: store)
            }
        }
    }

    func selectCheckpoint(_ checkpoint: Checkpoint) {
        guard !isBusy, checkpoint.id != selectedCheckpointID else { return }
        Task {
            await perform("Reading checkpoint") { store in
                try await self.loadCheckpoint(checkpoint, store: store)
            }
        }
    }

    func retryHistory() {
        guard !isBusy, selectedVaultID != nil else { return }
        Task {
            await perform("Reading local history") { store in
                try await self.reloadHistory(store: store)
            }
        }
    }

    func selectChange(_ change: FileChange) {
        guard !isBusy, change.path != selectedChangePath else { return }
        Task {
            await perform("Reading file versions") { store in
                try await self.loadChange(change, store: store)
            }
        }
    }

    func chooseExistingVault() {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.title = "Add an Existing Vault"
        panel.message = "Choose a folder to manage in place. Its files stay where they are. History is stored separately on this Mac."
        panel.prompt = "Add Vault"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            await perform("Adding vault") { store in
                let vault = try await store.register(url: url, name: nil)
                await self.refreshAfterCompletion("Vault added. Any retained history is preserved.", url: vault.url) {
                    try await self.reloadVaults(store: store, preferred: vault.id)
                }
            }
        }
    }

    func chooseNewVault() {
        guard !isBusy,
              let url = newFolderDestination(title: "Create a New Vault", prompt: "Create Vault", name: "My Vault",
                  message: "Choose a name and location for a new vault folder. No account or upload is needed.") else { return }
        Task {
            await perform("Creating vault") { store in
                let vault = try await store.create(at: url)
                await self.refreshAfterCompletion("Your local vault was created. Open it in your editor and add your files.", url: vault.url) {
                    try await self.reloadVaults(store: store, preferred: vault.id)
                }
            }
        }
    }

    func createCheckpoint() {
        guard !isBusy, historyReadError == nil, let vault = selectedVault else { return }
        let message = checkpointMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            await perform("Saving local checkpoint") { store in
                let checkpoint = try await store.createCheckpoint(vaultID: vault.id, message: message.isEmpty ? "Checkpoint" : message)
                self.checkpointMessage = ""
                let completion = "Checkpoint saved on this Mac at \(checkpoint.createdAt.formatted(date: .omitted, time: .standard)). \(checkpoint.fileCount) files preserved."
                await self.refreshAfterCompletion(completion) {
                    try await self.reloadHistory(store: store, preferred: checkpoint.id)
                }
            }
        }
    }

    func restoreCopy() {
        guard !isBusy, let vault = selectedVault, let checkpoint = selectedCheckpoint,
              let url = newFolderDestination(title: "Restore a New Copy", prompt: "Restore Copy", name: "\(vault.name) — Recovered",
                  message: "Restore this checkpoint into a new folder. Your original vault and its newer work remain untouched. The recovered copy will be added as a separate vault.") else { return }
        Task {
            await perform("Verifying and restoring a new copy") { store in
                let recovered = try await store.restoreCopy(vaultID: vault.id, checkpointID: checkpoint.id, destination: url)
                await self.refreshAfterCompletion("Recovered copy created. The original vault and its history are unchanged.", url: recovered.url) {
                    try await self.reloadVaults(store: store, preferred: recovered.id)
                }
            }
        }
    }

    func exportVault() {
        guard !isBusy, historyReadError == nil, !checkpoints.isEmpty, let vault = selectedVault,
              let url = newFolderDestination(title: "Export Vault and History", prompt: "Export", name: "\(vault.name) — Export",
                  message: "Export the latest saved checkpoint and all retained history into a new folder. Changes since the last checkpoint are not included. The working vault stays in place.") else { return }
        Task {
            await perform("Preparing a complete export") { store in
                let exported = try await store.exportVault(vaultID: vault.id, destination: url)
                self.showNotice("The latest saved checkpoint and retained history were exported. Changes since the last checkpoint are not included.", url: exported)
            }
        }
    }

    func removeSelectedVault() {
        guard !isBusy, let vault = selectedVault else { return }
        Task {
            await perform("Removing vault from this list") { store in
                try await store.archiveVault(vault.id)
                await self.refreshAfterCompletion("\(vault.name) was removed from the list. Its files and local history are preserved. Add the same folder again to return to its history.") {
                    try await self.reloadVaults(store: store)
                }
            }
        }
    }

    func openSelectedVault() {
        guard let vault = selectedVault else { return }
        if !NSWorkspace.shared.open(vault.url) { errorMessage = "Finder could not open this folder. It may have moved or become unavailable. Its retained history is still preserved." }
    }

    func openInObsidian() {
        guard let vault = selectedVault else { return }
        var components = URLComponents()
        components.scheme = "obsidian"
        components.host = "open"
        components.queryItems = [URLQueryItem(name: "path", value: vault.path)]
        guard let url = components.url, NSWorkspace.shared.open(url) else {
            errorMessage = "Obsidian could not open this vault. Open the folder in Obsidian first, or use Finder to choose your editor."
            return
        }
    }

    func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }

    private func newFolderDestination(title: String, prompt: String, name: String, message: String) -> URL? {
        let panel = NSSavePanel()
        panel.title = title
        panel.prompt = prompt
        panel.message = message
        panel.nameFieldLabel = "New folder:"
        panel.nameFieldStringValue = name
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func perform(_ description: String, operation: @MainActor (VaultStore) async throws -> Void) async {
        guard !isBusy else { return }
        guard let store else { errorMessage = startupError ?? "Local history is unavailable."; return }
        isBusy = true
        busyDescription = description
        notice = nil
        noticeURL = nil
        defer { isBusy = false; busyDescription = "" }
        do { try await operation(store) }
        catch { errorMessage = error.localizedDescription }
    }

    private func reloadVaults(store: VaultStore, preferred: UUID? = nil) async throws {
        let updated = try await store.vaults(includeArchived: false)
        vaults = updated
        let requested = preferred ?? selectedVaultID
        let next = updated.first(where: { $0.id == requested })?.id ?? updated.first?.id
        if next != selectedVaultID { clearHistory() }
        selectedVaultID = next
        try await reloadHistory(store: store)
    }

    private func reloadHistory(store: VaultStore, preferred: UUID? = nil) async throws {
        guard let id = selectedVaultID else { clearHistory(); return }
        let updated: [Checkpoint]
        do {
            updated = try await store.checkpoints(vaultID: id)
            historyReadError = nil
        } catch {
            historyReadError = error.localizedDescription
            throw error
        }
        checkpoints = updated
        if let checkpoint = updated.first(where: { $0.id == preferred }) ?? updated.first {
            try await loadCheckpoint(checkpoint, store: store)
        } else { clearHistory() }
    }

    private func clearHistory() {
        historyReadError = nil
        checkpoints = []
        selectedCheckpointID = nil
        changes = []
        selectedChangePath = nil
        beforeText = nil
        afterText = nil
    }

    private func loadCheckpoint(_ checkpoint: Checkpoint, store: VaultStore) async throws {
        let result = try await store.changes(vaultID: checkpoint.vaultID, from: checkpoint.parentID, to: checkpoint.id)
        selectedCheckpointID = checkpoint.id
        changes = result
        selectedChangePath = nil
        beforeText = nil
        afterText = nil
        if let first = result.first { try await loadChange(first, store: store) }
    }

    private func loadChange(_ change: FileChange, store: VaultStore) async throws {
        guard let checkpoint = selectedCheckpoint else { return }
        var before: String?
        var after: String?
        if let parent = checkpoint.parentID, change.oldEntry?.kind == .file {
            before = try await store.text(vaultID: checkpoint.vaultID, checkpointID: parent, path: change.path)
        }
        if change.newEntry?.kind == .file {
            after = try await store.text(vaultID: checkpoint.vaultID, checkpointID: checkpoint.id, path: change.path)
        }
        selectedChangePath = change.path
        beforeText = before
        afterText = after
    }

    private func showNotice(_ message: String, url: URL? = nil) {
        notice = message
        noticeURL = url
    }

    private func refreshAfterCompletion(_ message: String, url: URL? = nil, refresh: @MainActor () async throws -> Void) async {
        showNotice(message, url: url)
        do { try await refresh() }
        catch {
            errorMessage = "\(message)\n\nThe action completed, but the view could not be refreshed. Do not repeat the action just to refresh it.\n\n\(error.localizedDescription)"
        }
    }
}
