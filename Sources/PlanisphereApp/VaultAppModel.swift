import AppKit
import Foundation
import Observation
import PlanisphereCore
import PlanisphereGrapheine
import UniformTypeIdentifiers

enum VaultSurface: String, CaseIterable {
    case history = "History"
    case graph = "Graph"
    case pruning = "Pruning"
}

private struct PruningAttempt: Codable {
    let packetDigest: String
    let recoveryCheckpointID: UUID
    let startedAt: String
}

@MainActor
@Observable
final class VaultAppModel {
    var sidebarVisible = true
    var commandPalettePresented = false
    var workspaceConfirmationPresented = false
    var selectedSurface: VaultSurface = .history
    var vaults: [VaultRecord] = []
    var selectedVaultID: UUID?
    var checkpoints: [Checkpoint] = []
    var selectedCheckpointID: UUID?
    var changes: [FileChange] = []
    var selectedChangePath: String?
    var beforeText: String?
    var afterText: String?
    var checkpointMessage = ""
    var checkpointReviewPresented = false
    var checkpointMode: CheckpointMode = .markdownOnly
    var checkpointPlan: CheckpointPlan?
    var checkpointPlanError: String?
    private var checkpointReviewVaultID: UUID?
    var historyReadError: String?
    var pruningScan: PruningScan?
    var pruningError: String?
    var pruningRecoveryWarning: String?
    var selectedPruningGroupID: String?
    var selectedPruningQuestionID: String?
    var selectedPruningNotePath: String?
    var pruningNoteText: String?
    var pruningNoteError: String?
    var authorityPolicyURL: URL?
    var pruningPacket: PruningPacket?
    var localPruningPacket: LocalPruningPacket?
    var localReviewHold: String?
    var selectedKeeperPath: String?
    var selectedLocalChangePath: String?
    var localMutationReceipts: [MarkdownMutationReceipt] = []
    var localMutationReadError: String?
    var localRecoveryReviewPresented = false
    var selectedPruningChangePath: String?
    var permissionReceiptURL: URL?
    var isBusy = false
    var busyDescription = ""
    var errorMessage: String?
    var notice: String?
    var noticeURL: URL?
    let historyURL: URL

