import SwiftUI
import PlanisphereCore

struct CheckpointReviewView: View {
    @Bindable var model: VaultAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 14) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 22, weight: .medium)).foregroundStyle(PSStyle.accent)
                        .frame(width: 48, height: 48)
                        .background(PSStyle.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Save a checkpoint").font(.system(size: 23, weight: .semibold))
                        Text(model.selectedVault?.name ?? "Selected vault").font(.callout).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 10) {
                    Image(systemName: "text.alignleft").foregroundStyle(.secondary)
                    TextField("What changed? (optional)", text: $model.checkpointMessage)
                        .textFieldStyle(.plain).disabled(model.isBusy)
                        .accessibilityIdentifier("checkpoint-message")
                        .accessibilityLabel("Checkpoint message")
                }
                .padding(12)
                .background(PSStyle.surface, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(PSStyle.border, lineWidth: 1))
                PSSectionLabel(title: "WHAT TO SAVE")
                Picker("Checkpoint contents", selection: Binding(
                    get: { model.checkpointMode }, set: { model.reviewCheckpointMode($0) }
                )) {
                    Text("Markdown Only").tag(CheckpointMode.markdownOnly)
                    Text("Vault Content").tag(CheckpointMode.vaultContent)
                    Text("Whole Folder").tag(CheckpointMode.wholeFolder)
                }
                .pickerStyle(.segmented).disabled(model.isBusy)
                .accessibilityIdentifier("checkpoint-scope")
                Text(modeSummary)
                    .font(.callout).foregroundStyle(.secondary).lineSpacing(3)
            }
            .padding(28)
            .fixedSize(horizontal: false, vertical: true)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if model.isBusy {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text(model.busyDescription).font(.callout)
                        }
                    }
                    if let error = model.checkpointPlanError {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("Review needs attention", systemImage: "exclamationmark.circle")
                                .font(.headline).foregroundStyle(.orange)
                            Text(error).font(.callout).textSelection(.enabled)
                            Button("Review Again") { model.reviewCheckpointMode(model.checkpointMode) }
                                .buttonStyle(PSButtonStyle()).disabled(model.isBusy)
                        }
                        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
                    }
                    if let plan = model.checkpointPlan {
                        planDetails(plan)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(28)
            }
            .frame(minHeight: 0, maxHeight: .infinity)
            Divider()
            HStack {
                Label("Local history. Your files stay in place.", systemImage: "internaldrive")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Button("Cancel") { model.cancelCheckpointReview() }
                    .buttonStyle(PSButtonStyle())
                    .keyboardShortcut(.cancelAction).disabled(model.isBusy)
                Button("Save Checkpoint") { model.saveReviewedCheckpoint() }
                    .buttonStyle(PSButtonStyle(primary: true))
                    .disabled(model.isBusy || model.checkpointPlan == nil || model.checkpointPlanError != nil)
                    .accessibilityIdentifier("save-reviewed-checkpoint")
            }
            .padding(.horizontal, 24).padding(.vertical, 18)
            .fixedSize(horizontal: false, vertical: true)
            .background(PSStyle.surface)
        }
        .frame(width: 720, height: 650)
        .background(PSStyle.canvas)
    }

    private func planDetails(_ plan: CheckpointPlan) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            PSSectionLabel(title: "EXPECTED CONTENTS")
            HStack(alignment: .top, spacing: 10) {
                metric(plan.mode == .markdownOnly ? "Markdown notes" : "Files", "\(plan.fileCount)")
                metric("Folders", "\(plan.directoryCount)")
                metric("Symbolic links", "\(plan.symbolicLinkCount)")
                metric("Estimated size", ByteCountFormatter.string(fromByteCount: plan.totalBytes, countStyle: .file))
            }
            Text("Estimated from this review. Planisphere checks the files and scope again when saving.")
                .font(.caption).foregroundStyle(.secondary)
            if plan.symbolicLinkCount > 0 {
                Text("Symbolic link targets are preserved as references, including references outside this folder. Contents reached through a link are not included through that link.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !plan.unsupportedFilters.isEmpty {
                Label("Some Obsidian exclusions were not applied", systemImage: "exclamationmark.circle")
                    .font(.callout.weight(.semibold)).foregroundStyle(.orange)
                Text("Only supported literal exclusions are applied. Content matched only by these unsupported rules may be included.")
                    .font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("Review unsupported exclusions (\(plan.unsupportedFilters.count))") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(plan.unsupportedFilters.prefix(100).joined(separator: "\n"))
                            .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        if plan.unsupportedFilters.count > 100 {
                            Text("Showing 100 of \(plan.unsupportedFilters.count) unsupported exclusions.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(.top, 8)
                }.font(.callout)
            }
            Divider()
            Label("\(plan.excludedPathCount.formatted()) locations left out", systemImage: "folder.badge.minus")
                .font(.headline)
            if plan.mode != .wholeFolder {
                Text("Excluded content will not be in this checkpoint or a recovered copy. The saved checkpoint retains this scope.")
                    .font(.callout).foregroundStyle(.secondary).lineSpacing(3)
            }
            if plan.excludedPaths.isEmpty {
                Text("No encountered locations were excluded.").font(.caption).foregroundStyle(.secondary)
            } else {
                DisclosureGroup("Review excluded locations") {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        Text("Each listed folder includes its contents. This is a count of locations, not every omitted file.")
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(Array(plan.excludedPaths.enumerated()), id: \.offset) { _, item in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.path).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                Text(item.reason).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        if plan.excludedPathCount > plan.excludedPaths.count {
                            Text("Showing \(plan.excludedPaths.count) of \(plan.excludedPathCount) excluded locations.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(.top, 12)
                }.font(.callout)
            }
            DisclosureGroup("How this scope is selected") {
                Text(modeDescription).font(.caption).foregroundStyle(.secondary).lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
            }.font(.callout)
        }
    }

    private var modeSummary: String {
        switch model.checkpointMode {
        case .markdownOnly: "Save .md notes. Attachments, settings and symbolic links are left out."
        case .vaultContent: "Save vault content and settings, with supported exclusions."
        case .wholeFolder: "Save the whole folder, including attachments and settings. No content exclusions."
        }
    }

    private var modeDescription: String {
        switch model.checkpointMode {
        case .markdownOnly:
            "Save regular .md notes using supported Obsidian exclusions. Skip attachments, settings, symbolic links, hidden folders including .obsidian, and common dependency folders."
        case .vaultContent:
            "Keep vault content and .obsidian settings unless explicitly excluded. Skip supported Obsidian exclusions, other hidden directories, and common dependency folders. Review the exclusions before saving."
        case .wholeFolder:
            "Include the whole folder without content exclusions. Symbolic links are saved as links; their targets are not followed. Large folders may exceed the checkpoint limit."
        }
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(value).font(.system(size: 21, weight: .semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(14)
        .background(PSStyle.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(PSStyle.border, lineWidth: 1))
    }
}
