import SwiftUI
import PlanisphereCore

struct LocalPruningRecoveryView: View {
    @Bindable var model: VaultAppModel
    @State private var confirmAcknowledgment = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "clock.badge.exclamationmark")
                    .font(.system(size: 23, weight: .medium)).foregroundStyle(.orange)
                    .frame(width: 48, height: 48)
                    .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 7) {
                    Text("Review recovery").font(.system(size: 23, weight: .semibold))
                    Text("Pruning was interrupted. Some changes may already be in your working folder.")
                        .font(.callout).foregroundStyle(.secondary).lineSpacing(3)
                }
            }
            .padding(28).fixedSize(horizontal: false, vertical: true)
            Divider()
            ScrollView {
                if let receipt = model.unresolvedLocalMutation {
                    VStack(alignment: .leading, spacing: 18) {
                        if let error = receipt.error {
                            VStack(alignment: .leading, spacing: 7) {
                                Label("What happened", systemImage: "exclamationmark.circle").font(.callout.weight(.semibold))
                                Text(error).font(.caption).lineSpacing(3).textSelection(.enabled)
                            }
                            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.orange.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
                        }
                        VStack(alignment: .leading, spacing: 12) {
                            PSSectionLabel(title: "1 · INSPECT THE SAVED VERSION")
                            Text("Your pre-change checkpoint").font(.headline)
                            Text("Open it to inspect the notes before pruning. Restore Copy creates a separate recovered vault and leaves this working folder and its record in place.")
                                .font(.callout).foregroundStyle(.secondary).lineSpacing(3)
                            Button("Open Pre-Change Checkpoint", systemImage: "clock.arrow.circlepath") { model.openLocalRecovery(receipt) }
                                .buttonStyle(PSButtonStyle()).disabled(model.isBusy)
                        }
                        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
                        .background(PSStyle.surface, in: RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(PSStyle.border, lineWidth: 1))
                        VStack(alignment: .leading, spacing: 12) {
                            PSSectionLabel(title: "2 · INSPECT YOUR WORKING FOLDER")
                            Text("\(receipt.recoveryPaths.count.formatted()) retained recovery files").font(.headline)
                            if receipt.recoveryPaths.isEmpty {
                                Text("No retained recovery files were reported for this attempt.")
                                    .font(.caption).foregroundStyle(.secondary)
                            } else {
                                DisclosureGroup("Show recovery file locations") {
                                    VStack(alignment: .leading, spacing: 14) {
                                        ForEach(Array(receipt.recoveryPaths.prefix(100).enumerated()), id: \.offset) { _, path in
                                            HStack(alignment: .top, spacing: 12) {
                                                Text(path).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                                    .frame(maxWidth: .infinity, alignment: .leading)
                                                Button("Show") { model.reveal(URL(fileURLWithPath: path)) }
                                                    .buttonStyle(PSButtonStyle()).disabled(model.isBusy)
                                            }
                                        }
                                        if receipt.recoveryPaths.count > 100 {
                                            Text("Showing 100 of \(receipt.recoveryPaths.count) recovery files. The complete paths remain in the local receipt.")
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                    }.padding(.top, 12)
                                }.font(.callout)
                            }
                        }
                        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
                        .background(PSStyle.surface, in: RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(PSStyle.border, lineWidth: 1))
                        Text("Acknowledging this review does not restore files, repeat the operation, or mark it completed. It allows a fresh scan and explicit review.")
                            .font(.caption).foregroundStyle(.secondary).lineSpacing(3)
                        DisclosureGroup("Operation record") {
                            Text(receipt.id.uuidString)
                                .font(.system(.caption, design: .monospaced)).textSelection(.enabled).padding(.top, 8)
                        }
                                .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(28)
                }
            }
            .frame(minHeight: 0, maxHeight: .infinity)
            Divider()
            HStack {
                Button("Close") { model.localRecoveryReviewPresented = false }
                    .buttonStyle(PSButtonStyle()).disabled(model.isBusy)
                Spacer()
                Button("I’ve Inspected Recovery…") { confirmAcknowledgment = true }
                    .buttonStyle(PSButtonStyle(primary: true)).disabled(model.isBusy || model.unresolvedLocalMutation == nil)
                    .accessibilityIdentifier("acknowledge-local-recovery")
            }
            .padding(.horizontal, 24).padding(.vertical, 18).fixedSize(horizontal: false, vertical: true)
            .background(PSStyle.surface)
        }
        .frame(width: 720, height: 620)
        .background(PSStyle.canvas)
        .confirmationDialog("Allow a fresh local review?", isPresented: $confirmAcknowledgment, titleVisibility: .visible) {
            Button("Record Recovery Review") {
                if let receipt = model.unresolvedLocalMutation { model.acknowledgeLocalRecovery(receipt) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Confirm that you inspected the working folder and recovery information. The earlier operation remains interrupted and its records are kept. This allows a new scan and explicit review; it does not apply any changes.")
        }
    }
}
