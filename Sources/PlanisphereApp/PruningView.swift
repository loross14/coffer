import SwiftUI
import PlanisphereGrapheine

struct PruningView: View {
    @Bindable var model: VaultAppModel
    @State private var confirmApply = false
    @State private var confirmDisconnectPolicy = false

    var body: some View {
        VStack(spacing: 0) {
            controls
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            GeometryReader { bounds in
                let listWidth: CGFloat = model.pruningScan == nil ? 0 : 224
                HStack(spacing: 0) {
                    if listWidth > 0 {
                        resultsList.frame(width: listWidth, height: bounds.size.height, alignment: .top)
                        Divider()
                    }
                    ScrollView {
                        detail
                            .frame(maxWidth: 720, alignment: .leading)
                            .padding(24)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                    .frame(width: max(0, bounds.size.width - listWidth - (listWidth > 0 ? 1 : 0)), height: bounds.size.height)
                }
                .frame(width: bounds.size.width, height: bounds.size.height)
            }
        }
        .background(PSStyle.canvas)
        .onChange(of: confirmApply) { _, _ in
            model.workspaceConfirmationPresented = confirmApply || confirmDisconnectPolicy
        }
        .onChange(of: confirmDisconnectPolicy) { _, _ in
            model.workspaceConfirmationPresented = confirmApply || confirmDisconnectPolicy
        }
        .confirmationDialog("Apply the reviewed changes to this vault?", isPresented: $confirmApply, titleVisibility: .visible) {
            Button("Apply Reviewed Changes", role: .destructive) {
                if model.authorityPolicyURL == nil { model.applyLocalPruning() }
                else { model.applyPruning() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(model.authorityPolicyURL == nil
                 ? "Apply only the Markdown changes shown here, keeping your chosen note and retiring the other reviewed members. Planisphere rechecks the proposal, saves a pre-change checkpoint, records the operation locally, and saves the result. Keep other editors idle. This is your local approval, not a signed authority decision."
                 : "This changes the working files in the exact signed-policy packet shown here. Planisphere saves a recovery checkpoint first. Grapheine verifies signed permission and current files before applying. A second checkpoint is attempted after success.")
        }
        .confirmationDialog("Disconnect signed-policy review?", isPresented: $confirmDisconnectPolicy, titleVisibility: .visible) {
            Button("Disconnect Policy") { model.forgetAuthorityPolicy() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This vault will use local review, where you choose a note to keep and explicitly approve changes in Planisphere. Existing policy files and signed records are retained. Local approvals do not satisfy the disconnected signed policy.")
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Review your notes").font(.system(size: 18, weight: .semibold))
                    Text("Choose what stays. Inspect every change.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button(model.pruningScan == nil ? "Scan Vault" : "Scan Again", systemImage: "sparkle.magnifyingglass") { model.scanPruning() }
                    .buttonStyle(PSButtonStyle(primary: true))
                    .accessibilityIdentifier("scan-pruning")
            }
            HStack(spacing: 10) {
                if let policy = model.authorityPolicyURL {
                    Image(systemName: "signature").foregroundStyle(.secondary)
                    Text("Signed policy: \(policy.lastPathComponent)").font(.caption).lineLimit(1).truncationMode(.middle)
                        .help(policy.path)
                    Menu("Policy") {
                        Button("Change Policy…") { model.chooseAuthorityPolicy() }
                        Button("Disconnect…") { confirmDisconnectPolicy = true }
                    }.font(.caption).fixedSize(horizontal: true, vertical: false)
                } else {
                    Label("Local review", systemImage: "person.crop.circle.badge.checkmark")
                        .font(.caption).foregroundStyle(.secondary)
                    Menu("Advanced") {
                        Button("Connect Signed Policy…") { model.chooseAuthorityPolicy() }
                    }.font(.caption).fixedSize(horizontal: true, vertical: false)
                }
                Spacer(minLength: 0)
            }
            .accessibilityIdentifier("pruning-policy")
        }
        .padding(.horizontal, 24).padding(.vertical, 18)
        .background(PSStyle.surface)
        .disabled(model.isBusy)
    }

    private var resultsList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let scan = model.pruningScan {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("\(scan.groups.count.formatted()) candidate groups").font(.system(size: 13, weight: .semibold))
                        Text("From \(scan.notes.formatted()) Markdown notes")
                            .font(.caption).foregroundStyle(.secondary)
                        if scan.groups.count < scan.totalGroups {
                            Text("Showing \(scan.groups.count) of \(scan.totalGroups) groups")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Text("Scanned \(scanDate(scan.scannedAt))").font(.caption2).foregroundStyle(.secondary)
                        if model.pruningError != nil {
                            Label("Previous scan — scan again", systemImage: "exclamationmark.circle")
                                .font(.caption2).foregroundStyle(.orange)
                        }
                    }
                    sectionLabel("CANDIDATES")
                    if scan.groups.isEmpty {
                        Text("No matching groups found in this scan.").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(scan.groups) { group in
                        Button { model.selectPruningGroup(group) } label: {
                            listRow(group.candidateKey, subtitle: "\(group.members.count) notes", symbol: "doc.on.doc",
                                selected: model.selectedPruningGroupID == group.id)
                        }
                        .buttonStyle(.plain).disabled(model.isBusy)
                    }
                    if model.authorityPolicyURL != nil {
                    Divider()
                    sectionLabel("SIGNED POLICY")
                    ForEach(scan.authority.questions) { question in
                        Button { model.selectPruningQuestion(question) } label: {
                            listRow(question.question, subtitle: "\(question.scope) · \(questionState(question))", symbol: question.hold == nil ? "signature" : "pause.circle",
                                selected: model.selectedPruningQuestionID == question.id)
                        }
                        .buttonStyle(.plain).disabled(model.isBusy)
                    }
                    if scan.authority.questions.isEmpty {
                        Text(scan.authority.message ?? "No authority questions were reported.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    }
                    Divider()
                    Text("Grapheine \(scan.engineVersion)").font(.caption2).foregroundStyle(.tertiary)
                } else {
                    sectionLabel("READ-ONLY DISCOVERY")
                    Text("Scan the selected vault to find candidate groups and any available authority decisions.")
                        .font(.callout).foregroundStyle(.secondary).lineSpacing(3)
                    Text("A scan does not edit your notes.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 0, maxHeight: .infinity)
        .background(PSStyle.surface.opacity(0.65))
    }

    @ViewBuilder private var detail: some View {
        VStack(alignment: .leading, spacing: 22) {
            if let error = model.pruningError {
                callout("Review needs attention", text: error, symbol: "exclamationmark.circle", color: .orange)
            }
            if let historyError = model.historyReadError {
                callout("Local recovery history unavailable", text: "Applying is held until history can be read. \(historyError)", symbol: "clock.badge.exclamationmark", color: .orange)
                Button("Retry Reading History") { model.retryHistory() }
                    .buttonStyle(PSButtonStyle()).disabled(model.isBusy)
            }
            if let scan = model.pruningScan {
                scanCoverage(scan)
                if model.authorityPolicyURL != nil {
                callout(authorityTitle(scan.authority.status),
                    text: scan.authority.message ?? "Review each question and its holds before preparing changes.",
                    symbol: "signature", color: scan.authority.status == "unavailable" ? .orange : .secondary)
                }
            }
            if let group = model.selectedPruningGroup {
                groupDetail(group)
            } else if let question = model.selectedPruningQuestion {
                questionDetail(question)
            } else {
                introduction
            }
            if let scan = model.pruningScan, !scan.diagnostics.isEmpty {
                DisclosureGroup("Scan details") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(scan.diagnostics.enumerated()), id: \.offset) { _, diagnostic in
                            Text(diagnostic).font(.caption).textSelection(.enabled)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 22) {
            Image(systemName: "leaf")
                .font(.system(size: 28, weight: .light)).foregroundStyle(PSStyle.accent)
                .frame(width: 58, height: 58)
                .background(PSStyle.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))
            VStack(alignment: .leading, spacing: 10) {
                Text("Make room for clarity.").font(.system(size: 25, weight: .semibold))
                Text("Grapheine finds notes that may cover the same account. You decide what stays. A scan never changes your notes.")
                    .font(.callout).foregroundStyle(.secondary).lineSpacing(4)
            }
            VStack(alignment: .leading, spacing: 18) {
                reviewStep("1", title: "Find candidates", detail: "Scan this vault, then read the notes in a group.")
                reviewStep("2", title: model.authorityPolicyURL == nil ? "Choose what to keep" : "Inspect the signed decision",
                           detail: model.authorityPolicyURL == nil ? "Make an explicit choice. Similar names or few links alone do not justify removal." : "Review the policy’s question, evidence and any holds.")
                reviewStep("3", title: "Review the exact changes", detail: "Inspect retirements and link updates before you approve. Preservation holds remain in force.")
            }
            if model.authorityPolicyURL != nil { workflowRequirements }
            else {
                Label("Local approval · recovery checkpoints · no Git required", systemImage: "clock.arrow.circlepath")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(26).frame(maxWidth: .infinity, alignment: .leading)
        .background(PSStyle.surface, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(PSStyle.border, lineWidth: 1))
    }

    private func reviewStep(_ number: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 13) {
            Text(number).font(.system(size: 11, weight: .semibold)).foregroundStyle(PSStyle.accent)
                .frame(width: 24, height: 24).background(PSStyle.accent.opacity(0.08), in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary).lineSpacing(3)
            }
        }
    }

    private func scanCoverage(_ scan: PruningScan) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("\(scan.notes.formatted()) notes inspected · \(scan.scope.excludedCount.formatted()) locations excluded", systemImage: "folder.badge.magnifyingglass")
                .font(.system(size: 12, weight: .medium))
            Text("Discovery only. This scan does not verify the whole vault or approve changes.")
                .font(.caption).foregroundStyle(.secondary).lineSpacing(3)
            if !scan.scope.unsupportedFilters.isEmpty {
                Label("Some Obsidian exclusions could not be applied. Review the scope details.", systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.orange)
            }
            DisclosureGroup("Scope & exclusions") {
                VStack(alignment: .leading, spacing: 13) {
                    Text("A listed folder includes its contents. Counts describe skipped locations, not the number of files inside those folders.")
                        .font(.caption).foregroundStyle(.secondary)
                    if scan.scope.excludedPaths.isEmpty {
                        Text("No encountered locations were excluded.").font(.caption).foregroundStyle(.secondary)
                    } else {
                        scopeLines("Excluded paths", scan.scope.excludedPaths)
                        if scan.scope.truncated {
                            Text("Showing \(scan.scope.excludedPaths.count) of \(scan.scope.excludedCount) excluded locations.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if !scan.scope.appliedFilters.isEmpty {
                        scopeLines("Applied Obsidian exclusions", scan.scope.appliedFilters)
                    }
                    if !scan.scope.unsupportedFilters.isEmpty {
                        scopeLines("Obsidian exclusions not applied", scan.scope.unsupportedFilters)
                    }
                    if !scan.scope.limitations.isEmpty {
                        scopeLines("Coverage limits", scan.scope.limitations)
                    }
                    Text("Local preparation checks the reviewed Markdown scope and preservation requirements again. Connected signed policies keep their own write requirements. A discovery result alone does not approve changes.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.top, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.caption)
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(PSStyle.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(PSStyle.border, lineWidth: 1))
    }

    private func scopeLines(_ title: String, _ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold))
            ScrollView {
                Text(lines.joined(separator: "\n")).font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: min(180, CGFloat(max(1, lines.count)) * 19 + 8))
        }
    }

    private func groupDetail(_ group: PruningGroup) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            sectionLabel("CANDIDATE GROUP")
            Text(group.candidateKey).font(.title2.weight(.semibold)).textSelection(.enabled)
            Text("These notes share an account name or declare a copy. Read them before choosing what to keep; a matching name alone does not justify retirement.")
                .font(.callout).foregroundStyle(.secondary).lineSpacing(4)
            Text("\(group.members.count) members · \(group.declaredCopies) declared copies")
                .font(.caption).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 7) {
                ForEach(group.members, id: \.self) { path in
                    HStack(alignment: .center, spacing: 8) {
                    Button { model.readPruningNote(path) } label: {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "doc.text")
                            Text(path).multilineTextAlignment(.leading).textSelection(.disabled)
                            Spacer(minLength: 0)
                            if model.selectedPruningNotePath == path { Image(systemName: "eye") }
                        }
                        .font(.system(size: 12, weight: .medium)).padding(12)
                        .background(model.selectedPruningNotePath == path ? PSStyle.accent.opacity(0.07) : PSStyle.surface, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(model.selectedPruningNotePath == path ? PSStyle.accent.opacity(0.25) : PSStyle.border, lineWidth: 1))
                    }
                    .buttonStyle(.plain).disabled(model.isBusy)
                    if model.authorityPolicyURL == nil {
                        Button { model.chooseKeeper(path) } label: {
                            HStack(spacing: 5) {
                                if model.selectedKeeperPath == path { Image(systemName: "checkmark") }
                                Text(model.selectedKeeperPath == path ? "Keeping" : "Keep")
                            }
                        }
                            .buttonStyle(PSButtonStyle(primary: model.selectedKeeperPath == path))
                            .disabled(model.isBusy)
                            .accessibilityLabel("Keep \(path)")
                            .accessibilityIdentifier("keep-note-\(path)")
                    }
                    }
                }
            }
            if model.authorityPolicyURL == nil {
                if let hold = model.localReviewHold {
                    callout("No changes prepared", text: hold, symbol: "pause.circle", color: .orange)
                }
                if let keeper = model.selectedKeeperPath {
                    labeledText("Your note to keep", keeper)
                } else {
                    Text("Choose the note to keep. Reading a preview does not make this choice.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let packet = model.localPruningPacket {
                    localPacketDetail(packet)
                } else {
                    Button("Review Changes", systemImage: "doc.text.magnifyingglass") { model.prepareLocalPruning() }
                        .buttonStyle(PSButtonStyle(primary: true)).disabled(!model.canPrepareLocalPruning)
                        .accessibilityIdentifier("prepare-local-pruning")
                    Text("No files change during review. The proposal must preserve evidence and resolve affected links safely before it can be applied.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("This vault has a connected signed policy. Select its authority question to prepare an eligible signed-policy proposal; local review will not bypass its holds.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let path = model.selectedPruningNotePath {
                Divider()
                sectionLabel("CURRENT WORKING FILE")
                Text(path).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                if let error = model.pruningNoteError {
                    Text("Could not read this note. \(error)").font(.callout).foregroundStyle(.orange)
                } else if let text = model.pruningNoteText {
                    sourceText(text.isEmpty ? "(Empty file)" : text)
                } else {
                    Text("Text preview is unavailable for this file. It may be binary or too large to preview.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func localPacketDetail(_ packet: LocalPruningPacket) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Divider()
            sectionLabel("LOCAL CHANGE REVIEW")
            Text("\(packet.changes.filter(\.isRetired).count) notes to retire · \(packet.changes.filter { !$0.isRetired }.count) files to update")
                .font(.headline)
            labeledText("Keep", packet.keepPath)
            Text("This proposal affects the reviewed Markdown scope. Attachments, settings and excluded folders are outside its recovery checkpoint. Retirements remove files from the working folder after their pre-change versions are saved locally.")
                .font(.caption).foregroundStyle(.secondary).lineSpacing(3)
            if !packet.limitations.isEmpty {
                DisclosureGroup("Review scope & limits") {
                    scopeLines("Review limits", packet.limitations).padding(.top, 8)
                }.font(.caption)
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(packet.changes) { change in
                    Button { model.selectedLocalChangePath = change.path } label: {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: change.isRetired ? "minus.circle" : "pencil.circle")
                                .foregroundStyle(change.isRetired ? Color.orange : Color.accentColor)
                            Text(change.path).multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                            Text(change.isRetired ? "Retire" : "Update links").font(.caption).foregroundStyle(.secondary)
                        }
                        .font(.system(size: 12, weight: .medium)).padding(12)
                        .background(model.selectedLocalChangePath == change.path ? PSStyle.accent.opacity(0.07) : PSStyle.surface, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(model.selectedLocalChangePath == change.path ? PSStyle.accent.opacity(0.25) : PSStyle.border, lineWidth: 1))
                    }.buttonStyle(.plain).disabled(model.isBusy)
                }
            }
            if let change = model.selectedLocalChange {
                Text(change.path).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                sectionLabel("BEFORE")
                sourceText(change.before ?? "No readable original.")
                sectionLabel("AFTER")
                sourceText(change.isRetired ? "This note will be retired from the working folder." : change.after ?? "No readable result.")
            }
            DisclosureGroup("Review fingerprint") {
                labeledText("Exact local proposal", packet.digest).padding(.top, 8)
            }.font(.caption).foregroundStyle(.secondary)
            Button("Apply Reviewed Changes", systemImage: "checkmark.shield") { confirmApply = true }
                .buttonStyle(PSButtonStyle(primary: true)).disabled(!model.canApplyLocalPruning)
                .accessibilityIdentifier("apply-local-pruning")
            Text("Your next confirmation approves these exact local changes. Freshness and preservation are checked again; checkpoints and a local operation record support recovery. Keep other editors idle while applying.")
                .font(.caption).foregroundStyle(.secondary).lineSpacing(3)
        }
    }

    private func questionDetail(_ question: PruningQuestion) -> some View {
        VStack(alignment: .leading, spacing: 17) {
            sectionLabel("AUTHORITY QUESTION")
            Text(question.question).font(.title2.weight(.semibold)).textSelection(.enabled)
            Text(question.scope).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            Label(questionState(question), systemImage: question.hold == nil ? "signature" : "pause.circle")
                .font(.callout.weight(.medium))
            if let value = question.value {
                labeledText("Signed decision", value)
            }
            if !question.values.isEmpty {
                labeledText("Accounts under review", question.values.joined(separator: "\n"))
            }
            if !question.proofs.isEmpty {
                DisclosureGroup("Decision evidence (\(question.proofs.count))") {
                    Text(question.proofs.joined(separator: "\n"))
                        .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                }.font(.caption)
            }
            if let hold = question.hold {
                callout("Held", text: hold, symbol: "pause.circle", color: .orange)
            }
            if let packet = model.pruningPacket {
                Divider()
                packetDetail(packet)
            } else {
                workflowRequirements
                Button("Prepare Exact Changes", systemImage: "doc.text.magnifyingglass") { model.preparePruning() }
                    .buttonStyle(PSButtonStyle(primary: true))
                    .disabled(model.isBusy || model.pruningError != nil || model.authorityPolicyURL == nil || question.state != "resolved" || question.writeState != "needs_exact_write_permission")
                    .accessibilityIdentifier("prepare-pruning")
                Text("Preparation reads the current files and checks prerequisites. It does not apply the changes or grant write permission.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func packetDetail(_ packet: PruningPacket) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionLabel("EXACT CHANGE PREVIEW")
            Text("\(packet.changes.count) files in this packet").font(.headline)
            labeledText("Retained account", packet.value)
            labeledText("Valid until", packet.validUntil)
            DisclosureGroup("Packet fingerprint") {
                labeledText("Exact signed-policy proposal", packet.digest).padding(.top, 8)
            }.font(.caption).foregroundStyle(.secondary)
            Text("Review every change below. Retired files are removed from the working folder; the pre-change files remain in the recovery checkpoint.")
                .font(.caption).foregroundStyle(.secondary).lineSpacing(3)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(packet.changes) { change in
                    Button { model.selectedPruningChangePath = change.path } label: {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: change.isRetired ? "minus.circle" : "pencil.circle")
                                .foregroundStyle(change.isRetired ? Color.orange : Color.accentColor)
                            Text(change.path).multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                            Text(change.isRetired ? "Retire" : "Rewrite").font(.caption).foregroundStyle(.secondary)
                        }
                        .font(.system(size: 12, weight: .medium)).padding(12)
                        .background(model.selectedPruningChangePath == change.path ? PSStyle.accent.opacity(0.07) : PSStyle.surface, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(model.selectedPruningChangePath == change.path ? PSStyle.accent.opacity(0.25) : PSStyle.border, lineWidth: 1))
                    }
                    .buttonStyle(.plain).disabled(model.isBusy)
                }
            }
            if let change = model.selectedPruningChange {
                Text(change.path).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                sectionLabel("BEFORE")
                sourceText(change.before ?? "No readable text preview in this packet.")
                sectionLabel("AFTER")
                sourceText(change.isRetired ? "This file will be retired from the working folder." : change.after ?? "No readable text preview in this packet.")
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Button("Export Review Packet…", systemImage: "square.and.arrow.up") { model.exportPruningPacket() }
                    .buttonStyle(PSButtonStyle())
                    .accessibilityIdentifier("export-pruning-packet")
                Button("Load Signed Permission…", systemImage: "signature") { model.choosePruningPermission() }
                    .buttonStyle(PSButtonStyle())
                    .accessibilityIdentifier("choose-pruning-permission")
            }
            .disabled(model.isBusy)
            if let receipt = model.permissionReceiptURL {
                Text("Selected: \(receipt.lastPathComponent). Signature and exact permission are checked when applying.")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            } else {
                Text("An independently signed permission for this exact packet is required. Planisphere does not create signing keys or sign on your behalf.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button("Apply Reviewed Changes", systemImage: "checkmark.shield") { confirmApply = true }
                .buttonStyle(PSButtonStyle(primary: true)).disabled(!model.canApplyPruning)
                .accessibilityIdentifier("apply-pruning")
            Text("A local recovery checkpoint must succeed first. Grapheine checks the signature, exact packet and current files again before writing. Keep other editors idle while applying.")
                .font(.caption).foregroundStyle(.secondary).lineSpacing(3)
        }
    }

    private var workflowRequirements: some View {
        callout("Connected signed-policy workflow", text: "This optional workflow keeps its existing requirements: a clean local Git repository, a signed decision, and separate signed permission for exact changes. Planisphere does not create trust or switch to local approval when a signed-policy proposal is held.", symbol: "lock.shield", color: .secondary)
    }

    private func questionState(_ question: PruningQuestion) -> String {
        if question.hold != nil || question.writeState == "held" { return "Held for review" }
        switch question.state {
        case "resolved": return "Decision recorded · write permission required"
        case "conflicting_authority": return "Conflicting authority"
        case "needs_decision": return "Decision needed"
        default: return question.state.replacingOccurrences(of: "_", with: " ")
        }
    }

    private func authorityTitle(_ status: String) -> String {
        switch status {
        case "available": return "Authority policy connected"
        case "notConfigured": return "No authority policy connected"
        default: return "Authority policy unavailable"
        }
    }

    private func scanDate(_ raw: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: raw) else { return raw }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private func sectionLabel(_ text: String) -> some View {
        PSSectionLabel(title: text)
    }

    private func listRow(_ title: String, subtitle: String, symbol: String, selected: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(selected ? PSStyle.accent : .secondary).padding(.top, 2)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 12, weight: .medium)).lineLimit(3).multilineTextAlignment(.leading)
                Text(subtitle).font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.leading)
            }
            Spacer(minLength: 0)
        }
        .padding(11).frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? PSStyle.accent.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? PSStyle.accent.opacity(0.18) : .clear, lineWidth: 1))
        .contentShape(Rectangle())
    }

    private func labeledText(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(value).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func callout(_ title: String, text: String, symbol: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(color).padding(.top, 1)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(text).font(.caption).foregroundStyle(.secondary).lineSpacing(3).textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(color.opacity(0.1), lineWidth: 1))
    }

    private func sourceText(_ text: String) -> some View {
        ScrollView([.horizontal, .vertical]) {
            Text(text).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .topLeading).padding(16)
        }
        .frame(height: 230)
        .background(PSStyle.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(PSStyle.border, lineWidth: 1))
    }
}
