import SwiftUI

/// Install and run Planisphere's own model. Nothing else needs to be installed.
struct ModelRuntimeSection: View {
    @Bindable var runtime: ModelRuntimeModel
    var changed: () async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: symbol).foregroundStyle(PSStyle.accent)
                Text(title).font(.callout.weight(.medium))
            }
            Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if case .installing(_, let fraction) = runtime.phase {
                if let fraction { ProgressView(value: fraction) } else { ProgressView().controlSize(.small) }
            }
            if runtime.needsApproval {
                HStack {
                    Text("Allow Planisphere in Login Items so the model can run in the background.")
                        .font(.caption).fixedSize(horizontal: false, vertical: true)
                    Button("Open Login Items") { runtime.openLoginItems() }
                }
            }
            HStack {
                switch runtime.phase {
                case .notInstalled, .failed:
                    if runtime.existingCopy != nil {
                        Button("Use the Copy on This Mac") { runtime.useExistingCopy() }.buttonStyle(PSButtonStyle(primary: true))
                    }
                    Button("Download (\(ModelRuntimeModel.size(runtime.spec.sizeBytes)))") { runtime.download() }
                        .buttonStyle(PSButtonStyle(primary: runtime.existingCopy == nil))
                case .installing:
                    Button("Cancel") { runtime.cancel() }
                case .installed:
                    Button("Start Model") { Task { await runtime.start(); await changed() } }.buttonStyle(PSButtonStyle(primary: true))
                    Button("Remove") { Task { await runtime.remove(); await changed() } }
                case .running:
                    Button("Stop Model") { Task { await runtime.stop(); await changed() } }
                case .checking, .starting:
                    ProgressView().controlSize(.small)
                }
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(PSStyle.surface, in: RoundedRectangle(cornerRadius: 10))
        .task { await runtime.refresh() }
        .onChange(of: runtime.phase) { _, phase in if phase == .running { Task { await changed() } } }
    }

    private var symbol: String {
        switch runtime.phase {
        case .running: "checkmark.circle"
        case .failed: "exclamationmark.triangle"
        case .installing, .starting, .checking: "arrow.down.circle"
        default: "cpu"
        }
    }

    private var title: String {
        switch runtime.phase {
        case .checking: "Checking the Planisphere model…"
        case .notInstalled: "Planisphere model not installed"
        case .installing(let text, _): text
        case .installed: "Model installed, not running"
        case .starting: "Starting the model…"
        case .running: "\(runtime.spec.name) is running on this Mac"
        case .failed: "The model needs attention"
        }
    }

    private var detail: String {
        switch runtime.phase {
        case .failed(let message): message
        case .notInstalled:
            runtime.existingCopy != nil
                ? "A copy of \(runtime.spec.name) is already on this Mac. Planisphere checks it against a pinned fingerprint and keeps its own copy."
                : "Planisphere downloads \(runtime.spec.name) once from Hugging Face and checks it against a pinned fingerprint before use."
        case .running:
            "Runs in the background, also while Planisphere is closed. It only answers this Mac, on a private local port."
        default:
            "The model runs in the background on this Mac and only answers this Mac. Your agent still evaluates the evidence."
        }
    }
}
