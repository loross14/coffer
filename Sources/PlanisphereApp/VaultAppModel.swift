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
    let console = ConsoleConnectionModel()
    let activity = WorkspaceActivityModel()
    let memory: MemoryModel
    let reporting: ReportingModel
    let onboarding: OnboardingModel
    var activitySurface: ActivitySurface?
    var sidebarVisible = true
    var commandPalettePresented = false
    var workspaceConfirmationPresented = false
    var selectedSurface: VaultSurface = .history { didSet { activitySurface = nil } }
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
    var isHistoryLoading = false
    @ObservationIgnored private var historyTask: Task<Void, Never>?
    @ObservationIgnored private var historyLoadID = UUID()
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

    init(dataDirectory: URL? = nil) {
        if let dataDirectory { historyURL = dataDirectory }
        else if let path = ProcessInfo.processInfo.environment["PLANISPHERE_DATA_DIR"], !path.isEmpty {
            historyURL = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            historyURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Planisphere", isDirectory: true)
        }
        onboarding = OnboardingModel(root: historyURL)
        memory = MemoryModel(root: historyURL.appendingPathComponent("Memory", isDirectory: true))
        reporting = ReportingModel(stateURL: historyURL.appendingPathComponent("Reporting/claude-code.json"))
        console.beforeDisconnect = { [reporting] credential in await reporting.linkWillDisconnect(credential) }
        do { store = try VaultStore(rootURL: historyURL) }
        catch { startupError = error.localizedDescription }
    }

    var selectedVault: VaultRecord? { vaults.first { $0.id == selectedVaultID } }
    var canNavigateWorkspace: Bool {
        !onboarding.visible && (!isBusy || isHistoryLoading) && !checkpointReviewPresented && !localRecoveryReviewPresented && !workspaceConfirmationPresented && errorMessage == nil
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
            try await self.reloadVaults(store: store, loadHistory: false)
            self.onboarding.load(existing: self.vaults)
            if self.vaults.isEmpty { self.activitySurface = .memory }
        }
        if selectedVaultID != nil { startHistoryLoad() }
        if AppRelocationModel().consumePendingReregistration() { await completeRelocation() }
    }

    func refreshOnboardingRecovery() async {
        guard !onboarding.checking, !onboarding.busy else { return }
        onboarding.checking = true
        defer { onboarding.checking = false }
        if [.account, .agent].contains(onboarding.step) {
            await console.load()
            await memory.refreshAgents()
            reporting.bind(console.credential, verified: console.verified)
            while reporting.busy {
                guard !Task.isCancelled else { return }
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard !Task.isCancelled else { return }
            await reporting.refresh()
            onboarding.reconcile(accountVerified: console.verified, reports: memory.agentReports,
                                 reportingConnected: reporting.isConnected)
        }
        if onboarding.step == .existingVaults, onboarding.saved.recoveringExistingSetup == true {
            let knowledge = try? await store?.existingWorldKnowledge()
            onboarding.reconcile(accountVerified: console.verified, reports: memory.agentReports,
                                 reportingConnected: reporting.isConnected,
                                 knowledge: knowledge?.vault, knowledgeSources: knowledge?.sources ?? [])
        }
        if onboarding.step == .localModel {
            await memory.support.runtime.refresh()
            onboarding.reconcile(accountVerified: console.verified, reports: memory.agentReports,
                                 reportingConnected: reporting.isConnected,
                                 localModelInstalled: memory.support.runtime.record != nil)
        }
        if onboarding.step == .existingVaults { onboarding.discover(existing: vaults) }
    }

    func resumeOnboarding() {
        guard canNavigateWorkspace, onboarding.step != .complete else { return }
        onboarding.visible = true
    }

    func verifyExistingOnboardingAgent() async {
        if onboarding.saved.verificationStarted == nil {
            onboarding.saved.verificationStarted = Date()
            guard onboarding.persist() else { return }
        }
        await refreshOnboardingRecovery()
    }

    func connectOnboardingReporting() async {
        guard !onboarding.busy else { return }
        onboarding.busy = true
        reporting.bind(console.credential, verified: console.verified)
        while reporting.busy { try? await Task.sleep(for: .milliseconds(100)) }
        await reporting.refresh()
        if reporting.canConnect { await reporting.connect() }
        onboarding.busy = false
        await refreshOnboardingRecovery()
    }

    func addOnboardingSources() async {
        guard let store, !onboarding.busy else { return }
        await onboarding.registerSources(existing: vaults) { url in try await store.register(url: url) }
        vaults = (try? await store.vaults()) ?? vaults
    }

    func connectOnboardingAgent(_ host: AgentHost) async {
        guard !onboarding.busy else { return }
        onboarding.busy = true; defer { onboarding.busy = false }
        onboarding.selectedAgent = host
        onboarding.saved.agent = host.rawValue
        onboarding.saved.verificationStarted = Date()
        guard onboarding.persist() else { return }
        await memory.connect(host)
        if host == .claudeCode {
            reporting.bind(console.credential, verified: console.verified)
            await reporting.refresh()
            while reporting.busy { try? await Task.sleep(for: .milliseconds(100)) }
            if reporting.canConnect { await reporting.connect() }
        }
    }

    func finishOnboardingAgent() {
        let host = onboarding.selectedAgent
        guard onboarding.verifiedAgent(memory.agentReports[host]) else { return }
        if host == .claudeCode && !reporting.isConnected {
            onboarding.message = reporting.message ?? "Connect Console reporting before continuing."; return
        }
        onboarding.saved.progress.agentVerified(host.rawValue, successfulRun: true)
        onboarding.message = nil; _ = onboarding.persist()
        onboarding.discover(existing: vaults)
    }

    func createOnboardingKnowledge() async {
        guard let store, onboarding.consent, !onboarding.busy, let destination = onboarding.saved.destination else { return }
        onboarding.busy = true; onboarding.message = nil
        defer { onboarding.busy = false }
        guard onboarding.persist() else { return }
        do {
            let record = try await store.createWorldKnowledge(at: destination,
                sources: onboarding.saved.progress.sourceVaultIDs, purpose: onboarding.saved.purpose,
                operationID: onboarding.saved.operationID, consented: true)
            let checkpoints = try await store.checkpoints(vaultID: record.id)
            guard let latest = checkpoints.last,
                  try await store.text(vaultID: record.id, checkpointID: latest.id, path: "Start Here.md") != nil else {
                throw VaultStoreError.invalid("Knowledge was created, but its saved history could not be verified. Retry to finish.")
            }
            onboarding.saved.progress.knowledgeCreated(record.id, consented: true, verified: true)
            guard onboarding.persist() else { return }
            try await reloadVaults(store: store, preferred: record.id)
            activitySurface = nil
            await memory.refreshAgents()
            onboarding.visible = false
            notice = "Your World Knowledge map is ready. Open Start Here.md to explore your sources."
            noticeURL = record.url.appendingPathComponent("Start Here.md")
        } catch { onboarding.message = error.localizedDescription }
    }

    /// The first launch from Applications after the app moved itself: launchd and the agent hooks
    /// still name the old bundle, so register the Local model's login item and the Memory hooks again.
    func completeRelocation() async {
        let runtime = memory.support.runtime
        await runtime.refresh()
        let model = await runtime.reregisterAfterMove()
        let hosts = await memory.reconnectInstalledHosts()
        var parts: [String] = []
        if model { parts.append("the Local model") }
        if !hosts.isEmpty { parts.append("Memory for " + hosts.map(\.name).joined(separator: " and ")) }
        guard !parts.isEmpty else { return }
        memory.message = "Planisphere now runs from Applications. Reconnected " + parts.joined(separator: " and ") + "."
    }

    func selectVault(_ id: UUID?) {
        guard (!isBusy || isHistoryLoading), id != selectedVaultID else { return }
        activitySurface = nil
        selectedVaultID = id
        checkpointMessage = ""
        clearHistory()
        resetPruningForSelectedVault()
        startHistoryLoad()
    }

    func selectCheckpoint(_ checkpoint: Checkpoint) {
        guard !isBusy, checkpoint.id != selectedCheckpointID else { return }
        startHistoryLoad(checkpointID: checkpoint.id)
    }

    func retryHistory() {
        guard !isBusy, selectedVaultID != nil else { return }
        startHistoryLoad()
    }

    func selectChange(_ change: FileChange) {
        guard !isBusy, change.path != selectedChangePath else { return }
        startHistoryLoad(checkpointID: selectedCheckpointID, changePath: change.path)
    }

    func cancelHistoryLoad() { historyTask?.cancel() }

    private func startHistoryLoad(checkpointID: UUID? = nil, changePath: String? = nil) {
        historyTask?.cancel()
        let request = UUID()
        historyLoadID = request
        guard let store, let vaultID = selectedVaultID else {
            isHistoryLoading = false; isBusy = false; busyDescription = ""
            return
        }
        isHistoryLoading = true; isBusy = true; busyDescription = "Reading local history"
        historyReadError = nil
        historyTask = Task {
            defer {
                if historyLoadID == request {
                    isHistoryLoading = false; isBusy = false; busyDescription = ""; historyTask = nil
                }
            }
            do {
                let view = try await store.historyView(vaultID: vaultID, checkpointID: checkpointID, changePath: changePath)
                try Task.checkCancellation()
                guard historyLoadID == request, selectedVaultID == vaultID else { return }
                applyHistory(view)
            } catch {
                guard historyLoadID == request, selectedVaultID == vaultID else { return }
                clearHistory()
                historyReadError = error is CancellationError ? "History loading was cancelled. Retry when you are ready." : error.localizedDescription
            }
        }
    }

    private func applyHistory(_ view: VaultStore.HistoryView) {
        historyReadError = nil
        localMutationReceipts = view.mutationReceipts
        localMutationReadError = view.recoveryError.map { "Local pruning recovery records could not be read. Applying is held until these records are available. " + $0 }
        checkpoints = view.checkpoints
        selectedCheckpointID = view.selectedCheckpointID
        changes = view.changes
        selectedChangePath = view.selectedChangePath
        beforeText = view.beforeText
        afterText = view.afterText
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

    private func reloadVaults(store: VaultStore, preferred: UUID? = nil, loadHistory: Bool = true) async throws {
        let updated = try await store.vaults(includeArchived: false)
        let changedList = updated.map(\.id) != vaults.map(\.id)
        vaults = updated
        // The agents' vault reader reads these vaults; Check setup shows which, so refresh it when the list changes.
        if changedList, memory.agentStatus.values.contains(where: { $0 == "installed" || $0 == "disabled" }) {
            Task { await memory.refreshAgents() }
        }
        let requested = preferred ?? selectedVaultID
        let next = updated.first(where: { $0.id == requested })?.id ?? updated.first?.id
        let changedVault = next != selectedVaultID
        if changedVault { clearHistory() }
        selectedVaultID = next
        if changedVault { resetPruningForSelectedVault() }
        if loadHistory { try await reloadHistory(store: store) }
    }

    private func reloadHistory(store: VaultStore, preferred: UUID? = nil) async throws {
        guard let id = selectedVaultID else { clearHistory(); return }
        do { applyHistory(try await store.historyView(vaultID: id, checkpointID: preferred)) }
        catch { historyReadError = error.localizedDescription; throw error }
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
