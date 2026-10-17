import AppKit
import SwiftUI
import PlanisphereCore

struct OnboardingView: View {
    @Bindable var model: VaultAppModel
    var interactive = true
    @State private var showLocal = false
    @State private var showHooks = false
    private var setup: OnboardingModel { model.onboarding }
    private let ink = Color(red: 0.12, green: 0.22, blue: 0.22)
    @Environment(\.colorScheme) private var colorScheme
    private var teal: Color { colorScheme == .dark ? Color(red: 0.43, green: 0.73, blue: 0.66) : Color(red: 0.17, green: 0.43, blue: 0.39) }
    private var steps: [OnboardingProgress.Step] { OnboardingProgress.Step.allCases.filter { $0 != .complete } }
    private var currentIndex: Int { steps.firstIndex(of: setup.step) ?? 5 }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                Label("PLANISPHERE", systemImage: "circle.hexagongrid")
                    .font(.system(size: 13, weight: .semibold)).tracking(2)
                Spacer(minLength: 12)
                Image(systemName: "globe.europe.africa").font(.system(size: 76, weight: .ultraLight))
                    .foregroundStyle(Color.white.opacity(0.85))
                Text("A place for\nwhat you\nknow.")
                    .font(.system(size: 36, weight: .medium, design: .serif)).lineSpacing(1).fixedSize(horizontal: false, vertical: true)
                Text("Your sources. Your agents.\nOne shared starting point.")
                    .font(.system(size: 14)).lineSpacing(5).foregroundStyle(.white.opacity(0.7)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 15)
                VStack(alignment: .leading, spacing: 17) {
                    ForEach(Array(steps.enumerated()), id: \.element) { index, step in
                        HStack(spacing: 11) {
                            ZStack {
                                Circle().fill(index == currentIndex ? Color.white : Color.white.opacity(0.12)).frame(width: 23, height: 23)
                                if index < currentIndex { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)) }
                                else { Text("\(index + 1)").font(.system(size: 11, weight: .semibold)).foregroundStyle(index == currentIndex ? ink : .white) }
                            }
                            Text(step.title).font(.system(size: 13, weight: index == currentIndex ? .semibold : .regular))
                                .foregroundStyle(.white.opacity(index == currentIndex ? 1 : 0.65))
                        }
                    }
                }
                Text("Setup saves as you go.").font(.system(size: 11)).foregroundStyle(.white.opacity(0.55)).padding(.top, 10)
            }
            .foregroundStyle(.white)
            .padding(36).frame(width: 320, alignment: .leading).frame(maxHeight: .infinity)
            .background(LinearGradient(colors: [ink, teal], startPoint: .topLeading, endPoint: .bottomTrailing))
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack {
                        Text("MAKE YOURSELF AT HOME").tracking(2).font(.system(size: 10, weight: .semibold)).foregroundStyle(teal)
                        Spacer()
                        Text("\(currentIndex + 1) / 6").font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .padding(.bottom, 12)
                    if [.vaultSetup, .localModel, .worldKnowledge].contains(setup.step) {
                        Button("Back to source vaults") {
                            setup.saved.progress.revisitSources(); setup.consent = false
                            setup.saved.operationID = UUID(); _ = setup.persist()
                            setup.discover(existing: model.vaults)
                        }.buttonStyle(.plain).foregroundStyle(teal).disabled(setup.busy || setup.checking)
                    }
                    if setup.checking { ProgressView("Checking what you’ve already set up…") }
                    content.disabled(setup.checking)
                    if !model.vaults.isEmpty {
                        Button("Finish later — open workspace") { model.leaveOnboarding() }
                            .disabled(setup.busy || setup.checking)
                    }
                    if let message = setup.message {
                        Label(message, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                    if setup.busy { ProgressView("Working on your setup…").controlSize(.small) }
                }
                .padding(48).frame(maxWidth: 840, alignment: .leading).frame(maxWidth: .infinity)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .tint(teal)
        .task(id: setup.step) {
            guard interactive else { return }
            await model.refreshOnboardingRecovery()
            while setup.step == .agent && !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { break }
                await model.refreshOnboardingRecovery()
            }
        }
        .sheet(isPresented: Binding(get: { model.console.presented }, set: { model.console.presented = $0 })) {
            ConsoleConnectionView(connection: model.console)
        }
        .sheet(isPresented: $showLocal) {
            VStack(spacing: 0) {
                LocalModelsView(runtime: model.memory.support.runtime, support: model.memory.support, open: { _ in })
                Divider()
                Button("Return to setup") { showLocal = false }.padding(16)
            }.frame(width: 850, height: 650)
        }
    }

    @ViewBuilder private var content: some View {
        switch setup.step {
        case .account: account
        case .agent: agent
        case .existingVaults: sources
        case .vaultSetup: destination
        case .localModel: localModel
        case .worldKnowledge: knowledge
        case .complete: Text("Your knowledge home is ready.")
        }
    }
    private func heading(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.system(size: 33, weight: .semibold)).tracking(-0.8)
            Text(subtitle).font(.system(size: 15)).lineSpacing(4).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
    private func primary(_ title: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) { Text(title); Image(systemName: "arrow.right") }.padding(.horizontal, 8).padding(.vertical, 6)
        }.buttonStyle(OnboardingPrimaryStyle(color: teal)).controlSize(.large).disabled(disabled || setup.busy)
    }
    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14, content: content).padding(22).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.08)))
    }
    private var account: some View {
        VStack(alignment: .leading, spacing: 26) {
            heading("Welcome to Planisphere.", "Connect your account once. Your agents and knowledge can then find their way back to the same home.")
            card {
                Label("Secure sign-in, in your browser", systemImage: "lock.shield").font(.headline)
                Text("Log in or create an account in the browser. Planisphere connects this Mac to your Console workspace when you return.").foregroundStyle(.secondary)
                if model.console.verified {
                    Label(model.console.title, systemImage: "checkmark.circle.fill").foregroundStyle(teal)
                    primary("Continue") { setup.accountVerified(model.console.verified) }
                } else {
                    HStack {
                        primary("Log in", disabled: model.console.busy) { Task { await model.console.connect() } }
                        Button("Sign up") { Task { await model.console.connect() } }.controlSize(.large).disabled(model.console.busy)
                    }
                    if model.console.busy {
                        ProgressView("Waiting for your browser…").controlSize(.small)
                        Button("Cancel sign-in") { model.console.cancel() }
                    }
                    if model.console.needsSignIn { Button("Reconnect account") { Task { await model.console.reconnect() } } }
                    else if model.console.credential != nil { Button("Check account again") { Task { await model.console.refresh() } } }
                }
                if let message = model.console.message { Text(message).font(.callout).foregroundStyle(.secondary) }
            }
            Label("Your source vaults stay on this Mac.", systemImage: "internaldrive").font(.callout).foregroundStyle(.secondary)
        }
    }
    private var agent: some View {
        VStack(alignment: .leading, spacing: 22) {
            heading("Meet your first agent.", "Existing healthy connections are kept. If a run is still missing, open a fresh agent chat beside this window; there’s no need to reinstall.")
            HStack {
                ForEach(AgentHost.allCases) { host in
                    Button(host == .claudeCode ? "Claude Code · Terminal" : "Codex") { setup.selectedAgent = host }
                        .buttonStyle(.bordered).tint(setup.selectedAgent == host ? teal : .secondary)
                }
            }
            card {
                let host = setup.selectedAgent
                let report = model.memory.agentReports[host]
                HStack {
                    Text(host.name).font(.title3.weight(.semibold)); Spacer()
                    Label(setup.verifiedAgent(report) ? "Hook ran successfully" : "Waiting for a fresh run", systemImage: setup.verifiedAgent(report) ? "checkmark.circle.fill" : "circle.dotted")
                        .font(.caption).foregroundStyle(teal)
                }
                Text("Context delivery is separate from a successful hook run.").font(.caption).foregroundStyle(.secondary)
                Button("Open Hooks") { showHooks = true }.buttonStyle(.link)
                    .sheet(isPresented: $showHooks) { VStack { HStack { Text("Hooks").font(.headline); Spacer(); Button("Done") { showHooks = false } }.padding(); ScrollView { HookPresetsCard(model: model.memory.presets).padding() } }.frame(width: 720, height: 560).task { await model.memory.presets.refresh() } }
                Text(host == .claudeCode ? "Connect installs local memory and vault access, and provisions reporting through your signed-in account. No key to copy." : "Connect installs local memory and vault access. Console reporting for Codex uses its separate project integration; this build does not provision that key.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    if report?.status == "installed", report?.broken == false {
                        Button("Check existing connection") { Task { await model.verifyExistingOnboardingAgent() } }
                            .buttonStyle(.borderedProminent).disabled(setup.busy)
                    } else {
                        Button("Connect \(host.name)") { Task { await model.connectOnboardingAgent(host) } }.buttonStyle(.borderedProminent).disabled(setup.busy)
                    }
                    Button("Copy setup prompt") { setup.copyPrompt(setup.setupPrompt(host)) }.buttonStyle(.bordered)
                }
                if let report {
                    Text(report.lastRunLine() ?? "No hook run recorded yet.").font(.callout)
                    if let problem = report.problem { Text(problem).font(.callout).foregroundStyle(.orange) }
                }
                if let message = model.memory.message { Text(message).font(.caption).foregroundStyle(.secondary) }
                if host == .claudeCode {
                    Text(model.reporting.isConnected ? "Console reporting connected" : (model.reporting.message ?? "Reporting connects with your account when you click Connect.")).font(.caption).foregroundStyle(.secondary)
                    if model.reporting.canConnect {
                        Button("Connect reporting only") { Task { await model.connectOnboardingReporting() } }.disabled(setup.busy)
                    }
                    if !model.reporting.isConnected { Button("Manage account connection…") { model.console.presented = true } }
                }
            }
            card {
                Label("Claude desktop", systemImage: "desktopcomputer").font(.headline)
                Text("Claude desktop does not run Claude Code terminal hooks. Its connector must be configured separately; it cannot satisfy this local-agent step yet.").font(.callout).foregroundStyle(.secondary)
                Button("Copy desktop guidance") {
                    setup.copyPrompt("I use Claude desktop, not Claude Code terminal. Help me inspect available Planisphere connectors. Do not claim terminal hooks are installed in this desktop app or ask me to paste account secrets. Local first-run verification currently requires Codex or Claude Code terminal.")
                }
            }
            primary("Agent connected — continue", disabled: !setup.verifiedAgent(model.memory.agentReports[setup.selectedAgent])) { model.finishOnboardingAgent() }
        }
    }
    private var sources: some View {
        VStack(alignment: .leading, spacing: 22) {
            heading("Bring what you already know.", "Start with your existing Obsidian vaults. These sources will inform World Knowledge in the final step; adding them keeps their files in place.")
            HStack {
                Button("Choose folders…") { setup.chooseFolders() }.buttonStyle(.bordered).disabled(setup.busy)
                Button("Discover again") { setup.discover(existing: model.vaults) }.buttonStyle(.bordered).disabled(setup.busy)
            }
            if setup.candidates.isEmpty {
                card { Text("No existing vaults found.").font(.headline); Text("Choose a folder, or continue and describe your new knowledge home in the next step.").foregroundStyle(.secondary) }
            } else {
                card {
                    ForEach(setup.candidates) { source in
                        Toggle(isOn: Binding(get: { setup.candidates.first(where: { $0.id == source.id })?.selected ?? false }, set: { setup.selectSource(id: source.id, selected: $0) })) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(source.url.lastPathComponent).font(.headline)
                                Text(source.url.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                if source.registeredID != nil { Text("Already added — kept in place").font(.caption).foregroundStyle(teal) }
                                if let error = source.error { Text(error).font(.caption).foregroundStyle(.orange) }
                            }
                        }.toggleStyle(.checkbox).padding(.vertical, 5).disabled(setup.busy)
                    }
                }
            }
            HStack {
                if !setup.candidates.isEmpty {
                    primary("Use all & continue") {
                        setup.selectAllSources()
                        Task { await model.addOnboardingSources() }
                    }
                }
                Button(setup.candidates.isEmpty ? "Continue without existing vaults" : "Continue with selection") { Task { await model.addOnboardingSources() } }.disabled(setup.busy)
            }
        }
    }
    private var destination: some View {
        VStack(alignment: .leading, spacing: 24) {
            heading("Give your knowledge a home.", "World Knowledge is a Planisphere-managed vault: a useful starting map across the sources you selected, available to your connected local agents.")
            card {
                Label("World Knowledge", systemImage: "folder.badge.gearshape").font(.headline)
                Text(setup.saved.destination?.path ?? "Choose a location").font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                Button("Choose location…") { setup.chooseDestination() }
                Text("The new folder is created only after your permission in the final step.").font(.caption).foregroundStyle(.secondary)
            }
            TextField("What would you like this knowledge home to help with?", text: Binding(get: { setup.saved.purpose }, set: { setup.saved.purpose = $0; _ = setup.persist() }), axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(3...5)
            if setup.saved.progress.sourceVaultIDs.isEmpty { Text("With no source vaults, your purpose becomes the first note. Add existing sources for a richer map.").font(.callout).foregroundStyle(.secondary) }
            primary("Use this home", disabled: setup.saved.destination == nil || (setup.saved.progress.sourceVaultIDs.isEmpty && setup.saved.purpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)) { setup.confirmDestination() }
        }
    }
    private var localModel: some View {
        VStack(alignment: .leading, spacing: 24) {
            heading("A little intelligence, locally.", "Add Planisphere’s own model for local support, or come back to it later. Your World Knowledge map works either way.")
            card {
                Label("Runs on your Mac", systemImage: "cpu").font(.headline)
                Text("Optional 2.5 GB download. The model runs locally and can prepare evidence for connected agents.").foregroundStyle(.secondary)
                Button("Install local model…") { showLocal = true }.buttonStyle(.borderedProminent)
            }
            primary("Continue") { setup.finishModelChoice() }
            Button("Not now") { setup.finishModelChoice() }
        }
    }
    private var knowledge: some View {
        VStack(alignment: .leading, spacing: 24) {
            heading("Turn sources into a starting point.", "One map to find your way through what you know. Planisphere will read the selected vaults and create your first World Knowledge vault.")
            card {
                Label("What will be created", systemImage: "map").font(.headline)
                Text("Start Here, a source map for each selected vault, original-file links, headings, short excerpts and source fingerprints. This is a grounded table of contents, not an AI-written synthesis.").foregroundStyle(.secondary)
                Text("\(setup.saved.progress.sourceVaultIDs.count) source vaults · stored locally").font(.callout.weight(.medium))
                Text("Uses readable Markdown notes up to 512 KiB each, with source scope exclusions applied. Hidden files and links are omitted. Original files stay in place. The map is a dated snapshot, not a verification of its sources.").font(.caption).foregroundStyle(.secondary)
            }
            Toggle(isOn: Binding(get: { setup.consent }, set: { setup.consent = $0 })) {
                Text("I allow Planisphere to gather context from my selected vaults and create this managed World Knowledge vault.").font(.callout)
            }.toggleStyle(.checkbox)
            primary("Create World Knowledge & open Planisphere", disabled: !setup.consent) { Task { await model.createOnboardingKnowledge() } }
            Text("If a source cannot be read, setup stays here with a retryable error. No empty success screen.").font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct OnboardingPrimaryStyle: ButtonStyle {
    let color: Color
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 14, weight: .semibold))
            .foregroundStyle(enabled ? Color.white : Color.secondary)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(enabled ? color.opacity(configuration.isPressed ? 0.8 : 1) : Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }
}
