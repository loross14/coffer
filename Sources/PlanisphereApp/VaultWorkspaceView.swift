import SwiftUI
import PlanisphereCore

struct VaultWorkspaceView: View {
    @Bindable var model: VaultAppModel
    @State private var confirmRemoval = false
    @State private var showSavedScope = false
    @State private var showLocalInfo = false
    @State private var previewAfter = true
    @State private var changeQuery = ""
    @FocusState private var changeSearchFocused: Bool

    var body: some View {
        GeometryReader { bounds in
            HStack(spacing: 0) {
                if model.sidebarVisible {
                    sidebar.frame(width: 216, height: bounds.size.height, alignment: .top)
                    Divider()
                }
                workspace.frame(width: max(0, bounds.size.width - (model.sidebarVisible ? 217 : 0)), height: bounds.size.height, alignment: .top)
            }
            .frame(width: bounds.size.width, height: bounds.size.height)
        }
        .tint(PSStyle.accent)
        .accentColor(PSStyle.accent)
        .disabled(model.commandPalettePresented)
        .accessibilityHidden(model.commandPalettePresented)
        .overlay {
            if model.commandPalettePresented { WorkspaceCommandsView(model: model) }
        }
        .sheet(isPresented: $model.checkpointReviewPresented) {
            CheckpointReviewView(model: model)
                .interactiveDismissDisabled(model.isBusy)
        }
        .sheet(isPresented: Binding(get: { model.console.presented }, set: { model.console.presented = $0 })) {
            ConsoleConnectionView(connection: model.console)
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
        .onChange(of: confirmRemoval) { _, value in model.workspaceConfirmationPresented = value }
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
                        .overlay(alignment: .topLeading) {
                            if !model.sidebarVisible {
                                PSIconButton(symbol: "sidebar.left", help: "Show sidebar") { model.sidebarVisible = true }
                                    .padding(12)
                            }
                        }
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
            .background(PSStyle.canvas)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Image(nsImage: NSImage(named: NSImage.applicationIconName) ?? NSImage()).resizable().frame(width: 25, height: 25)
                Text("Planisphere").font(.system(size: 14, weight: .semibold)).tracking(-0.3)
                Spacer()
                PSIconButton(symbol: "sidebar.left", help: "Hide sidebar · ⌘\\") { model.sidebarVisible = false }
            }
            .padding(.leading, 18).padding(.trailing, 10).frame(height: 56)

            Button { model.toggleCommandPalette() } label: {
                HStack(spacing: 9) {
                    Image(systemName: "magnifyingglass")
                    Text("Go anywhere").font(.system(size: 12))
                    Spacer()
                    Text("⌘K").font(.system(size: 10, weight: .medium)).foregroundStyle(.tertiary)
                }
                .foregroundStyle(.secondary).padding(.horizontal, 11).frame(height: 34)
                .background(PSStyle.surface.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(PSStyle.border))
                .contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(!model.canNavigateWorkspace)
            .padding(.horizontal, 12).padding(.bottom, 24)
            .accessibilityLabel("Go anywhere, Command K")

            VStack(spacing: 4) {
                ForEach(VaultSurface.allCases, id: \.self) { surface in
                    Button { model.selectedSurface = surface } label: {
                        HStack(spacing: 11) {
                            Image(systemName: surface.symbol).font(.system(size: 14)).frame(width: 20)
                            Text(surface.rawValue).font(.system(size: 13, weight: model.selectedSurface == surface ? .semibold : .regular))
                            Spacer()
                            if model.selectedSurface == surface {
                                Capsule().fill(PSStyle.accent).frame(width: 3, height: 16)
                            }
                        }
                        .foregroundStyle(model.selectedSurface == surface ? Color.primary : Color.secondary)
                        .padding(.horizontal, 12).frame(height: 38)
                        .background(model.selectedSurface == surface ? PSStyle.accent.opacity(0.11) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).disabled(model.isBusy || model.selectedVault == nil)
                    .accessibilityIdentifier("surface-\(surface.rawValue.lowercased())")
                    .accessibilityAddTraits(model.selectedSurface == surface ? .isSelected : [])
                }
            }.padding(.horizontal, 10)

            HStack {
                PSSectionLabel(title: "Your vaults")
                Spacer()
                Menu {
                    Button("Add Existing Vault…", systemImage: "folder.badge.plus") { model.chooseExistingVault() }
                    Button("Create New Vault…", systemImage: "plus.square") { model.chooseNewVault() }
                } label: {
                    Image(systemName: "plus").font(.system(size: 12, weight: .medium))
                        .frame(width: 28, height: 28).contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden)
                .frame(width: 28, height: 28).disabled(model.isBusy)
                .help("Add or create a local vault").accessibilityLabel("Add a vault")
                .accessibilityIdentifier("add-vault")
            }.padding(.horizontal, 20).padding(.top, 30).padding(.bottom, 12)

            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(model.vaults) { vault in
                        Button { model.selectVault(vault.id) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: model.selectedVaultID == vault.id ? "folder.fill" : "folder")
                                    .font(.system(size: 13)).foregroundStyle(model.selectedVaultID == vault.id ? PSStyle.accent : Color.secondary)
                                Text(vault.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 12).frame(height: 36)
                            .background(model.selectedVaultID == vault.id ? Color.primary.opacity(0.045) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 8))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).disabled(model.isBusy)
                        .help(vault.path)
                        .accessibilityLabel("\(vault.name), local vault")
                        .accessibilityIdentifier("vault-row-\(vault.id.uuidString)")
                    }
                }.padding(.horizontal, 10)
            }.frame(minHeight: 0, maxHeight: .infinity)

            if ConsoleConnectionModel.isAvailable {
                Button { model.console.presented = true } label: {
                    Label(model.console.title, systemImage: "network")
                        .font(.system(size: 12, weight: .medium)).lineLimit(1)
                        .padding(.horizontal, 18).padding(.top, 12)
                }.buttonStyle(.plain).disabled(!model.canNavigateWorkspace)
                .accessibilityIdentifier("console-connection")
            } else {
                Link(destination: ConsoleConnectionModel.consoleURL) {
                    Label("Open Console", systemImage: "arrow.up.right.square")
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 18).padding(.top, 12)
                }.buttonStyle(.plain).help("Open the Planisphere console in your browser")
                .accessibilityIdentifier("open-console")
            }

            Button { showLocalInfo = true } label: {
                HStack(spacing: 8) {
                    Circle().fill(Color.green.opacity(0.8)).frame(width: 5, height: 5)
                    Text("On your Mac").font(.system(size: 11, weight: .medium))
                    Spacer()
                    Image(systemName: "info.circle").font(.system(size: 11)).foregroundStyle(.tertiary)
                }.foregroundStyle(.secondary).padding(18).contentShape(Rectangle())
            }.buttonStyle(.plain)
            .popover(isPresented: $showLocalInfo) {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Your vault stays yours", systemImage: "internaldrive").font(.headline)
                    Text("Your notes and checkpoint history stay on this Mac. No account or Git repository is required.")
                    Text("Managed storage will be optional. This app does not upload your vault.").foregroundStyle(.secondary)
                    Button("Show History Location") { model.reveal(model.historyURL) }.buttonStyle(PSButtonStyle())
                    Text("Keep a separate backup for device loss.").font(.caption).foregroundStyle(.secondary)
                }.font(.callout).padding(22).frame(width: 300)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(PSStyle.sidebar)
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 35)
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 46, weight: .ultraLight)).foregroundStyle(.tint)
                .padding(.bottom, 27)
            Text("A place for your vaults.\nA way back to your work.")
                .font(.system(size: 35, weight: .semibold)).tracking(-1.1)
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
            HStack(spacing: 12) {
                if !model.sidebarVisible {
                    PSIconButton(symbol: "sidebar.left", help: "Show sidebar · ⌘\\") { model.sidebarVisible = true }
                }
                Menu {
                    ForEach(model.vaults) { item in
                        Button(item.name) { model.selectVault(item.id) }
                    }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "folder").foregroundStyle(.secondary)
                        Text(vault.name).fontWeight(.medium).lineLimit(1)
                    }
                }.menuStyle(.borderlessButton).frame(maxWidth: 240, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: false)
                    .help(vault.path).disabled(model.isBusy)
                Text("/").foregroundStyle(.tertiary)
                Menu {
                    ForEach(VaultSurface.allCases, id: \.self) { surface in
                        Button(surface.rawValue, systemImage: surface.symbol) { model.selectedSurface = surface }
                    }
                } label: { Text(model.selectedSurface.rawValue).fontWeight(.semibold) }
                    .menuStyle(.borderlessButton).fixedSize().disabled(model.isBusy)
                Spacer(minLength: 8)
                if model.selectedSurface == .history {
                    Button("Checkpoint", systemImage: "plus") { model.createCheckpoint() }
                        .buttonStyle(PSButtonStyle(primary: true))
                        .disabled(model.isBusy || model.historyReadError != nil)
                        .help("Review and create a checkpoint · ⌘S").accessibilityIdentifier("create-checkpoint")
                }
                Menu {
                    Button("Open in Finder", systemImage: "folder") { model.openSelectedVault() }
                    Divider()
                    Button("Export Vault…", systemImage: "square.and.arrow.up") { model.exportVault() }
                        .disabled(model.checkpoints.isEmpty || model.historyReadError != nil)
                    Button("Show History Location") { model.reveal(model.historyURL) }
                    Divider()
                    Button("Remove from App…", systemImage: "minus.circle") { confirmRemoval = true }
                } label: { Image(systemName: "ellipsis").frame(width: 24, height: 24) }
                    .menuStyle(.borderlessButton).frame(width: 24).disabled(model.isBusy)
                    .accessibilityLabel("Vault actions")
            }
            .font(.system(size: 12)).padding(.horizontal, 18).frame(height: 54)
            .background(PSStyle.canvas)
            Divider()
            if model.selectedSurface == .graph {
                VaultGraphView(vault: vault).id(vault.id)
                    .frame(minHeight: 0, maxHeight: .infinity)
            } else if model.selectedSurface == .pruning {
                PruningView(model: model).frame(minHeight: 0, maxHeight: .infinity)
            } else if let historyError = model.historyReadError {
                unavailableHistory(historyError)
            } else if model.checkpoints.isEmpty {
                emptyHistory
            } else {
                HStack(spacing: 0) {
                    historyList.frame(width: 208)
                    Divider()
                    checkpointDetail.frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
                }.frame(minHeight: 0, maxHeight: .infinity)
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
                PSSectionLabel(title: "Saved moments")
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
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12).contentShape(Rectangle())
                            .background(model.selectedCheckpointID == checkpoint.id ? PSStyle.accent.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain).disabled(model.isBusy)
                        .accessibilityIdentifier("checkpoint-\(checkpoint.id.uuidString)")
                    }
                }
                .padding(.horizontal, 8).padding(.bottom, 12)
            }
        }
        .background(PSStyle.surface.opacity(0.4))
        .accessibilityIdentifier("checkpoint-history")
    }

    private var checkpointDetail: some View {
        VStack(spacing: 0) {
            if let checkpoint = model.selectedCheckpoint {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(checkpoint.message.isEmpty ? "Checkpoint" : checkpoint.message)
                            .font(.system(size: 18, weight: .semibold)).tracking(-0.4).lineLimit(2)
                        Text("\(model.changes.count) changed \(model.changes.count == 1 ? "item" : "items") · \(checkpoint.createdAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        Text(checkpoint.parentID == nil ? "First saved moment" : "Compared with the previous checkpoint")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        if checkpoint.captureScope != nil {
                            Text("Saving excludes files without deleting them from your vault.")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if let scope = checkpoint.captureScope {
                        Button(model.checkpointModeTitle(scope.mode)) { showSavedScope = true }
                            .font(.system(size: 10, weight: .medium)).buttonStyle(.plain)
                            .padding(.horizontal, 8).padding(.vertical, 6)
                            .background(PSStyle.accent.opacity(0.08), in: Capsule())
                            .help("Saved capture scope and exclusions")
                            .accessibilityLabel("\(model.checkpointModeTitle(scope.mode)), saved scope and exclusions")
                            .popover(isPresented: $showSavedScope) { savedScope(scope) }
                    } else {
                        Text("Whole Folder").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Button("Restore Copy…", systemImage: "arrow.uturn.backward") { model.restoreCopy() }
                        .buttonStyle(PSButtonStyle()).fixedSize()
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
                        changesList.frame(width: 192)
                        Divider()
                        filePreview.frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .frame(minHeight: 0, maxHeight: .infinity)
                }
            } else {
                Text("Select a checkpoint").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var changesList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Find a changed file", text: $changeQuery)
                    .textFieldStyle(.plain).focused($changeSearchFocused)
                    .accessibilityIdentifier("changed-files-search")
                if !changeQuery.isEmpty {
                    Button { changeQuery = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Clear changed-file search")
                }
            }.font(.system(size: 11)).padding(12)
            Divider()
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(model.changes.filter { changeQuery.isEmpty || $0.path.localizedCaseInsensitiveContains(changeQuery) }) { change in
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
        .background {
            Button("Find a changed file") { changeSearchFocused = true }
                .keyboardShortcut("f", modifiers: .command).hidden().accessibilityHidden(true)
        }
        .onChange(of: model.selectedCheckpointID) { _, _ in changeQuery = "" }
    }

    private func savedScope(_ scope: CheckpointScope) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Saved \(model.checkpointModeTitle(scope.mode)) scope").font(.headline)
            Text(scope.mode == .markdownOnly
                 ? "This checkpoint contains regular .md notes only. Attachments, settings, symbolic links, hidden folders including .planisphere, dependency folders, and the literal paths below are excluded. Excluded content is absent from recovered copies."
                 : "This checkpoint excludes hidden folders outside .planisphere settings, node_modules, __pycache__, and the literal paths below. Explicit paths can also exclude Planisphere settings. Excluded content is absent from recovered copies.")
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
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: entrySymbol(change.newEntry ?? change.oldEntry)).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text((change.path as NSString).lastPathComponent).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                            Text(change.path).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer(minLength: 0)
                    }.textSelection(.enabled)
                    HStack {
                        Picker("File version", selection: $previewAfter) {
                            Text("Before").tag(false)
                            Text("After").tag(true)
                        }.pickerStyle(.segmented).labelsHidden().frame(width: 152)
                        Spacer()
                        Text(change.kind.rawValue.capitalized).font(.system(size: 10, weight: .medium))
                            .foregroundStyle(changeColor(change.kind)).padding(.horizontal, 7).padding(.vertical, 4)
                            .background(changeColor(change.kind).opacity(0.08), in: Capsule())
                    }
                }
                .padding(16).fixedSize(horizontal: false, vertical: true)
                Divider()
                GeometryReader { bounds in
                    ScrollView(.vertical) {
                        Group {
                            if previewAfter {
                                textVersion(title: "THIS CHECKPOINT", text: model.afterText, entry: change.newEntry, absent: "Not present in this checkpoint")
                            } else {
                                textVersion(title: "PREVIOUS CHECKPOINT", text: model.beforeText, entry: change.oldEntry, absent: "Not present in the previous checkpoint")
                            }
                        }
                        .padding(22)
                        .frame(width: bounds.size.width, alignment: .topLeading)
                    }.background(PSStyle.surface)
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "doc.text.magnifyingglass").font(.system(size: 30, weight: .ultraLight))
                    Text("Choose a file to read its versions.").font(.callout)
                }.foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onChange(of: "\(model.selectedCheckpointID?.uuidString ?? "")/\(model.selectedChangePath ?? "")", initial: true) { _, _ in
            previewAfter = model.selectedChange?.kind != .deleted
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
                    .font(.system(size: 12, design: .monospaced)).lineSpacing(5)
                    .foregroundStyle(text.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
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
