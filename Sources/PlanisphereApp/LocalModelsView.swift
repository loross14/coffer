import AppKit
import SwiftUI

/// The Local tab: Planisphere's own model, what uses it, a place to try it, and its details.
struct LocalModelsView: View {
    @Bindable var runtime: ModelRuntimeModel
    @Bindable var support: LocalSupportModel
    var open: (ActivitySurface) -> Void
    @State private var prompt = ""
    @State private var confirmRemove = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                PSSectionLabel(title: "On this Mac")
                Text("Local").font(.system(size: 30, weight: .semibold)).tracking(-0.8)
                Text("Your own model, running on this Mac. Nothing else to install.").foregroundStyle(.secondary)
            }.padding(28)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    modelCard
                    if runtime.record != nil {
                        putToWork
                        tryIt
                        details
                    } else {
                        purpose
                    }
                }
                .padding(28).frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(PSStyle.canvas)
        .task {
            await runtime.refresh()
            await support.refresh(inventory: false)
            await runtime.scanAgentHooks()
        }
        .confirmationDialog("Remove the Planisphere model?", isPresented: $confirmRemove) {
            Button("Remove model", role: .destructive) { Task { await runtime.remove(); await support.refresh() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This stops the model and deletes its 2.5 GB file from this Mac. Features that use it pause until you install it again.")
        }
    }

    // MARK: Model card

    private var modelCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 14) {
                RoundedRectangle(cornerRadius: 11).fill(PSStyle.accent.opacity(0.12)).frame(width: 46, height: 46)
                    .overlay(Image(systemName: "cpu").font(.system(size: 21, weight: .medium)).foregroundStyle(PSStyle.accent))
                VStack(alignment: .leading, spacing: 4) {
                    Text(runtime.spec.name).font(.system(size: 17, weight: .semibold))
                    HStack(spacing: 6) {
                        Circle().fill(statusColor).frame(width: 7, height: 7)
                        Text(statusLine).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 12)
                cardActions
            }
            if case .installing(_, let fraction) = runtime.phase {
                VStack(alignment: .leading, spacing: 8) {
                    if let fraction {
                        GeometryReader { bar in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.primary.opacity(0.08))
                                Capsule().fill(PSStyle.accent).frame(width: max(6, bar.size.width * fraction))
                            }
                        }.frame(height: 6).animation(.easeOut(duration: 0.25), value: fraction)
                    }
                    HStack(spacing: 8) {
                        if fraction == nil { ProgressView().controlSize(.small) }
                        Text(progressCaption(fraction)).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
            if runtime.record != nil {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                    readout("Last reply", runtime.lastReply.map { String(format: "%.2f s", $0.seconds) } ?? "—")
                    readout("Context", "\(runtime.spec.contextLength / 1024)K")
                    readout("On disk", ModelRuntimeModel.size(runtime.spec.sizeBytes))
                    readout("Address", ":\(runtime.spec.port)", help: "127.0.0.1 — only this Mac can reach it")
                }
            } else if !runtime.busy {
                Text(installDetail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if runtime.needsApproval {
                HStack(spacing: 10) {
                    Image(systemName: "hand.raised").foregroundStyle(.secondary)
                    Text("Allow Planisphere in Login Items so the model can run in the background.")
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Open Login Items") { runtime.openLoginItems() }.buttonStyle(PSButtonStyle())
                }
            }
            if case .failed(let message) = runtime.phase {
                Label(message, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(22)
        .background(PSStyle.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(PSStyle.border))
    }

    @ViewBuilder private var cardActions: some View {
        switch runtime.phase {
        case .notInstalled, .failed:
            HStack(spacing: 8) {
                if runtime.existingCopy != nil {
                    Button("Use the copy on this Mac") { runtime.useExistingCopy() }.buttonStyle(PSButtonStyle(primary: true))
                }
                Button("Download \(ModelRuntimeModel.size(runtime.spec.sizeBytes))") { runtime.download() }
                    .buttonStyle(PSButtonStyle(primary: runtime.existingCopy == nil))
            }
        case .installing:
            Button("Cancel") { runtime.cancel() }.buttonStyle(PSButtonStyle())
        case .installed:
            Button("Start") { Task { await runtime.start(); await support.refresh() } }.buttonStyle(PSButtonStyle(primary: true))
        case .running:
            Button("Stop") { Task { await runtime.stop(); await support.refresh(inventory: false) } }.buttonStyle(PSButtonStyle())
        case .checking, .starting:
            ProgressView().controlSize(.small)
        }
    }

    private var statusColor: Color {
        switch runtime.phase {
        case .running: Color(nsColor: .systemGreen)
        case .failed: Color(nsColor: .systemOrange)
        case .installing, .starting, .checking: PSStyle.accent
        default: Color.secondary.opacity(0.5)
        }
    }

    private var statusLine: String {
        switch runtime.phase {
        case .checking: "Checking…"
        case .notInstalled: "Not installed"
        case .installing(let text, let fraction): fraction.map { "\(text.replacingOccurrences(of: "…", with: "")) · \(Int($0 * 100))%" } ?? text
        case .installed: "Installed · not running"
        case .starting: "Starting…"
        case .running: "Running · answers only this Mac"
        case .failed: "Needs attention"
        }
    }

    private var installDetail: String {
        runtime.existingCopy != nil
            ? "A copy is already on this Mac. Planisphere checks it against a pinned fingerprint and keeps its own copy — no download needed."
            : "One download from Hugging Face, checked against a pinned fingerprint before it's used. It then runs in the background and only answers this Mac."
    }

    private func progressCaption(_ fraction: Double?) -> String {
        let total = ModelRuntimeModel.size(runtime.spec.sizeBytes)
        guard let fraction else { return "Checking against the pinned fingerprint…" }
        let done = ModelRuntimeModel.size(Int64(Double(runtime.spec.sizeBytes) * fraction))
        return "\(done) of \(total) · keep Planisphere open while it downloads"
    }

    // What the model is for, before it's installed.
    private var purpose: some View {
        VStack(alignment: .leading, spacing: 12) {
            PSSectionLabel(title: "What it's for")
            purposeLine("sparkles", "Prepares evidence from your memory for your agent, in the background.")
            purposeLine("puzzlepiece.extension", "Answers tools on this Mac, like the Adapters sandbox, through a standard local endpoint.")
            purposeLine("lock", "Runs entirely on this Mac. No account, no API key, no other app.")
        }
    }

    private func purposeLine(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(PSStyle.accent).frame(width: 18)
            Text(text).font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func readout(_ label: String, _ value: String, help: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 17, weight: .semibold)).monospacedDigit()
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PSStyle.canvas, in: RoundedRectangle(cornerRadius: 9))
        .help(help ?? "")
    }

    // MARK: Put to work

    private var putToWork: some View {
        VStack(alignment: .leading, spacing: 10) {
            PSSectionLabel(title: "Put to work")
            VStack(spacing: 0) {
                row(symbol: "sparkles", title: "Memory evidence prep", detail: memoryDetail,
                    action: ("Open Memory", { open(.memory) }))
                Divider().padding(.leading, 50)
                row(symbol: "checkmark.bubble", title: "Agent reply review", detail: hooksDetail,
                    trailing: runtime.agentHooks > 0 ? "Connected" : nil)
                Divider().padding(.leading, 50)
                row(symbol: "puzzlepiece.extension", title: "Adapters sandbox", detail: "Test prompts against this model",
                    action: ("Open Adapters", { open(.adapters) }))
            }
            .background(PSStyle.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(PSStyle.border))
        }
    }

    private var memoryDetail: String {
        guard let status = support.status, status.enabled else { return "Off · set it up in Memory" }
        return status.mode == "optimize" ? "Preparing evidence for your agent" : "Observing · delivery unchanged"
    }

    private var hooksDetail: String {
        switch runtime.agentHooks {
        case 0: "No agent hooks use it yet"
        case 1: "1 agent hook uses this model"
        default: "\(runtime.agentHooks) agent hooks use this model"
        }
    }

    private func row(symbol: String, title: String, detail: String, action: (String, () -> Void)? = nil, trailing: String? = nil) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 15)).foregroundStyle(PSStyle.accent).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            if let action {
                Button(action.0, action: action.1).buttonStyle(.link).font(.system(size: 12))
            } else if let trailing {
                Text(trailing).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
    }

    // MARK: Try it

    private var tryIt: some View {
        VStack(alignment: .leading, spacing: 10) {
            PSSectionLabel(title: "Try it")
            HStack(spacing: 10) {
                TextField("Question", text: $prompt, prompt: Text("Summarize why checkpoints matter in one sentence"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await runtime.ask(prompt) } }
                Button(runtime.asking ? "Asking…" : "Ask") { Task { await runtime.ask(prompt) } }
                    .buttonStyle(PSButtonStyle())
                    .disabled(runtime.phase != .running || runtime.asking || prompt.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if runtime.phase != .running {
                Text("Start the model to try it.").font(.caption).foregroundStyle(.secondary)
            } else if let error = runtime.askError {
                Text(error).font(.caption).foregroundStyle(.secondary)
            } else if let reply = runtime.lastReply {
                VStack(alignment: .leading, spacing: 6) {
                    Text(reply.text).font(.system(size: 13)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Text(replyCaption(reply)).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(PSStyle.surface, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(PSStyle.border))
            }
        }
    }

    private func replyCaption(_ reply: ModelRuntimeModel.Reply) -> String {
        [String(format: "%.2f s", reply.seconds), reply.tokens.map { "\($0) tokens" }, "on this Mac"].compactMap { $0 }.joined(separator: " · ")
    }

    // MARK: Details

    private var details: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 18, verticalSpacing: 8) {
            GridRow {
                detailLabel("Fingerprint")
                HStack(spacing: 6) {
                    Text(runtime.fingerprint).font(.system(size: 12, design: .monospaced))
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(runtime.spec.sha256, forType: .string)
                    } label: { Image(systemName: "doc.on.doc").font(.system(size: 11)) }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("Copy the full SHA-256")
                }
            }
            GridRow { detailLabel("Server"); detailValue("llama.cpp 0.6.0 · built into Planisphere") }
            GridRow { detailLabel("Licenses"); detailValue("Model Apache-2.0 · server MIT") }
            GridRow {
                detailLabel("Stored in")
                HStack(spacing: 6) {
                    detailValue("Application Support › Planisphere › Models")
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([runtime.location.modelFile(runtime.spec)]) }
                        .buttonStyle(.link).font(.system(size: 12))
                }
            }
            GridRow {
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                Button("Remove model…") { confirmRemove = true }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Color(nsColor: .systemRed))
                    .disabled(runtime.busy)
            }
        }
        .padding(.top, 2)
    }

    private func detailLabel(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(.secondary).gridColumnAlignment(.leading).frame(width: 90, alignment: .leading)
    }

    private func detailValue(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(.primary.opacity(0.85))
    }
}
