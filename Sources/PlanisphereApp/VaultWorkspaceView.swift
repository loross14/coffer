import SwiftUI
import PlanisphereCore

struct VaultWorkspaceView: View {
    @Bindable var model: VaultAppModel
    @State private var confirmRemoval = false
    @State private var showSavedScope = false

    var body: some View {
        GeometryReader { bounds in
            HStack(spacing: 0) {
                sidebar.frame(width: 240, height: bounds.size.height, alignment: .top)
                Divider()
                workspace.frame(width: max(0, bounds.size.width - 241), height: bounds.size.height, alignment: .top)
            }
            .frame(width: bounds.size.width, height: bounds.size.height)
        }
        .tint(Color(red: 0.26, green: 0.39, blue: 0.72))
        .sheet(isPresented: $model.checkpointReviewPresented) {
            CheckpointReviewView(model: model)
                .interactiveDismissDisabled(model.isBusy)
        }
        .sheet(isPresented: $model.localRecoveryReviewPresented) {
            LocalPruningRecoveryView(model: model)
                .interactiveDismissDisabled(model.isBusy)
        }
        .alert("Planisphere needs attention", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .confirmationDialog("Remove \(model.selectedVault?.name ?? "vault") from Planisphere?", isPresented: $confirmRemoval, titleVisibility: .visible) {
            Button("Remove from List", role: .destructive) { model.removeSelectedVault() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your folder and its local history will be kept. Add the same folder again to return to its history.")
        }
    }

    private var workspace: some View {
            VStack(spacing: 0) {
                if let receipt = model.unresolvedLocalMutation {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 5) {
                            Text("A local pruning attempt needs recovery review.").font(.callout.weight(.semibold))
                            Text("Receipt \(receipt.id.uuidString). Inspect the working folder and pre-change checkpoint before retrying.")
                                .font(.caption).textSelection(.enabled)
                            if let error = receipt.error { Text(error).font(.caption).lineLimit(3) }
                        }
                        Spacer(minLength: 4)
                        Button("Review Recovery…") { model.localRecoveryReviewPresented = true }.disabled(model.isBusy)
                    }
                    .padding(.horizontal, 22).padding(.vertical, 12)
                    .background(Color.orange.opacity(0.08)).fixedSize(horizontal: false, vertical: true)
                } else if let error = model.localMutationReadError {
                    HStack(alignment: .top, spacing: 12) {
                        Text(error).font(.caption).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Retry Recovery Records") { model.retryHistory() }.disabled(model.isBusy)
                    }
                    .padding(.horizontal, 22).padding(.vertical, 12)
                    .background(Color.orange.opacity(0.08)).fixedSize(horizontal: false, vertical: true)
                }
                if let warning = model.pruningRecoveryWarning {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                        Text(warning).font(.caption).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 22).padding(.vertical, 12)
                    .background(Color.orange.opacity(0.08))
                    .fixedSize(horizontal: false, vertical: true)
                }
                if let notice = model.notice { noticeBanner(notice).fixedSize(horizontal: false, vertical: true) }
                if let vault = model.selectedVault {
                    vaultDetail(vault).frame(minHeight: 0, maxHeight: .infinity)
                } else {
                    welcome
                }
                if model.isBusy {
                    Divider()
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(model.busyDescription).font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Text("Keep Planisphere open until this finishes.").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 24).padding(.vertical, 12)
                }
            }
            .background(Color(nsColor: .windowBackgroundColor))
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                Image(systemName: "globe.americas.fill")
                    .font(.system(size: 27, weight: .light)).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Planisphere").font(.headline)
                    Text("Your vaults, on your Mac").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 18).padding(.top, 24).padding(.bottom, 27)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Text("VAULTS").font(.system(size: 10, weight: .semibold)).tracking(1.2).foregroundStyle(.secondary)
                Spacer()
                Text("\(model.vaults.count)").font(.caption).foregroundStyle(.tertiary)
                Menu {
                    Button("Add Existing Vault…", systemImage: "folder.badge.plus") { model.chooseExistingVault() }
                    Button("Create New Vault…", systemImage: "plus.square") { model.chooseNewVault() }
                } label: {
                    Image(systemName: "plus").font(.system(size: 13, weight: .medium))
                }
                .menuStyle(.borderlessButton).frame(width: 24, height: 24).disabled(model.isBusy)
                .help("Add or create a local vault")
            }
            .padding(.horizontal, 18).padding(.bottom, 10)
            .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(model.vaults) { vault in
                        Button { model.selectVault(vault.id) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "folder.fill").font(.system(size: 17)).foregroundStyle(model.selectedVaultID == vault.id ? Color.accentColor : Color.secondary)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(vault.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                    Text(vault.restoredFrom == nil ? "Local vault" : "Recovered copy").font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 2)
                            }
                            .padding(.horizontal, 11).padding(.vertical, 11)
                            .contentShape(Rectangle())
                            .background(model.selectedVaultID == vault.id ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain).disabled(model.isBusy)
                        .accessibilityLabel("\(vault.name), local vault")
                        .accessibilityIdentifier("vault-row-\(vault.id.uuidString)")
                    }
                }
                .padding(.horizontal, 9)
            }
            .frame(minHeight: 0, maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 10) {
                Label("Local by default", systemImage: "internaldrive").font(.system(size: 12, weight: .medium))
                Text("No account. No uploads. Your history is stored on this Mac.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Show history location") { model.reveal(model.historyURL) }
                    .buttonStyle(.link).font(.caption)
                Divider().padding(.vertical, 5)
                Label("Managed, when you choose", systemImage: "cloud")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Text("Optional managed storage is planned. Nothing is uploaded by this app.")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(18)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.45))
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 35)
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 46, weight: .ultraLight)).foregroundStyle(.tint)
                .padding(.bottom, 27)
            Text("A place for your vaults.\nA way back to your work.")
                .font(.system(size: 35, weight: .semibold, design: .rounded)).tracking(-1.1)
                .fixedSize(horizontal: false, vertical: true)
            Text("Keep working in your favorite editor. Planisphere keeps\nlocal checkpoints you can inspect, recover and take with you.")
                .font(.system(size: 15)).foregroundStyle(.secondary).lineSpacing(5)
                .padding(.top, 18)
            HStack(spacing: 12) {
                Button("Add Existing Vault…", systemImage: "folder.badge.plus") { model.chooseExistingVault() }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("add-existing-vault")
                Button("Create New Vault…", systemImage: "plus") { model.chooseNewVault() }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("create-new-vault")
            }
            .controlSize(.large).padding(.top, 28).disabled(model.isBusy)
            HStack(alignment: .top, spacing: 32) {
                feature("Keep your files", symbol: "folder", detail: "Use an existing folder.\nNo forced migration.")
                feature("Save a moment", symbol: "clock.arrow.circlepath", detail: "Explicit checkpoints.\nReadable changes.")
                feature("Recover a copy", symbol: "arrow.uturn.backward", detail: "Restore to a new folder.\nKeep the original intact.")
            }
            .padding(.top, 55)
            Spacer(minLength: 45)
            Text("Local history helps with unwanted changes. Keep a separate backup for device loss.")
                .font(.caption).foregroundStyle(.secondary).padding(.bottom, 30)
        }
        .padding(.horizontal, 54)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .accessibilityIdentifier("welcome-view")
    }

    private func feature(_ title: String, symbol: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Image(systemName: symbol).font(.system(size: 18, weight: .regular)).foregroundStyle(.secondary)
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(detail).font(.caption).foregroundStyle(.secondary).lineSpacing(3)
        }
    }

    private func vaultDetail(_ vault: VaultRecord) -> some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(spacing: 10) {
                            Text(vault.name).font(.system(size: 27, weight: .semibold)).lineLimit(1)
                            Text("ON THIS MAC").font(.system(size: 9, weight: .semibold)).tracking(0.9)
                                .foregroundStyle(.secondary).padding(.horizontal, 8).padding(.vertical, 5)
                                .background(Color.primary.opacity(0.05), in: Capsule())
                        }
                        Text(vault.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    }
                    Spacer(minLength: 15)
                    Menu {
                        Button("Open in Finder", systemImage: "folder") { model.openSelectedVault() }
                        Button("Open in Obsidian", systemImage: "arrow.up.forward.app") { model.openInObsidian() }
                            .disabled(!model.canOpenObsidian)
                    } label: { Label("Open Vault", systemImage: "arrow.up.forward.square") }
                    Button("Export…", systemImage: "square.and.arrow.up") { model.exportVault() }
                        .disabled(model.checkpoints.isEmpty || model.historyReadError != nil)
                        .help(model.historyReadError != nil ? "Retry reading history before exporting." : model.checkpoints.isEmpty ? "Create a checkpoint before exporting." : "Export the latest saved checkpoint and retained history.")
                        .accessibilityIdentifier("export-vault")
                    Menu {
                        Button("Remove from App…", systemImage: "minus.circle") { confirmRemoval = true }
                    } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).frame(width: 24, height: 24)
                }
                .disabled(model.isBusy)

                Picker("Vault workspace", selection: $model.selectedSurface) {
                    ForEach(VaultSurface.allCases, id: \.self) { surface in
                        Text(surface.rawValue).tag(surface)
                    }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 300)
                .disabled(model.isBusy)
                .accessibilityIdentifier("vault-surface")

                if model.selectedSurface == .history {
                HStack(spacing: 12) {
                    Image(systemName: "bookmark").foregroundStyle(.secondary)
                    TextField("Checkpoint message (optional)", text: $model.checkpointMessage)
                        .textFieldStyle(.plain).onSubmit { model.createCheckpoint() }
                        .accessibilityLabel("Checkpoint message")
                        .accessibilityIdentifier("checkpoint-message")
                    Button("Create Checkpoint", systemImage: "plus") { model.createCheckpoint() }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        .accessibilityIdentifier("create-checkpoint")
                }
                .padding(11)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.07), lineWidth: 1))
                .disabled(model.isBusy || model.historyReadError != nil)
                Text("Checkpoints are explicit. Edits since your last checkpoint are not yet in local history.")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.top, -8)
                }
            }
            .padding(24)
            .fixedSize(horizontal: false, vertical: true)
            Divider()
            if model.selectedSurface == .graph {
                VaultGraphView(vault: vault)
                    .id(vault.id)
                    .frame(minHeight: 0, maxHeight: .infinity)
            } else if model.selectedSurface == .pruning {
                PruningView(model: model)
                    .frame(minHeight: 0, maxHeight: .infinity)
            } else if let historyError = model.historyReadError {
                unavailableHistory(historyError)
            } else if model.checkpoints.isEmpty {
                emptyHistory
            } else {
                HStack(spacing: 0) {
                    historyList.frame(width: 220)
                    Divider()
                    checkpointDetail.frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(minHeight: 0, maxHeight: .infinity)
            }
        }
    }

    private var emptyHistory: some View {
        VStack(spacing: 16) {
            Image(systemName: "clock.badge.checkmark").font(.system(size: 38, weight: .ultraLight)).foregroundStyle(.secondary)
            Text("Your history starts here").font(.title3.weight(.semibold))
            Text("Create your first checkpoint to preserve this vault as it is now.\nThen keep working in your editor and return when you want to save another moment.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(4)
            Button("Create First Checkpoint", systemImage: "plus") { model.createCheckpoint() }
                .buttonStyle(.borderedProminent).controlSize(.large).disabled(model.isBusy)
                .accessibilityIdentifier("create-first-checkpoint")
        }
        .padding(40).frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("empty-history")
    }

    private func unavailableHistory(_ error: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.arrow.circlepath")
                .font(.system(size: 36, weight: .light)).foregroundStyle(.secondary)
            Text("Local history is unavailable").font(.title3.weight(.semibold))
            Text("Planisphere could not read this vault’s saved history. This does not mean the vault has no checkpoints.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                .multilineTextAlignment(.center).frame(maxWidth: 580)
            Button("Retry History", systemImage: "arrow.clockwise") { model.retryHistory() }
                .buttonStyle(.borderedProminent).disabled(model.isBusy)
                .accessibilityIdentifier("retry-history")
        }
        .padding(40).frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("unavailable-history")
    }

    private var historyList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("HISTORY").font(.system(size: 10, weight: .semibold)).tracking(1)
                Spacer()
                Text("\(model.checkpoints.count)").font(.caption)
            }
            .foregroundStyle(.secondary).padding(18)
            .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                LazyVStack(spacing: 5) {
                    ForEach(model.checkpoints) { checkpoint in
                        Button { model.selectCheckpoint(checkpoint) } label: {
                            VStack(alignment: .leading, spacing: 7) {
                                HStack(spacing: 7) {
                                    Image(systemName: "circle.inset.filled").font(.system(size: 9)).foregroundStyle(.tint)
                                    Text(checkpoint.message.isEmpty ? "Checkpoint" : checkpoint.message)
                                        .font(.system(size: 13, weight: .medium)).lineLimit(2)
                                }
                                Text(checkpoint.createdAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption2).foregroundStyle(.secondary)
                                Text("\(model.checkpointContentSummary(checkpoint)) · \(bytes(checkpoint.totalBytes))")
                                    .font(.caption2).foregroundStyle(.secondary)
                                Text(model.checkpointModeTitle(checkpoint.captureScope?.mode ?? .wholeFolder))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12).contentShape(Rectangle())
                            .background(model.selectedCheckpointID == checkpoint.id ? Color.accentColor.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain).disabled(model.isBusy)
                        .accessibilityIdentifier("checkpoint-\(checkpoint.id.uuidString)")
                    }
                }
                .padding(.horizontal, 8).padding(.bottom, 12)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.4))
        .accessibilityIdentifier("checkpoint-history")
    }

    private var checkpointDetail: some View {
        VStack(spacing: 0) {
            if let checkpoint = model.selectedCheckpoint {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(checkpoint.parentID == nil ? "First checkpoint" : "Changes from previous checkpoint")
                            .font(.system(size: 13, weight: .semibold))
                        Text("\(model.changes.count) changed items · saved locally")
                            .font(.caption).foregroundStyle(.secondary)
                        if checkpoint.captureScope != nil {
                            Text("Excluded content is not in this checkpoint. Saving does not remove working files.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if let scope = checkpoint.captureScope {
                        Button("Saved Exclusions") { showSavedScope = true }
                            .popover(isPresented: $showSavedScope) { savedScope(scope) }
                    }
                    Button("Restore Copy…", systemImage: "arrow.uturn.backward") { model.restoreCopy() }
                        .disabled(model.isBusy)
                        .accessibilityIdentifier("restore-copy")
                }
                .padding(18)
                .fixedSize(horizontal: false, vertical: true)
                Divider()
                if model.changes.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "equal.circle").font(.system(size: 31, weight: .light)).foregroundStyle(.secondary)
                        Text("No file changes").font(.headline)
                        Text("This checkpoint matches the previous version.").font(.callout).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    HStack(spacing: 0) {
                        changesList.frame(width: 200)
                        Divider()
                        filePreview.frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .frame(minHeight: 0, maxHeight: .infinity)
                }
            } else {
                Text("Select a checkpoint").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var changesList: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(model.changes) { change in
                    Button { model.selectChange(change) } label: {
                        HStack(alignment: .top, spacing: 9) {
                            Image(systemName: changeSymbol(change.kind)).foregroundStyle(changeColor(change.kind))
                                .font(.system(size: 11, weight: .semibold)).frame(width: 13).padding(.top, 2)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(change.path).font(.system(size: 12, weight: .medium)).lineLimit(3)
                                    .truncationMode(.middle)
                                Text(change.kind.rawValue.capitalized + ((change.newEntry ?? change.oldEntry)?.kind == .symbolicLink ? " · symbolic link" : ""))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10).padding(.vertical, 10).contentShape(Rectangle())
                        .background(model.selectedChangePath == change.path ? Color.primary.opacity(0.055) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain).disabled(model.isBusy)
                    .accessibilityIdentifier("file-change-\(change.path)")
                }
            }
            .padding(8)
        }
        .accessibilityIdentifier("changed-files")
    }

    private func savedScope(_ scope: CheckpointScope) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Saved \(model.checkpointModeTitle(scope.mode)) scope").font(.headline)
            Text(scope.mode == .markdownOnly
                 ? "This checkpoint contains regular .md notes only. Attachments, settings, symbolic links, hidden folders including .obsidian, dependency folders, and the literal paths below are excluded. Excluded content is absent from recovered copies."
                 : "This checkpoint excludes hidden folders outside .obsidian settings, node_modules, __pycache__, and the literal paths below. Explicit paths can also exclude Obsidian settings. Excluded content is absent from recovered copies.")
                .font(.callout).foregroundStyle(.secondary)
            Text("\(scope.excludedPaths.count) saved path rules").font(.caption.weight(.semibold))
            ScrollView {
                Text(scope.excludedPaths.isEmpty ? "No explicit path exclusions." : scope.excludedPaths.prefix(200).joined(separator: "\n"))
                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 0, maxHeight: .infinity)
            if scope.excludedPaths.count > 200 {
                Text("Showing 200 of \(scope.excludedPaths.count) saved rules. The complete scope is retained in checkpoint metadata and exported history.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button("Done") { showSavedScope = false }.frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(22).frame(width: 520, height: 420)
    }

    private var filePreview: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let change = model.selectedChange {
                HStack {
                    Image(systemName: entrySymbol(change.newEntry ?? change.oldEntry))
                    Text(change.path).lineLimit(2).textSelection(.enabled)
                    Spacer(minLength: 0)
                }
                .font(.system(size: 12, weight: .medium)).padding(16)
                .fixedSize(horizontal: false, vertical: true)
                Divider()
                GeometryReader { bounds in
                    ScrollView([.vertical, .horizontal]) {
                        VStack(alignment: .leading, spacing: 22) {
                            textVersion(title: "BEFORE", text: model.beforeText, entry: change.oldEntry, absent: "Not present in the previous checkpoint")
                            Divider()
                            textVersion(title: "AFTER", text: model.afterText, entry: change.newEntry, absent: "Not present in this checkpoint")
                        }
                        .padding(18)
                        .frame(minWidth: bounds.size.width, minHeight: bounds.size.height, alignment: .topLeading)
                    }
                    .background(Color(nsColor: .textBackgroundColor))
                }
            } else {
                Text("Select a file to inspect its versions.").font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .accessibilityIdentifier("file-preview")
    }

    private func textVersion(title: String, text: String?, entry: FileEntry?, absent: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(.system(size: 10, weight: .semibold)).tracking(1).foregroundStyle(.secondary)
                if let entry { Text(bytes(entry.size)).font(.caption2).foregroundStyle(.tertiary) }
            }
            if entry?.kind == .symbolicLink {
                Text("Symbolic link target — referenced contents are not saved through this link.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: 340, alignment: .leading)
            }
            if let text {
                Text(text.isEmpty ? "Empty file" : text)
                    .font(.system(size: 12, design: .monospaced)).lineSpacing(4)
                    .foregroundStyle(text.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled).fixedSize(horizontal: true, vertical: true)
            } else {
                Text(entry == nil ? absent : entry?.kind == .directory ? "Folder" : entry?.kind == .symbolicLink ? "The target has no text preview. Its exact bytes are preserved in the checkpoint." : "No text preview. Binary or larger files are preserved in the checkpoint.")
                    .font(.callout).foregroundStyle(.secondary).frame(maxWidth: 310, alignment: .leading)
            }
        }
    }

    private func noticeBanner(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle").foregroundStyle(.tint)
            Text(message).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if let url = model.noticeURL {
                Button("Show in Finder") { model.reveal(url) }.buttonStyle(.link).font(.callout)
            }
            Button { model.notice = nil; model.noticeURL = nil } label: { Image(systemName: "xmark").font(.caption) }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Dismiss message")
        }
        .padding(.horizontal, 22).padding(.vertical, 13)
        .background(Color.accentColor.opacity(0.07))
    }

    private func bytes(_ count: Int64) -> String { ByteCountFormatter.string(fromByteCount: count, countStyle: .file) }
    private func entrySymbol(_ entry: FileEntry?) -> String {
        switch entry?.kind {
        case .directory: return "folder"
        case .symbolicLink: return "link"
        default: return "doc.text"
        }
    }
    private func changeSymbol(_ kind: FileChange.Kind) -> String {
        switch kind { case .added: return "plus"; case .modified: return "pencil"; case .deleted: return "minus" }
    }
    private func changeColor(_ kind: FileChange.Kind) -> Color {
        switch kind { case .added: return .green; case .modified: return .orange; case .deleted: return .red }
    }
}
