import SwiftUI
import PlanisphereConnection

struct ConsoleWorkspaceView: View {
    @Bindable var model: VaultAppModel
    let surface: ActivitySurface
    @State private var onMac = true
    @State private var query = ""
    @State private var localSelection: String?
    @State private var cloudSelection: String?
    @FocusState private var searchFocused: Bool

    private var activity: WorkspaceActivityModel { model.activity }
    private var connection: ConsoleConnectionModel { model.console }
    private var localPrompts: [LocalPrompt] {
        activity.local.prompts.filter { query.isEmpty || ($0.prompt + " " + $0.responses.joined(separator: " ")).localizedCaseInsensitiveContains(query) }
    }
    private var localPrompt: LocalPrompt? { localPrompts.first { $0.id == localSelection } }
    private var projectURL: URL? { model.selectedVault.map { URL(fileURLWithPath: $0.path, isDirectory: true) } }
    private var accountBinding: String { (connection.credential?.token ?? "") + ":" + String(connection.verified) + ":" + (connection.credential?.connection.permissions.joined(separator: ",") ?? "") }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if onMac {
                if activity.localBusy || activity.localProjectPath != projectURL.map(LocalWorkReader.canonicalPath) { ProgressView("Reading local activity…").frame(maxWidth: .infinity, maxHeight: .infinity) }
                else if surface == .prompts { localPromptBrowser }
                else { localHooks }
            } else if !ConsoleConnectionModel.isAvailable {
                empty("Workspace connection is coming", "This build keeps workspace sign-in disabled until the account service is released and verified.", symbol: "network")
            } else if !connection.verified || !activity.matches(connection.credential, verified: connection.verified) {
                VStack(spacing: 14) {
                    empty("Connect your workspace", connection.message ?? "Sign in to view activity reported to your own workspace.", symbol: "network")
                    Button("Manage Connection") { connection.presented = true }.buttonStyle(PSButtonStyle(primary: true)).padding(.bottom, 40)
                }
            } else {
                if let message = activity.message {
                    HStack {
                        Label(message, systemImage: "exclamationmark.circle").font(.callout).textSelection(.enabled)
                        Spacer()
                        Button("Connection…") { connection.presented = true }
                    }.padding(16).background(Color.orange.opacity(0.08))
                }
                if surface == .prompts { remotePromptBrowser } else { remoteHooks }
            }
        }
        .background(PSStyle.canvas)
        .task(id: model.selectedVaultID) { localSelection = nil; await activity.loadLocal(project: projectURL) }
        .task(id: accountBinding) {
            activity.bind(connection.credential, verified: connection.verified)
            cloudSelection = nil
            if !onMac { await refresh() }
        }
        .task(id: surface) { if !onMac { await refresh() } }
        .onChange(of: onMac) { _, _ in query = ""; localSelection = nil; cloudSelection = nil; Task { await refresh() } }
        .onChange(of: query) { _, _ in if onMac, localPrompt == nil { localSelection = nil } }
        .onChange(of: cloudSelection) { _, value in if let value { Task { await activity.select(value) } } }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                if !model.sidebarVisible {
                    PSIconButton(symbol: "sidebar.left", help: "Show sidebar") { model.sidebarVisible = true }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(surface.rawValue).font(.system(size: 24, weight: .semibold))
                    Text(onMac ? (model.selectedVault?.name ?? "Choose a local vault") : connection.title)
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Activity location", selection: $onMac) {
                    Text("On this Mac").tag(true)
                    Text("Workspace").tag(false)
                }.pickerStyle(.segmented).frame(width: 260).accessibilityIdentifier("activity-location")
                Button { Task { await refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .buttonStyle(PSButtonStyle()).disabled(activity.busy || activity.localBusy)
                    .keyboardShortcut("r", modifiers: .command)
            }
            if surface == .prompts {
                HStack {
                    TextField(onMac ? "Search captured prompts and responses" : "Search prompt, chat, agent or source", text: $query)
                        .textFieldStyle(.roundedBorder).focused($searchFocused)
                        .accessibilityIdentifier("prompt-search")
                        .onSubmit { if !onMac { activity.filter.query = query; Task { await activity.loadPrompts() } } }
                    if !onMac {
                        Picker("Agent", selection: Binding(get: { activity.filter.agent }, set: { activity.filter.agent = $0; Task { await activity.loadPrompts() } })) {
                            Text("All agents").tag(""); Text("Codex").tag("codex"); Text("Claude Code").tag("claude-code")
                        }.frame(width: 135)
                        Picker("Status", selection: Binding(get: { activity.filter.status }, set: { activity.filter.status = $0; Task { await activity.loadPrompts() } })) {
                            Text("All statuses").tag(""); Text("In progress").tag("in_progress"); Text("Completed").tag("completed"); Text("Interrupted").tag("interrupted"); Text("Unknown").tag("unknown")
                        }.frame(width: 145)
                        Picker("Date", selection: Binding(get: { activity.filter.days ?? 0 }, set: { activity.filter.days = $0 == 0 ? nil : $0; Task { await activity.loadPrompts() } })) {
                            Text("All dates").tag(0); Text("Last day").tag(1); Text("Last week").tag(7); Text("Last month").tag(30)
                        }.frame(width: 125)
                    }
                }
                if !onMac {
                    HStack {
                        TextField("Reporting source (optional)", text: Binding(get: { activity.filter.source }, set: { activity.filter.source = $0 }))
                            .textFieldStyle(.roundedBorder).frame(maxWidth: 280)
                            .onSubmit { activity.filter.query = query; Task { await activity.loadPrompts() } }
                        Text("Filters apply to reported records. Search with Return.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }.padding(24)
    }

    private var localPromptBrowser: some View {
        HSplitView {
            VStack(spacing: 0) {
                if localPrompts.isEmpty {
                    empty(query.isEmpty ? "No recent captured prompts" : "No matching prompts", "Only existing Planisphere captures for the selected vault appear here. Nothing is uploaded.", symbol: "text.bubble")
                } else {
                    List(selection: $localSelection) {
                        ForEach(localPrompts) { prompt in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(prompt.prompt).lineLimit(3).font(.system(size: 13, weight: .medium))
                                Text("\(prompt.agent.capitalized) · \(prompt.observedAt.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption).foregroundStyle(.secondary)
                                Text(prompt.responses.isEmpty ? "Response not captured" : "Response captured").font(.caption).foregroundStyle(.secondary)
                            }.padding(.vertical, 6).tag(prompt.id)
                        }
                    }.listStyle(.plain).accessibilityIdentifier("local-prompt-list")
                }
                localCoverage
            }.frame(minWidth: 260, idealWidth: 330, maxWidth: 420)
            ScrollView {
                if let prompt = localPrompt {
                    VStack(alignment: .leading, spacing: 22) {
                        Text(prompt.observedAt.formatted(date: .complete, time: .shortened)).font(.callout).foregroundStyle(.secondary)
                        contentSection("Prompt", body: prompt.prompt)
                        contentSection("Response", body: prompt.responses.isEmpty ? "No response was captured for this turn." : prompt.responses.joined(separator: "\n\n"))
                        coverageCard("This local source contains captured messages only. Tools, changed files, token usage and task outcome are not recorded here.")
                        DisclosureGroup("Source details") {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Project: \(prompt.project)"); Text("Chat: \(prompt.session)"); Text("Turn: \(prompt.turn)")
                            }.font(.caption).textSelection(.enabled).padding(.top, 8)
                        }
                        Button("View Hooks") { model.activitySurface = .hooks }.buttonStyle(PSButtonStyle())
                    }.padding(26).frame(maxWidth: .infinity, alignment: .leading)
                } else { empty("Select a prompt", "Read the prompt and captured response here.", symbol: "text.alignleft") }
            }.frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var remotePromptBrowser: some View {
        HSplitView {
            VStack(spacing: 0) {
                if activity.busy && activity.prompts.isEmpty { ProgressView("Loading prompts…").padding(30) }
                else if activity.prompts.isEmpty { empty("No reported prompts", "Connected agents appear here after sending usage records. Missing reports do not mean zero activity.", symbol: "text.bubble") }
                List(selection: $cloudSelection) {
                    ForEach(activity.prompts) { prompt in
                        VStack(alignment: .leading, spacing: 5) {
                            Text("\(prompt.agent_system.capitalized) · \(date(prompt.started_at))").font(.system(size: 13, weight: .medium))
                            Text(prompt.system_id).font(.caption).foregroundStyle(.secondary)
                            Text(prompt.status.replacingOccurrences(of: "_", with: " ").capitalized).font(.caption)
                        }.padding(.vertical, 5).tag(prompt.id)
                    }
                }.listStyle(.plain).accessibilityIdentifier("workspace-prompt-list")
                if activity.nextCursor != nil {
                    Button("Load older prompts") { Task { await activity.loadPrompts(more: true) } }.disabled(activity.busy).padding(12)
                }
            }.frame(minWidth: 260, idealWidth: 320, maxWidth: 400)
            ScrollView {
                if activity.detailBusy { ProgressView("Loading prompt…").padding(40) }
                else if let error = activity.detailMessage { empty("Prompt unavailable", error, symbol: "exclamationmark.circle") }
                else if let prompt = activity.detail {
                    VStack(alignment: .leading, spacing: 20) {
                        Text(prompt.agent_system.capitalized).font(.title2.weight(.semibold))
                        Text("\(date(prompt.started_at)) · \(prompt.status.replacingOccurrences(of: "_", with: " "))").foregroundStyle(.secondary)
                        coverageCard("This workspace source reports usage, not prompt or response text. Read existing captured messages under On this Mac. Tools, files and task outcomes are not provided by this source.")
                        HStack(spacing: 35) {
                            metric("Input tokens", prompt.summary.metrics["input_tokens"])
                            metric("Output tokens", prompt.summary.metrics["output_tokens"])
                        }
                        Text("Coverage: \(prompt.coverage.status)").font(.headline)
                        ForEach(prompt.coverage.limitations, id: \.self) { Text($0).font(.callout).foregroundStyle(.secondary) }
                        if let calls = prompt.calls, !calls.isEmpty {
                            Text("Reported model calls").font(.headline)
                            ForEach(calls) { call in
                                HStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(call.model ?? "Model not reported")
                                        Text("\(call.provider ?? "Provider unknown") · \(call.measurement)").font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer(); Text(call.status.replacingOccurrences(of: "_", with: " ")).font(.caption)
                                }.padding(12).background(PSStyle.surface, in: RoundedRectangle(cornerRadius: 8))
                            }
                        }
                        if let receipt = prompt.bound_receipt_id,
                           let url = URL(string: "https://api.planisphere.ooo/receipts/" + receipt.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!) {
                            Link("Open linked receipt", destination: url)
                        }
                        Text("Source: \(prompt.system_id)\nChat: \(prompt.session_id)\nPrompt: \(prompt.prompt_id)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        Button("View Hooks") { model.activitySurface = .hooks }.buttonStyle(PSButtonStyle())
                    }.padding(26).frame(maxWidth: .infinity, alignment: .leading)
                } else { empty("Select a prompt", "Inspect reported usage and collection gaps.", symbol: "text.alignleft") }
            }.frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var localHooks: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HookPresetsCard(model: model.memory.presets, openLocal: { model.activitySurface = .local })
                coverageCard("Configuration is not proof of execution. Host approval, last execution and local delivery errors are not reported by these settings. Workspace shows records actually received.")
                if activity.local.hooks.isEmpty { empty("No Planisphere hooks found", "No matching hooks were found in the supported Codex and Claude Code settings for this Mac and the selected vault.", symbol: "point.3.connected.trianglepath.dotted") }
                ForEach(activity.local.hooks) { hook in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Label(hook.purpose, systemImage: "point.3.connected.trianglepath.dotted").font(.headline)
                            Spacer()
                            Text(hook.disabled ? "Disabled in settings" : "Configured · execution unverified")
                                .font(.caption).foregroundStyle(hook.disabled ? Color.secondary : PSStyle.accent)
                        }
                        Text("\(hook.agent) · \(hook.scope) · \(hook.event)").font(.callout).foregroundStyle(.secondary)
                        Text(hook.version.map { "Installed build: " + String($0.prefix(12)) } ?? "Installed version not reported")
                            .font(.caption).foregroundStyle(.secondary)
                        DisclosureGroup("Configuration location") { Text(hook.configurationPath).font(.caption).textSelection(.enabled).padding(.top, 8) }
                    }.padding(18).background(PSStyle.surface, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(PSStyle.border))
                }
                localCoverage
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }.accessibilityIdentifier("local-hooks-list")
    }

    private var remoteHooks: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                coverageCard("These are received records by reporting source. A recent record does not prove every hook is active or approved. Installed versions and local failures are shown only when that evidence is available.")
                if activity.busy { ProgressView("Loading activity…") }
                else if activity.hooks.isEmpty { empty("No received hook activity", "Records from this workspace will appear after a connected agent reports work.", symbol: "network") }
                ForEach(activity.hooks) { hook in
                    VStack(alignment: .leading, spacing: 9) {
                        Text(hook.system_id).font(.headline)
                        Text(hook.observed_connector ?? "Connector not reported").foregroundStyle(.secondary)
                        Text("Last received: \(date(hook.last_recorded_at))").font(.callout)
                        Text("\(hook.records_24h) records in the last 24 hours · \(hook.last_event_type ?? "Event type unavailable")").font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(18)
                    .background(PSStyle.surface, in: RoundedRectangle(cornerRadius: 12))
                }
                if activity.hooksTruncated { Text("Showing the 200 most recently observed sources.").font(.caption).foregroundStyle(.secondary) }
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var localCoverage: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(activity.local.notices, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
    }
    private func contentSection(_ title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            Text(body).font(.system(size: 14)).lineSpacing(4).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func coverageCard(_ text: String) -> some View {
        Label(text, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(PSStyle.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }
    private func empty(_ title: String, _ description: String, symbol: String) -> some View {
        ContentUnavailableView(title, systemImage: symbol, description: Text(description))
            .frame(maxWidth: .infinity, maxHeight: .infinity).padding(18)
    }
    private func metric(_ label: String, _ value: UsageMetric?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value?.observed.map { $0.formatted(.number.precision(.fractionLength(0))) } ?? "Not reported").font(.title2.monospacedDigit())
            if let estimate = value?.estimated, estimate > 0 { Text("Estimated: \(Int(estimate))").font(.caption) }
            if let missing = value?.missing_observations, missing > 0 { Text("\(missing) observations missing").font(.caption) }
        }
    }
    private func date(_ text: String?) -> String {
        guard let text else { return "Time not reported" }
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let value = format.date(from: text) ?? ISO8601DateFormatter().date(from: text)
        return value?.formatted(date: .abbreviated, time: .shortened) ?? text
    }
    private func refresh() async {
        if onMac { await activity.loadLocal(project: projectURL) }
        else {
            activity.bind(connection.credential, verified: connection.verified)
            if surface == .prompts { activity.filter.query = query; await activity.loadPrompts() }
            else { await activity.loadHooks() }
        }
    }
}
