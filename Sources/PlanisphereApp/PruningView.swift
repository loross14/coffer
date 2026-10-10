import SwiftUI
import PlanisphereGrapheine

struct PruningView: View {
    @Bindable var model: VaultAppModel
    @State private var confirmApply = false

    var body: some View {
        VStack(spacing: 0) {
            controls
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            GeometryReader { bounds in
                HStack(spacing: 0) {
                    resultsList
                        .frame(width: 230, height: bounds.size.height, alignment: .top)
                    Divider()
                    ScrollView {
                        detail
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(22)
                    }
                    .frame(width: max(0, bounds.size.width - 231), height: bounds.size.height)
                }
                .frame(width: bounds.size.width, height: bounds.size.height)
            }
        }
        .confirmationDialog("Apply the reviewed changes to this vault?", isPresented: $confirmApply, titleVisibility: .visible) {
            Button("Apply Reviewed Changes", role: .destructive) { model.applyPruning() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This changes the working files in the exact packet shown here. Planisphere saves a recovery checkpoint first. Grapheine then verifies the signed permission and current files before applying. A second checkpoint is attempted after success.")
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Review with Grapheine").font(.headline)
                    Text("Find related accounts. Preserve evidence. Review exact changes.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button(model.pruningScan == nil ? "Scan Vault" : "Scan Again", systemImage: "sparkle.magnifyingglass") { model.scanPruning() }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("scan-pruning")
            }
            HStack(spacing: 10) {
                Image(systemName: "signature").foregroundStyle(.secondary)
                if let policy = model.authorityPolicyURL {
                    Text(policy.lastPathComponent).font(.caption).lineLimit(1).truncationMode(.middle)
                        .help(policy.path)
                    Button("Change Policy…") { model.chooseAuthorityPolicy() }.font(.caption)
                    Button("Forget") { model.forgetAuthorityPolicy() }.font(.caption)
                        .help("Forget this location. The policy file is kept.")
                } else {
                    Text("Authority policy optional for scanning").font(.caption).foregroundStyle(.secondary)
                    Button("Choose Policy…") { model.chooseAuthorityPolicy() }.font(.caption)
                }
                Spacer(minLength: 0)
            }
            .accessibilityIdentifier("pruning-policy")
        }
        .padding(.horizontal, 24).padding(.vertical, 16)
        .disabled(model.isBusy)
    }

    private var resultsList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let scan = model.pruningScan {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("\(scan.notes) notes scanned").font(.system(size: 12, weight: .semibold))
                        Text("\(scan.groups.count) of \(scan.totalGroups) candidate groups shown")
                            .font(.caption2).foregroundStyle(.secondary)
                        Text("Scanned \(scanDate(scan.scannedAt))").font(.caption2).foregroundStyle(.secondary)
                        if model.pruningError != nil {
                            Label("Previous scan — scan again", systemImage: "exclamationmark.circle")
                                .font(.caption2).foregroundStyle(.orange)
                        }
                    }
                    sectionLabel("CANDIDATES")
                    if scan.groups.isEmpty {
                        Text("No matching-account groups nominated.").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(scan.groups) { group in
                        Button { model.selectPruningGroup(group) } label: {
                            listRow(group.candidateKey, subtitle: "\(group.members.count) notes", symbol: "doc.on.doc",
                                selected: model.selectedPruningGroupID == group.id)
                        }
                        .buttonStyle(.plain).disabled(model.isBusy)
                    }
                    Divider()
                    sectionLabel("AUTHORITY REVIEW")
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
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 0, maxHeight: .infinity)
        .background(Color.primary.opacity(0.018))
    }

