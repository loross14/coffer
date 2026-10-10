import SwiftUI
import PlanisphereCore

struct LocalPruningRecoveryView: View {
    @Bindable var model: VaultAppModel
    @State private var confirmAcknowledgment = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Review interrupted pruning").font(.title2.weight(.semibold))
                Text("Inspect your working folder and the saved pre-change checkpoint. Some changes may already be present. Acknowledging this record does not restore files, replay the operation, or mark it completed.")
                    .font(.callout).foregroundStyle(.secondary).lineSpacing(3)
            }
            .padding(22).fixedSize(horizontal: false, vertical: true)
            Divider()
            ScrollView {
                if let receipt = model.unresolvedLocalMutation {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Receipt \(receipt.id.uuidString)").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        if let error = receipt.error { Text(error).font(.callout).textSelection(.enabled) }
                        Button("Open Pre-Change Checkpoint") { model.openLocalRecovery(receipt) }
                            .disabled(model.isBusy)
                        Text("Restore Copy from that checkpoint creates a separate recovered vault. It leaves the interrupted working folder and this record in place.")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("\(receipt.recoveryPaths.count) retained recovery files").font(.headline)
                        ForEach(Array(receipt.recoveryPaths.prefix(100).enumerated()), id: \.offset) { _, path in
                            HStack(alignment: .top) {
                                Text(path).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                Spacer(minLength: 8)
                                Button("Show") { model.reveal(URL(fileURLWithPath: path)) }.disabled(model.isBusy)
                            }
                        }
                        if receipt.recoveryPaths.count > 100 {
                            Text("Showing 100 of \(receipt.recoveryPaths.count) recovery files. The complete paths remain in the local receipt.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(22)
                }
            }
            .frame(minHeight: 0, maxHeight: .infinity)
            Divider()
            HStack {
                Button("Close") { model.localRecoveryReviewPresented = false }.disabled(model.isBusy)
                Spacer()
                Button("I’ve Inspected Recovery…") { confirmAcknowledgment = true }
                    .buttonStyle(.borderedProminent).disabled(model.isBusy || model.unresolvedLocalMutation == nil)
                    .accessibilityIdentifier("acknowledge-local-recovery")
            }
            .padding(20).fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 680, height: 540)
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