    @ObservationIgnored private var store: VaultStore?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var startupError: String?
    @ObservationIgnored private let grapheine = GrapheineService()

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
    var canNavigateWorkspace: Bool {
        !isBusy && !checkpointReviewPresented && !localRecoveryReviewPresented && !workspaceConfirmationPresented && errorMessage == nil
    }
    func toggleCommandPalette() {
        guard canNavigateWorkspace else { return }
        if !commandPalettePresented { NSApp.keyWindow?.makeFirstResponder(nil) }
        commandPalettePresented.toggle()
    }
    var selectedCheckpoint: Checkpoint? { checkpoints.first { $0.id == selectedCheckpointID } }
    var selectedChange: FileChange? { changes.first { $0.path == selectedChangePath } }
    var selectedPruningGroup: PruningGroup? { pruningScan?.groups.first { $0.id == selectedPruningGroupID } }
    var selectedPruningQuestion: PruningQuestion? { pruningScan?.authority.questions.first { $0.id == selectedPruningQuestionID } }
    var selectedPruningChange: PruningChange? { pruningPacket?.changes.first { $0.path == selectedPruningChangePath } }
    var selectedLocalChange: PruningChange? { localPruningPacket?.changes.first { $0.path == selectedLocalChangePath } }
    var unresolvedLocalMutation: MarkdownMutationReceipt? {
        localMutationReceipts.first { $0.status != .completed && $0.recoveryAcknowledgedAt == nil }
    }
    var canPrepareLocalPruning: Bool {
        !isBusy && authorityPolicyURL == nil && pruningError == nil &&
        selectedKeeperPath.map { selectedPruningGroup?.members.contains($0) == true } == true
    }
    var canApplyLocalPruning: Bool {
        !isBusy && authorityPolicyURL == nil && historyReadError == nil && pruningError == nil &&
        localMutationReadError == nil && unresolvedLocalMutation == nil &&
        localPruningPacket != nil && localPruningPacket?.vaultPath == selectedVault?.path &&
        localPruningPacket?.keepPath == selectedKeeperPath
    }
    var canApplyPruning: Bool {
        !isBusy && historyReadError == nil && pruningError == nil && authorityPolicyURL != nil &&
        localMutationReadError == nil && unresolvedLocalMutation == nil &&
        permissionReceiptURL != nil && pruningPacket != nil && pruningPacket?.vaultPath == selectedVault?.path
    }

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
                self.resetPruningForSelectedVault()
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
        checkpointReviewVaultID = vault.id
        checkpointReviewPresented = true
        reviewCheckpointMode(.markdownOnly)
    }

    func reviewCheckpointMode(_ mode: CheckpointMode) {
        guard !isBusy, let vault = selectedVault, vault.id == checkpointReviewVaultID else { return }
        checkpointMode = mode
        checkpointPlan = nil
        checkpointPlanError = nil
        Task {
            await perform("Reviewing checkpoint contents") { store in
                do {
                    let plan = try await store.checkpointPlan(vaultID: vault.id, mode: mode)
                    guard self.checkpointReviewPresented, self.checkpointReviewVaultID == vault.id else { return }
                    self.checkpointPlan = plan
                } catch {
                    self.checkpointPlanError = error.localizedDescription
                }
            }
        }
    }

    func cancelCheckpointReview() {
        guard !isBusy else { return }
        checkpointReviewPresented = false
        checkpointPlan = nil
        checkpointPlanError = nil
        checkpointReviewVaultID = nil
    }

    func saveReviewedCheckpoint() {
        guard !isBusy, historyReadError == nil, let vault = selectedVault,
              vault.id == checkpointReviewVaultID, let plan = checkpointPlan,
              plan.mode == checkpointMode else { return }
        let message = checkpointMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            await perform("Saving local checkpoint") { store in
                let checkpoint: Checkpoint
                do {
                    checkpoint = try await store.createCheckpoint(vaultID: vault.id,
                        message: message.isEmpty ? "Checkpoint" : message, scope: plan.scope)
                } catch {
                    self.checkpointPlan = nil
                    self.checkpointPlanError = "The checkpoint was not saved. Review the contents again before retrying.\n\n\(error.localizedDescription)"
                    return
                }
                self.checkpointReviewPresented = false
                self.checkpointPlan = nil
                self.checkpointReviewVaultID = nil
                self.checkpointMessage = ""
                let scopeNotice: String
                switch plan.mode {
                case .markdownOnly: scopeNotice = " Markdown Only: attachments, settings, symbolic links, and excluded content were not saved."
                case .vaultContent: scopeNotice = " Vault Content exclusions were applied; excluded content was not saved."
                case .wholeFolder: scopeNotice = ""
                }
                let completion = "Checkpoint saved on this Mac at \(checkpoint.createdAt.formatted(date: .omitted, time: .standard)). \(self.checkpointContentSummary(checkpoint)) preserved.\(scopeNotice)"
                await self.refreshAfterCompletion(completion) {
                    try await self.reloadHistory(store: store, preferred: checkpoint.id)
                }
            }
        }
    }

    func restoreCopy() {
        guard !isBusy, let vault = selectedVault, let checkpoint = selectedCheckpoint,
              let url = newFolderDestination(title: "Restore a New Copy", prompt: "Restore Copy", name: "\(vault.name) — Recovered",
                  message: "Restore this checkpoint into a new folder. Your original vault and its newer work remain untouched. The recovered copy will be added as a separate vault." + checkpointScopeWarning(checkpoint) + (checkpoint.symbolicLinkCount > 0 ? " Symbolic links are recreated with their saved targets; they can refer outside the recovered folder. Referenced contents are not copied through those links." : "")) else { return }
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
                  message: "Export the latest saved checkpoint and all retained history into a new folder. Changes since the last checkpoint are not included. The working vault stays in place." + (checkpoints.first.map(checkpointScopeWarning) ?? "") + ((checkpoints.first?.symbolicLinkCount ?? 0) > 0 ? " Symbolic links are exported as references, including targets outside the folder; referenced contents are not copied through them." : "")) else { return }
        Task {
            await perform("Exporting saved checkpoint and history") { store in
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

    func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }

    func checkpointContentSummary(_ checkpoint: Checkpoint) -> String {
        let files = "\(checkpoint.fileCount) " + (checkpoint.captureScope?.mode == .markdownOnly ? "Markdown notes" : "files")
        return checkpoint.symbolicLinkCount == 0 ? files : "\(files) · \(checkpoint.symbolicLinkCount) symbolic links"
    }

    func checkpointModeTitle(_ mode: CheckpointMode) -> String {
        switch mode {
        case .markdownOnly: "Markdown Only"
        case .vaultContent: "Vault Content"
        case .wholeFolder: "Whole Folder"
        }
    }

    private func checkpointScopeWarning(_ checkpoint: Checkpoint) -> String {
        switch checkpoint.captureScope?.mode ?? .wholeFolder {
        case .markdownOnly:
            " This is a Markdown Only checkpoint. Its copy contains saved notes, without attachments, settings, symbolic links, or excluded content."
        case .vaultContent:
            " This is a Vault Content checkpoint. Excluded content was not saved and will not appear in its copy."
        case .wholeFolder:
            ""
        }
    }

    // MARK: - Grapheine pruning

    func scanPruning() {
        guard !isBusy, let vault = selectedVault else { return }
        let policy = authorityPolicyURL
        Task {
            await perform("Scanning this vault with Grapheine") { _ in
                self.clearPreparedPruning()
                self.selectedKeeperPath = nil
                self.pruningError = nil
                do {
                    let scan = try await self.grapheine.scan(vaultURL: vault.url, policyURL: policy)
                    self.pruningScan = scan
                    self.selectedPruningGroupID = scan.groups.first?.id
                    self.selectedPruningQuestionID = scan.groups.isEmpty ? scan.authority.questions.first?.id : nil
                    self.clearPruningNote()
                } catch {
                    self.pruningError = error.localizedDescription
                    throw error
                }
            }
        }
    }

    func chooseAuthorityPolicy() {
        guard !isBusy, let vault = selectedVault else { return }
        guard let url = chooseJSON(title: "Use an Existing Authority Policy", prompt: "Use Policy",
            message: "Choose an independently provisioned Grapheine policy for this vault. Planisphere remembers its location; it does not create keys, trust a new signer or edit the policy.") else { return }
        UserDefaults.standard.set(url.absoluteString, forKey: policyPreferenceKey(vault.id))
        authorityPolicyURL = url
        clearPruningResults()
    }

    func forgetAuthorityPolicy() {
        guard !isBusy, let vault = selectedVault else { return }
        UserDefaults.standard.removeObject(forKey: policyPreferenceKey(vault.id))
        authorityPolicyURL = nil
        clearPruningResults()
    }

    func selectPruningGroup(_ group: PruningGroup) {
        guard !isBusy else { return }
        selectedPruningGroupID = group.id
        selectedPruningQuestionID = nil
        selectedKeeperPath = nil
        clearPreparedPruning()
        clearPruningNote()
    }

    func selectPruningQuestion(_ question: PruningQuestion) {
        guard !isBusy else { return }
        selectedPruningQuestionID = question.id
        selectedPruningGroupID = nil
        selectedKeeperPath = nil
        clearPreparedPruning()
        clearPruningNote()
    }

    func readPruningNote(_ path: String) {
        guard !isBusy, let vault = selectedVault else { return }
        Task {
            await perform("Reading candidate note") { _ in
                self.selectedPruningNotePath = path
                self.pruningNoteText = nil
                self.pruningNoteError = nil
                do { self.pruningNoteText = try await self.grapheine.readNote(vaultURL: vault.url, path: path) }
                catch { self.pruningNoteError = error.localizedDescription; throw error }
            }
        }
    }

    func chooseKeeper(_ path: String) {
        guard !isBusy, authorityPolicyURL == nil, selectedPruningGroup?.members.contains(path) == true else { return }
        selectedKeeperPath = path
        clearPreparedPruning()
    }

    func prepareLocalPruning() {
        guard canPrepareLocalPruning, let vault = selectedVault, let group = selectedPruningGroup,
              let keeper = selectedKeeperPath, let scan = pruningScan else { return }
        Task {
            await perform("Checking preservation and preparing changes") { _ in
                self.clearPreparedPruning()
                do {
                    let packet = try await self.grapheine.prepareLocal(vaultURL: vault.url, members: group.members,
                        keepPath: keeper, fingerprint: scan.fingerprint)
                    self.localPruningPacket = packet
                    self.selectedLocalChangePath = packet.changes.first?.path
                } catch {
                    self.localReviewHold = error.localizedDescription
                    throw error
                }
            }
        }
    }

    func applyLocalPruning() {
        guard canApplyLocalPruning, let vault = selectedVault, let packet = localPruningPacket else { return }
        Task {
            await perform("Rechecking the reviewed Markdown changes") { store in
                let verified: LocalPruningPacket
                do { verified = try await self.grapheine.verifyLocal(vaultURL: vault.url, packet: packet) }
                catch {
                    self.clearPreparedPruning()
                    self.pruningError = "The review could not be verified. No local pruning was started. Scan and review again. \(error.localizedDescription)"
                    throw error
                }
                let scope = try CheckpointScope.markdownOnly(excludedPaths: verified.scope.excludedPaths,
                    sourceConfigurationSHA256: verified.scope.sourceConfigurationSHA256)
                let mutations = try verified.changes.map { change -> MarkdownMutation in
                    guard let before = verified.originals[change.path] else {
                        throw GrapheineError.invalidResponse("A reviewed file has no preserved original.")
                    }
                    return MarkdownMutation(path: change.path, before: before, after: change.after.map { Data($0.utf8) })
                }
                let plan = try MarkdownMutationPlan(vaultID: vault.id, vaultPath: vault.path, scope: scope,
                    expectedFiles: verified.files, changes: mutations, reviewedPacket: packet.rawData)
                self.busyDescription = "Saving recovery history and applying reviewed changes"
                do {
                    let receipt = try await store.applyMarkdownMutation(plan)
                    self.clearPruningResults()
                    if receipt.status == .completed {
                        let completion = "Reviewed changes applied locally. Before and after checkpoints are retained. Receipt \(receipt.id.uuidString.prefix(8)). Scan again before another review."
                        await self.refreshAfterCompletion(completion) {
                            try await self.reloadHistory(store: store, preferred: receipt.afterCheckpointID ?? receipt.beforeCheckpointID)
                        }
                    } else {
                        self.pruningError = "Pruning needs recovery review. Inspect the working folder and the saved pre-change checkpoint before another attempt."
                        self.errorMessage = receipt.error ?? self.pruningError
                        try await self.reloadHistory(store: store, preferred: receipt.beforeCheckpointID)
                    }
                } catch {
                    self.clearPreparedPruning()
                    self.pruningError = "Local pruning did not return a confirmed completed result. Inspect recovery history before retrying."
                    self.errorMessage = "\(self.pruningError ?? "")\n\n\(error.localizedDescription)"
                    do { try await self.reloadHistory(store: store) }
                    catch { self.historyReadError = error.localizedDescription }
                }
            }
        }
    }

    func openLocalRecovery(_ receipt: MarkdownMutationReceipt) {
        guard !isBusy else { return }
        localRecoveryReviewPresented = false
        Task {
            await perform("Opening the pre-change checkpoint") { store in
                self.selectedSurface = .history
                try await self.reloadHistory(store: store, preferred: receipt.beforeCheckpointID)
                self.showNotice("Inspect this pre-change checkpoint. Restore Copy creates a separate recovered vault; it does not overwrite the interrupted working folder or clear its recovery record.")
            }
        }
    }

    func acknowledgeLocalRecovery(_ receipt: MarkdownMutationReceipt) {
        guard !isBusy, let vault = selectedVault,
              localMutationReceipts.contains(where: { $0.id == receipt.id && $0.status != .completed }) else { return }
        Task {
            await perform("Recording your recovery review") { store in
                _ = try await store.acknowledgeMutationRecovery(vaultID: vault.id, operationID: receipt.id)
                self.localRecoveryReviewPresented = false
                self.clearPruningResults()
                await self.refreshAfterCompletion("Recovery review recorded. The earlier operation remains interrupted; its checkpoints and recovery records are retained. Scan again to prepare a new proposal.") {
                    try await self.reloadHistory(store: store, preferred: receipt.beforeCheckpointID)
                }
            }
        }
    }

    func preparePruning() {
        guard !isBusy, pruningError == nil, let vault = selectedVault,
              let policy = authorityPolicyURL, let question = selectedPruningQuestion,
              question.state == "resolved", question.writeState == "needs_exact_write_permission" else { return }
        Task {
            await perform("Preparing exact changes for review") { _ in
                self.clearPreparedPruning()
                do {
                    let packet = try await self.grapheine.prepare(vaultURL: vault.url, policyURL: policy,
                        scope: question.scope, question: question.question)
                    self.pruningPacket = packet
                    self.selectedPruningChangePath = packet.changes.first?.path
                } catch {
                    self.pruningError = "No changes were prepared. \(error.localizedDescription)"
                    throw error
                }
            }
        }
    }

    func choosePruningPermission() {
        guard !isBusy, pruningPacket != nil else { return }
        guard let url = chooseJSON(title: "Load Signed Permission", prompt: "Load Permission",
            message: "Choose a signed permission outside this vault for the exact packet shown here. Selecting a file does not verify or grant permission; Grapheine checks its signature, scope, expiry and exact packet again when you apply.") else { return }
        guard !isInsideSelectedVault(url) else {
            errorMessage = "Keep signed permission outside the working vault. Adding a receipt inside the vault changes the files the packet was prepared against. Choose a receipt stored elsewhere, then scan and prepare again if the vault changed."
            return
        }
        permissionReceiptURL = url
    }

    func exportPruningPacket() {
        guard !isBusy, let packet = pruningPacket else { return }
        let panel = NSSavePanel()
        panel.title = "Export Exact Review Packet"
        panel.message = "Save outside the working vault to keep the reviewed files unchanged. This packet contains source content and original file bytes; share it only with your intended signer or reviewer."
        panel.nameFieldStringValue = "pruning-\(packet.digest.prefix(12)).json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard !isInsideSelectedVault(url) else {
            errorMessage = "Choose a location outside the working vault. Saving a packet inside it would change the vault and invalidate this review. No packet was exported."
            return
        }
        do {
            try writePrivatePacket(packet.rawData, to: url)
            showNotice("Exact review packet exported. Exporting does not authorize the changes.", url: url)
        } catch { errorMessage = error.localizedDescription }
    }

    private func isInsideSelectedVault(_ url: URL) -> Bool {
        guard let vault = selectedVault else { return true }
        func contains(_ candidate: URL, _ root: URL) -> Bool {
            let path = candidate.standardizedFileURL.path
            let rootPath = root.standardizedFileURL.path
            return path == rootPath || path.hasPrefix(rootPath + "/")
        }
        return contains(url, vault.url) || contains(url.resolvingSymlinksInPath(), vault.url.resolvingSymlinksInPath())
    }

    private func writePrivatePacket(_ data: Data, to destination: URL) throws {
        let manager = FileManager.default
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".planisphere-packet-\(UUID().uuidString)")
        guard manager.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { try? manager.removeItem(at: temporary) }
        let file = try FileHandle(forWritingTo: temporary)
        do { try file.write(contentsOf: data); try file.close() }
        catch { try? file.close(); throw error }
        if manager.fileExists(atPath: destination.path) {
            _ = try manager.replaceItemAt(destination, withItemAt: temporary, options: .usingNewMetadataOnly)
        } else {
            try manager.moveItem(at: temporary, to: destination)
        }
    }

    func applyPruning() {
        guard canApplyPruning, let vault = selectedVault, let policy = authorityPolicyURL,
              let packet = pruningPacket, let receipt = permissionReceiptURL else { return }
        Task {
            await perform("Saving recovery checkpoint before applying") { store in
                let recovery = try await store.createCheckpoint(vaultID: vault.id,
                    message: "Before pruning \(packet.digest.prefix(12))")
                try self.rememberPruningAttempt(vaultID: vault.id, digest: packet.digest, checkpointID: recovery.id)
                self.busyDescription = "Verifying and applying reviewed changes"
                let result: PruningApplyResult
                do {
                    result = try await self.grapheine.apply(vaultURL: vault.url, policyURL: policy, packet: packet, receiptURL: receipt)
                } catch {
                    self.pruningRecoveryWarning = self.pruningAttemptWarning(vaultID: vault.id)
                    self.clearPreparedPruning()
                    self.pruningError = "Application was not confirmed. Inspect the reported result before retrying; a recovery checkpoint was saved at \(recovery.createdAt.formatted(date: .abbreviated, time: .standard))."
                    self.showNotice("A pre-change recovery checkpoint was saved. Grapheine did not return a confirmed successful result.")
                    self.errorMessage = "\(self.pruningError ?? "")\n\n\(error.localizedDescription)"
                    do { try await self.reloadHistory(store: store, preferred: recovery.id) }
                    catch { self.historyReadError = error.localizedDescription }
                    return
                }

                UserDefaults.standard.removeObject(forKey: self.pruningAttemptKey(vault.id))
                UserDefaults.standard.synchronize()
                self.pruningRecoveryWarning = nil
                self.clearPruningResults()
                let completion = "Reviewed changes applied in commit \(result.commit.prefix(12)). The pre-change checkpoint is retained. Scan again before preparing another proposal."
                self.showNotice(completion)
                self.busyDescription = "Saving checkpoint of applied changes"
                do {
                    let after = try await store.createCheckpoint(vaultID: vault.id,
                        message: "After pruning \(packet.digest.prefix(12))")
                    await self.refreshAfterCompletion(completion) {
                        try await self.reloadHistory(store: store, preferred: after.id)
                    }
                    if let message = result.message, !message.isEmpty {
                        self.showNotice("\(completion) \(message)")
                    }
                } catch {
                    self.errorMessage = "\(completion)\n\nThe post-change checkpoint could not be saved. Do not apply the packet again. The pre-change recovery checkpoint is \(recovery.id.uuidString).\n\n\(error.localizedDescription)"
                    do { try await self.reloadHistory(store: store, preferred: recovery.id) }
                    catch { self.historyReadError = error.localizedDescription }
                }
            }
        }
    }

    private func chooseJSON(title: String, prompt: String, message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title; panel.prompt = prompt; panel.message = message
        panel.canChooseDirectories = false; panel.canChooseFiles = true
        panel.allowsMultipleSelection = false; panel.allowedContentTypes = [.json]
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func policyPreferenceKey(_ vaultID: UUID) -> String { "authority-policy.\(vaultID.uuidString)" }

    private func pruningAttemptKey(_ vaultID: UUID) -> String { "pruning-in-flight.\(vaultID.uuidString)" }

    private func rememberPruningAttempt(vaultID: UUID, digest: String, checkpointID: UUID) throws {
        let attempt = PruningAttempt(packetDigest: digest, recoveryCheckpointID: checkpointID,
            startedAt: Date().formatted(.iso8601))
        let encoded = try JSONEncoder().encode(attempt)
        UserDefaults.standard.set(String(decoding: encoded, as: UTF8.self), forKey: pruningAttemptKey(vaultID))
        guard UserDefaults.standard.synchronize() else {
            throw GrapheineError.unavailable("The recovery reminder could not be saved. Pruning was not started. Recovery checkpoint: \(checkpointID.uuidString).")
        }
    }

    private func pruningAttemptWarning(vaultID: UUID) -> String? {
        guard let saved = UserDefaults.standard.string(forKey: pruningAttemptKey(vaultID)) else { return nil }
        let message = "Previous pruning attempt has no confirmed result. Inspect the vault and local history before retrying."
        guard let attempt = try? JSONDecoder().decode(PruningAttempt.self, from: Data(saved.utf8)) else {
            return "\(message) The saved reminder could not be read; look for a Before pruning checkpoint in History."
        }
        return "\(message) Recovery checkpoint: \(attempt.recoveryCheckpointID.uuidString). Packet: \(attempt.packetDigest.prefix(12)). Started: \(attempt.startedAt)."
    }

    private func resetPruningForSelectedVault() {
        clearPruningResults()
        localMutationReceipts = []
        localMutationReadError = nil
        localRecoveryReviewPresented = false
        pruningRecoveryWarning = selectedVaultID.flatMap { pruningAttemptWarning(vaultID: $0) }
        authorityPolicyURL = selectedVaultID.flatMap { id in
            UserDefaults.standard.string(forKey: policyPreferenceKey(id)).flatMap(URL.init(string:))
        }
    }

    private func clearPreparedPruning() {
        pruningPacket = nil
        localPruningPacket = nil
        localReviewHold = nil
        selectedLocalChangePath = nil
        selectedPruningChangePath = nil
        permissionReceiptURL = nil
    }

    private func clearPruningNote() {
        selectedPruningNotePath = nil
        pruningNoteText = nil
        pruningNoteError = nil
    }

    private func clearPruningResults() {
        pruningScan = nil
        pruningError = nil
        selectedPruningGroupID = nil
        selectedPruningQuestionID = nil
        selectedKeeperPath = nil
        clearPreparedPruning()
        clearPruningNote()
    }

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
        let changedVault = next != selectedVaultID
        if changedVault { clearHistory() }
        selectedVaultID = next
        if changedVault { resetPruningForSelectedVault() }
        try await reloadHistory(store: store)
    }

    private func reloadHistory(store: VaultStore, preferred: UUID? = nil) async throws {
        guard let id = selectedVaultID else { clearHistory(); return }
        do {
            localMutationReceipts = try await store.mutationReceipts(vaultID: id)
            localMutationReadError = nil
        } catch {
            localMutationReadError = "Local pruning recovery records could not be read. Applying is held until these records are available. \(error.localizedDescription)"
        }
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
        if let parent = checkpoint.parentID, let kind = change.oldEntry?.kind, kind == .file || kind == .symbolicLink {
            before = try await store.text(vaultID: checkpoint.vaultID, checkpointID: parent, path: change.path)
        }
        if let kind = change.newEntry?.kind, kind == .file || kind == .symbolicLink {
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