    @ViewBuilder private var detail: some View {
        VStack(alignment: .leading, spacing: 22) {
            if let error = model.pruningError {
                callout("Review needs attention", text: error, symbol: "exclamationmark.circle", color: .orange)
            }
            if let historyError = model.historyReadError {
                callout("Local recovery history unavailable", text: "Applying is held until history can be read. \(historyError)", symbol: "clock.badge.exclamationmark", color: .orange)
                Button("Retry Reading History") { model.retryHistory() }.disabled(model.isBusy)
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
        VStack(alignment: .leading, spacing: 17) {
            Image(systemName: "leaf").font(.system(size: 35, weight: .light)).foregroundStyle(.tint)
            Text("Make room without losing the record.").font(.title2.weight(.semibold))
            Text("Grapheine nominates notes that may represent the same account. A matching name, few links, or an orphaned note is not permission to remove it.")
                .font(.callout).foregroundStyle(.secondary).lineSpacing(4)
            Text("Select a candidate to read its members, or an authority question to inspect its decision and holds.")
                .font(.callout).foregroundStyle(.secondary).lineSpacing(4)
            workflowRequirements
            if let scan = model.pruningScan {
                callout(authorityTitle(scan.authority.status), text: scan.authority.message ?? "Review each question and its holds before preparing changes.", symbol: "signature", color: .secondary)
            }
        }
    }

    private func groupDetail(_ group: PruningGroup) -> some View {
        VStack(alignment: .leading, spacing: 17) {
            sectionLabel("CANDIDATE GROUP")
            Text(group.candidateKey).font(.title2.weight(.semibold)).textSelection(.enabled)
            Text("These notes were nominated by matching account names or declared copies. Their contents and authority still need review. This group is not a deletion proposal.")
                .font(.callout).foregroundStyle(.secondary).lineSpacing(4)
            Text("\(group.members.count) members · \(group.declaredCopies) declared copies")
                .font(.caption).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 7) {
                ForEach(group.members, id: \.self) { path in
                    Button { model.readPruningNote(path) } label: {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "doc.text")
                            Text(path).multilineTextAlignment(.leading).textSelection(.disabled)
                            Spacer(minLength: 0)
                            if model.selectedPruningNotePath == path { Image(systemName: "eye") }
                        }
                        .padding(10)
                        .background(Color.primary.opacity(model.selectedPruningNotePath == path ? 0.08 : 0.035), in: RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain).disabled(model.isBusy)
                }
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

    private func questionDetail(_ question: PruningQuestion) -> some View {
        VStack(alignment: .leading, spacing: 17) {
            sectionLabel("AUTHORITY QUESTION")
            Text(question.scope).font(.title2.weight(.semibold)).textSelection(.enabled)
            Text(question.question).font(.headline).textSelection(.enabled)
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
                    .buttonStyle(.borderedProminent)
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
            labeledText("Packet fingerprint", packet.digest)
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
                        .padding(9)
                        .background(Color.primary.opacity(model.selectedPruningChangePath == change.path ? 0.08 : 0.025), in: RoundedRectangle(cornerRadius: 6))
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
            HStack(spacing: 10) {
                Button("Export Review Packet…", systemImage: "square.and.arrow.up") { model.exportPruningPacket() }
                    .accessibilityIdentifier("export-pruning-packet")
                Button("Load Signed Permission…", systemImage: "signature") { model.choosePruningPermission() }
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
                .buttonStyle(.borderedProminent).disabled(!model.canApplyPruning)
                .accessibilityIdentifier("apply-pruning")
            Text("A local recovery checkpoint must succeed first. Grapheine checks the signature, exact packet and current files again before writing. Keep other editors idle while applying.")
                .font(.caption).foregroundStyle(.secondary).lineSpacing(3)
        }
    }

    private var workflowRequirements: some View {
        callout("Applying has additional requirements", text: "The current Grapheine protocol requires a clean local Git repository, an existing authority policy, a signed decision, and separate signed permission for exact changes. Local Git does not require GitHub. Planisphere does not initialize Git or create trust for you. Ordinary folders can still be scanned.", symbol: "lock.shield", color: .secondary)
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
        Text(text).font(.system(size: 10, weight: .semibold)).tracking(0.8).foregroundStyle(.secondary)
    }

    private func listRow(_ title: String, subtitle: String, symbol: String, selected: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).font(.system(size: 13)).padding(.top, 2)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 12, weight: .medium)).lineLimit(3).multilineTextAlignment(.leading)
                Text(subtitle).font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.leading)
            }
            Spacer(minLength: 0)
        }
        .padding(9).frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
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
        .padding(13).frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.065), in: RoundedRectangle(cornerRadius: 9))
    }

    private func sourceText(_ text: String) -> some View {
        ScrollView([.horizontal, .vertical]) {
            Text(text).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .topLeading).padding(12)
        }
        .frame(height: 230)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.primary.opacity(0.08), lineWidth: 1))
    }
}
