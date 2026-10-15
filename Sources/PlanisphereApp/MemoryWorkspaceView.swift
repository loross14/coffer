import SwiftUI

struct MemoryWorkspaceView: View {
    @Bindable var model: MemoryModel
    var reporting: ReportingModel? = nil
    var openLocal: (() -> Void)? = nil
    @State private var editing: MemoryFact?
    @State private var editorPresented = false
    @State private var draft = ""
    @State private var forgetting: MemoryFact?
    @State private var query = ""

    private var filtered: [MemoryFact] {
        model.facts.filter { query.isEmpty || $0.body.localizedCaseInsensitiveContains(query) || $0.scope.localizedCaseInsensitiveContains(query) }
    }
    static func agentLine(_ host: AgentHost, status: String?) -> String {
        switch status {
        case "installed": host == .codex ? "Connected. Review the hooks in Codex, then start a new chat."
                                         : "Connected. Start a new session; if asked, review the hooks in /hooks."
        case "disabled": "Connected, but its Planisphere hooks are turned off in \(host.name)."
        case "not_installed": "Not connected"
        default: "Status not checked yet"
        }
    }
    private func agentColor(_ status: String?) -> Color {
        switch status {
        case "installed": Color(nsColor: .systemGreen)
        case "disabled": Color(nsColor: .systemOrange)
        default: Color.secondary.opacity(0.5)
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    PSSectionLabel(title: "On this Mac")
                    Text("Memory").font(.system(size: 30, weight: .semibold)).tracking(-0.8)
                    Text("Keep what matters. Pick up where you left off.").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Add a memory", systemImage: "plus") { editing = nil; draft = ""; editorPresented = true }
                    .buttonStyle(PSButtonStyle()).disabled(!model.enabled || model.busy)
            }.padding(28)
            HStack(spacing: 14) {
                TextField("Find a memory", text: $query).textFieldStyle(.roundedBorder).frame(maxWidth: 360)
                Spacer()
                Button(model.enabled ? "Pause saving" : "Resume saving") { Task { await model.setEnabled(!model.enabled) } }
                Button("Export…") { Task { await model.export() } }
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
            }.buttonStyle(PSButtonStyle()).disabled(model.busy).padding(.horizontal, 28).padding(.bottom, 20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    AgentConnectionsCard(model: model, reporting: reporting, line: Self.agentLine, color: agentColor)
                    LocalSupportCard(model: model.support, openLocal: openLocal)
                    if !model.enabled { Label("Saving is paused. Existing memories remain available.", systemImage: "pause.circle").foregroundStyle(.secondary) }
                    if let message = model.message { Text(message).font(.callout).textSelection(.enabled) }
                    if model.pendingRepairs > 0 {
                        Label("Some edited copies need review. Your changes have been preserved.", systemImage: "exclamationmark.circle")
                        Button("Show memory folder") { NSWorkspace.shared.open(model.root) }
                    }
                    if model.loaded && model.facts.isEmpty {
                        VStack(alignment: .leading, spacing: 14) {
                            Image(systemName: "sparkles.rectangle.stack").font(.system(size: 30)).foregroundStyle(PSStyle.accent)
                            Text("A little continuity goes a long way.").font(.title2.weight(.semibold))
                            Text("Save a preference or a decision here. Connected agents can read your memories and propose new ones as you work.")
                                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            Text("No account or existing vault needed.").font(.callout.weight(.medium))
                        }.padding(28).frame(maxWidth: .infinity, alignment: .leading)
                            .background(PSStyle.surface, in: RoundedRectangle(cornerRadius: 14))
                    }
                    ForEach(filtered) { fact in
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text(fact.scope == "personal" ? "Personal" : "Project memory").font(.caption.weight(.semibold)).foregroundStyle(PSStyle.accent)
                                Spacer()
                                Text(fact.attribution == "human_statement" ? "Saved by you" : "Agent interpretation").font(.caption).foregroundStyle(.secondary)
                                Menu {
                                    Button("Edit…") { editing = fact; draft = fact.body; editorPresented = true }.disabled(!model.enabled)
                                    Button("Forget…", role: .destructive) { forgetting = fact }
                                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 28)
                            }
                            Text(fact.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            DisclosureGroup("Source and scope") {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(fact.source_excerpt).textSelection(.enabled)
                                    Text(fact.scope).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                            }.font(.callout).foregroundStyle(.secondary)
                        }.padding(22).background(PSStyle.surface, in: RoundedRectangle(cornerRadius: 14))
                            .overlay(RoundedRectangle(cornerRadius: 14).stroke(PSStyle.border))
                    }
                    if model.remaining > 0 { Button("Load more (\(model.remaining) remaining)") { Task { await model.refresh(more: true) } }.disabled(model.busy) }
                    Text("Stored locally on this Mac. Forgetting removes Planisphere’s owned memory copies; original chats, task records and exports remain separate.")
                        .font(.caption).foregroundStyle(.secondary).padding(.top, 8)
                }.padding(28).frame(maxWidth: 900, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
            }
        }.background(PSStyle.canvas)
        .task { await model.refresh() }
        .sheet(isPresented: $editorPresented) {
            VStack(alignment: .leading, spacing: 18) {
                Text(editing == nil ? "Add a memory" : "Edit memory").font(.title2.weight(.semibold))
                Text("What should Planisphere remember?").foregroundStyle(.secondary)
                TextEditor(text: $draft).font(.body).frame(height: 170).border(PSStyle.border)
                if let message = model.message { Text(message).font(.caption).foregroundStyle(.secondary) }
                HStack { Spacer(); Button("Cancel") { editorPresented = false }; Button("Save") { Task { if await model.save(draft, replacing: editing) { editorPresented = false } } }.keyboardShortcut(.defaultAction).disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.utf8.count > 4096 || model.busy) }
            }.padding(28).frame(width: 520).interactiveDismissDisabled(model.busy)
        }
        .confirmationDialog("Forget this memory?", isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } }), titleVisibility: .visible) {
            Button("Forget memory", role: .destructive) { if let fact = forgetting { Task { await model.forget(fact) } }; forgetting = nil }
            Button("Cancel", role: .cancel) { forgetting = nil }
        } message: { Text("Its saved revisions will be removed. Original chats, tasks and separate exports will remain.") }
    }
}

