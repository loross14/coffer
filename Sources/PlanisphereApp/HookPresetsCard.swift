import SwiftUI

/// The hooks Planisphere comes with: one row per preset, one install per agent app, status from recorded runs.
struct HookPresetsCard: View {
    @Bindable var model: HookPresetsModel
    var openLocal: (() -> Void)? = nil

    private func color(_ status: HookPresetStatus?) -> Color {
        switch status?.installed {
        case "installed": status?.last_error == nil ? Color(nsColor: .systemGreen) : Color(nsColor: .systemOrange)
        case "disabled": Color(nsColor: .systemOrange)
        case "unknown": Color(nsColor: .systemRed)
        default: Color.secondary.opacity(0.5)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 18) {
                Image(systemName: "shippingbox").font(.title2).foregroundStyle(PSStyle.accent)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Hooks that come with Planisphere").font(.callout.weight(.semibold))
                    Text("One click installs a hook into an agent app on this Mac. Status comes from what each hook records, not from the settings alone.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Button("Check status", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
                    .buttonStyle(PSButtonStyle()).disabled(model.busy)
            }
            ForEach(HookPreset.allCases) { preset in
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: preset.symbol).foregroundStyle(PSStyle.accent)
                        Text(preset.name).font(.callout.weight(.medium))
                    }
                    Text(preset.summary).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    ForEach(AgentHost.allCases) { host in
                        let status = model.status(preset, host)
                        let context = model.status(.context, host)
                        HStack(alignment: .center, spacing: 12) {
                            Circle().fill(color(status)).frame(width: 7, height: 7)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(host.name).font(.caption.weight(.semibold))
                                Text(HookPresetsModel.line(status, preset: preset, host: host, context: context))
                                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                    .accessibilityIdentifier("hook-preset-\(preset.rawValue)-\(host.rawValue)")
                            }
                            Spacer(minLength: 12)
                            action(preset, host, status: status, context: context)
                        }.padding(.leading, 26)
                    }
                }
            }
            if let message = model.message { Text(message).font(.caption).textSelection(.enabled) }
            Text("Installation does not prove execution: the agent may still ask you to review the hooks, and runs appear only once a hook records one.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(20).background(PSStyle.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(PSStyle.border))
        .task { await model.refresh() }
    }

    @ViewBuilder
    private func action(_ preset: HookPreset, _ host: AgentHost, status: HookPresetStatus?, context: HookPresetStatus?) -> some View {
        let installed = ["installed", "disabled"].contains(status?.installed)
        let needsModel = preset == .support && status?.model != "ready"
        let needsContext = preset != .context && context?.installed != "installed"
        if !model.checked || installed {
            EmptyView()
        } else if needsModel, let openLocal {
            Button("Open Local") { openLocal() }.buttonStyle(PSButtonStyle()).disabled(model.busy)
        } else {
            Button("Install for \(host.name)") { Task { await model.install(preset, for: host) } }
                .buttonStyle(PSButtonStyle(primary: preset == .context))
                .disabled(model.busy || needsModel || needsContext)
        }
    }
}
