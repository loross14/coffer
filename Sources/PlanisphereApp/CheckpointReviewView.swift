import SwiftUI
import PlanisphereCore

struct CheckpointReviewView: View {
    @Bindable var model: VaultAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Review checkpoint contents").font(.title2.weight(.semibold))
                Text(model.selectedVault?.name ?? "Selected vault").font(.callout).foregroundStyle(.secondary)
                Picker("Checkpoint contents", selection: Binding(
                    get: { model.checkpointMode }, set: { model.reviewCheckpointMode($0) }
                )) {
                    Text("Vault Content").tag(CheckpointMode.vaultContent)
                    Text("Whole Folder").tag(CheckpointMode.wholeFolder)
                }
                .pickerStyle(.segmented).disabled(model.isBusy)
                .accessibilityIdentifier("checkpoint-scope")
                Text(model.checkpointMode == .vaultContent
                     ? "Keep vault content and .obsidian settings unless explicitly excluded. Skip supported Obsidian exclusions, other hidden directories, and common dependency folders. Review the exclusions before saving."
                     : "Include the whole folder without Vault Content exclusions. Symbolic links are saved as links; their targets are not followed. Large folders may exceed the checkpoint limit.")
                    .font(.callout).foregroundStyle(.secondary).lineSpacing(3)
            }
            .padding(24)
            .fixedSize(horizontal: false, vertical: true)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if model.isBusy {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text(model.busyDescription).font(.callout)
                        }
                    }
                    if let error = model.checkpointPlanError {
                        Label("Checkpoint review needs attention", systemImage: "exclamationmark.circle")
                            .font(.headline).foregroundStyle(.orange)
                        Text(error).font(.callout).textSelection(.enabled)
                        Button("Review Again") { model.reviewCheckpointMode(model.checkpointMode) }
                            .disabled(model.isBusy)
                    }
                    if let plan = model.checkpointPlan {
                        planDetails(plan)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            }
            .frame(minHeight: 0, maxHeight: .infinity)
            Divider()
            HStack {
                Text("Files stay in place. Saving creates local history.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Button("Cancel") { model.cancelCheckpointReview() }
                    .keyboardShortcut(.cancelAction).disabled(model.isBusy)
                Button("Save Checkpoint") { model.saveReviewedCheckpoint() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isBusy || model.checkpointPlan == nil || model.checkpointPlanError != nil)
                    .accessibilityIdentifier("save-reviewed-checkpoint")
            }
            .padding(20)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 720, height: 650)
    }

    private func planDetails(_ plan: CheckpointPlan) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Expected contents").font(.headline)
            HStack(alignment: .top, spacing: 26) {
                metric("Files", "\(plan.fileCount)")
                metric("Folders", "\(plan.directoryCount)")
                metric("Symbolic links", "\(plan.symbolicLinkCount)")
                metric("Stored size", ByteCountFormatter.string(fromByteCount: plan.totalBytes, countStyle: .file))
            }
            Text("These counts are an estimate from this review. Capture checks the files and reviewed scope again before publishing a checkpoint.")
                .font(.caption).foregroundStyle(.secondary)
            if plan.symbolicLinkCount > 0 {
                Text("Symbolic link targets are preserved as references, including references outside this folder. Contents reached through a link are not included through that link.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !plan.unsupportedFilters.isEmpty {
                Label("Some Obsidian exclusions were not applied", systemImage: "exclamationmark.circle")
                    .font(.callout.weight(.semibold)).foregroundStyle(.orange)
                Text(plan.unsupportedFilters.prefix(100).joined(separator: "\n"))
                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                if plan.unsupportedFilters.count > 100 {
                    Text("Showing 100 of \(plan.unsupportedFilters.count) unsupported exclusions.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("Only supported literal exclusions are applied. Content matched only by these unsupported rules may be included.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            Text("\(plan.excludedPathCount) excluded locations").font(.headline)
            if plan.mode == .vaultContent {
                Text("Excluded content will not be in this checkpoint or its recovered copy. The scope is retained with the checkpoint. A listed folder represents its contents; the count is not a count of every omitted file.")
                    .font(.callout).foregroundStyle(.secondary).lineSpacing(3)
            }
            if plan.excludedPaths.isEmpty {
                Text("No encountered locations were excluded.").font(.caption).foregroundStyle(.secondary)
            } else {
                LazyVStack(alignment: .leading, spacing: 9) {
                    ForEach(Array(plan.excludedPaths.enumerated()), id: \.offset) { _, item in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.path).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            Text(item.reason).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                if plan.excludedPathCount > plan.excludedPaths.count {
                    Text("Showing \(plan.excludedPaths.count) of \(plan.excludedPathCount) excluded locations.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}