/// One row per agent app: whether Planisphere's memory hooks are in it, whether it reports to the console, and the action that fits.
struct AgentConnectionsCard: View {
    @Bindable var model: MemoryModel
    var reporting: ReportingModel? = nil
    let line: (AgentHost, String?) -> String
    let color: (String?) -> Color

    static func reportingLine(_ host: AgentHost, _ reporting: ReportingModel?) -> String? {
        guard let reporting else { return nil }
        switch host {
        case .claudeCode: return ReportingModel.line(reporting.state)
        case .codex: return reporting.linked ? "Reporting for Codex is set up per project from Connections in the console." : nil
        }
    }
    private func reportingColor(_ state: ReportingModel.State) -> Color {
        switch state {
        case .connected: Color(nsColor: .systemGreen)
        case .keyRevoked, .unavailable: Color(nsColor: .systemOrange)
        default: Color.secondary.opacity(0.5)
        }
    }
    private var connectsReportingToo: Bool { reporting?.canConnect == true }
    private var busy: Bool { model.busy || reporting?.busy == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 18) {
                Image(systemName: "point.3.connected.trianglepath.dotted").font(.title2).foregroundStyle(PSStyle.accent)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Take your memory into your agents").font(.callout.weight(.semibold))
                    Text(reporting?.linked == true
                         ? "Planisphere adds local hooks to each app you connect, and reports Claude Code activity to your console workspace with a key it holds for you. Your other hooks and settings stay as they are."
                         : "Planisphere adds local hooks to each app you connect. Your other hooks and settings stay as they are.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            ForEach(AgentHost.allCases) { host in
                Divider()
                HStack(alignment: .center, spacing: 12) {
                    Circle().fill(color(model.agentStatus[host])).frame(width: 7, height: 7)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(host.name).font(.callout.weight(.medium))
                        Text(line(host, model.agentStatus[host])).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let report = Self.reportingLine(host, reporting) {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                if host == .claudeCode, let reporting {
                                    Circle().fill(reportingColor(reporting.state)).frame(width: 5, height: 5).offset(y: -1)
                                }
                                Text(report).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }.accessibilityIdentifier("agent-reporting-\(host.rawValue)")
                        }
                    }
                    Spacer(minLength: 12)
                    if ["installed", "disabled"].contains(model.agentStatus[host]) {
                        if host == .claudeCode, let reporting, reporting.canConnect {
                            Button("Connect reporting") { Task { await reporting.connect() } }
                        } else if host == .claudeCode, let reporting, reporting.isConnected {
                            Button("Disconnect reporting") { Task { await reporting.disconnect() } }
                        }
                        Button("Check setup") { Task { await model.refresh(); await reporting?.refresh() } }
                    } else {
                        // One step: the memory hooks, and the console's reporting hooks when this Mac is linked with permission.
                        Button("Connect \(host.name)") {
                            Task {
                                await model.connect(host)
                                if host == .claudeCode, connectsReportingToo, model.agentStatus[host] == "installed" { await reporting?.connect() }
                            }
                        }
                    }
                }.buttonStyle(PSButtonStyle()).disabled(busy)
            }
            if let message = reporting?.message { Text(message).font(.caption).textSelection(.enabled).accessibilityIdentifier("agent-reporting-message") }
        }.padding(20).background(PSStyle.surface, in: RoundedRectangle(cornerRadius: 14))
    }
}
