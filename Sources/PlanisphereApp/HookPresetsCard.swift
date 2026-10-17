import SwiftUI

/// The hooks Planisphere comes with: one row per preset, one install per agent app, status from recorded runs.
struct HookPresetsCard: View {
    @Bindable var model: HookPresetsModel
    var openLocal: (() -> Void)? = nil
    var presets: [HookPreset] = HookPreset.allCases
    var title: String = "Hooks that come with Planisphere"

    private func color(_ status: HookPresetStatus?) -> Color {
        switch status?.installed {
        case "installed": status?.last_error == nil && status?.last_run != nil ? Color(nsColor: .systemGreen) : Color(nsColor: .systemOrange)
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
                    Text(title).font(.callout.weight(.semibold))
                    Text("Context connects with the agent. Local support and response checks are optional. Installation, execution and delivery are separate observations.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Button("Check status", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
                    .buttonStyle(PSButtonStyle()).disabled(model.busy)
            }
            ForEach(presets) { preset in
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
                                if let origin = status?.model_review_origin {
                                    Text("Model review choice: \(origin)").font(.caption2).foregroundStyle(.secondary)
                                }
                                if let directory = status?.receipt_directory {
                                    Button("Show receipts") { NSWorkspace.shared.open(URL(fileURLWithPath: directory)) }.buttonStyle(.link)
                                }
                                if let path = status?.policy_path {
                                    Text("Policy: \(path)").font(.caption2).textSelection(.enabled)
                                }
                                if let health = status?.delivery_health {
                                    Text(health).font(.caption).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                if preset == .context && status?.installed == "installed" {
                                    HookPolicyControls(model: model, host: host)
                                }
                                DisclosureGroup("Scope, settings and data") {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(status?.ownership ?? "Optional preset · user controlled")
                                        Text(status?.scope ?? "Agent home · \(host.name)")
                                        Text(status?.triggers ?? (preset == .responseCheck ? "Trigger: reply completion" : "Trigger: prompt context preparation"))
                                        Text(status?.data_flow ?? (preset == .responseCheck ? "Reads the captured prompt and final reply locally; saves bounded review records. May ask the agent for one correction." : "Uses the local model and saves local preparation receipts. Observe mode leaves delivered evidence unchanged."))
                                        if let settings = status?.settings_summary { Text(settings) }
                                        Text("Recorded output does not prove the agent received or used it. Reporting and token collection have separate connections.")
                                    }.font(.caption).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }.font(.caption)

                            }
                            Spacer(minLength: 12)
                            VStack(alignment: .trailing, spacing: 8) {
                                action(preset, host, status: status, context: context)
                                if preset == .responseCheck && status?.installed == "installed" {
                                    Button(status?.model_review == true ? "Pause model review for this host" : "Enable model review for this host") {
                                        Task { await model.setModelReview(status?.model_review != true, for: host) }
                                    }.buttonStyle(PSButtonStyle()).disabled(model.busy)
                                }
                            }
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
        if !model.checked {
            EmptyView()
        } else if installed {
            Button("Repair installation") { Task { await model.install(preset, for: host) } }
                .buttonStyle(PSButtonStyle()).disabled(model.busy || needsModel || needsContext)
        } else if needsModel, let openLocal {
            Button("Open Local") { openLocal() }.buttonStyle(PSButtonStyle()).disabled(model.busy)
        } else {
            Button("Install for \(host.name)") { Task { await model.install(preset, for: host) } }
                .buttonStyle(PSButtonStyle(primary: preset == .context))
                .disabled(model.busy || needsModel || needsContext)
        }
    }
}


private struct HookPolicyControls: View {
    @Bindable var model: HookPresetsModel
    let host: AgentHost
    @State private var scope = "global"
    private var status: HookPresetStatus? { model.status(.context, host) }
    private var enabled: Bool { scope != "project" || model.policyProject != nil }
    private func save(_ field: String, _ value: String) { guard enabled else { return }; Task { await model.setPolicy(scope: scope, host: host, field: field, value: value) } }
    var body: some View {
        DisclosureGroup("Edit hook choices") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Apply changes to", selection: $scope) {
                    Text("All projects and hosts").tag("global")
                    Text("A project folder").tag("project")
                    Text("Only \(host.name)").tag("host")
                }
                if scope == "project" {
                    Button(model.policyProject?.lastPathComponent ?? "Choose project folder…") {
                        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
                        if panel.runModal() == .OK { model.policyProject = panel.url; Task { await model.refresh() } }
                    }
                    if let path = model.policyProject?.path { Text(path).font(.caption2) }
                }
                Text("Effective choices for \(host.name) · \(model.policyProject?.path ?? "global and host settings"). Project and host overrides can take precedence over the layer you edit.").font(.caption)
                Toggle("Offer session context", isOn: Binding(get: { status?.policy_values?.context_enabled ?? true }, set: { save("context_enabled", $0 ? "true" : "false") }))
                Picker("Context model job", selection: Binding(get: { status?.policy_values?.context_interpretation ?? "off" }, set: { save("context_interpretation", "\"" + $0 + "\"") })) {
                    Text("Off").tag("off"); Text("Observe proposals").tag("observe"); Text("Apply validated proposals").tag("assist")
                }
                Text("A model job also needs an available, permitted local runtime. Observe leaves evidence unchanged.").font(.caption)
                ForEach(["context_enabled", "context_interpretation"], id: \.self) { key in
                    HStack {
                        Text((key == "context_enabled" ? "Context" : "Model job") + " · " + (status?.policy_origins?[key] ?? "default")).font(.caption2)
                        Button("Use inherited value") { save(key, "null") }.buttonStyle(.link)
                    }
                }
            }.disabled(model.busy)
        }
    }
}
