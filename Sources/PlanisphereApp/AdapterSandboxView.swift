import SwiftUI
import AppKit

struct AdapterSandboxView: View {
    @Bindable var model: AdapterSandboxModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Adapters").font(.largeTitle.bold())
                Text("Try an integration or a served model with your own test input.").foregroundStyle(.secondary)
                Picker("Adapter type", selection: $model.kind) {
                    ForEach(AdapterSandboxModel.Kind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).disabled(model.busy)
                Group {
                    if model.kind == .integration { integration } else { models }
                }.disabled(model.busy)
                HStack {
                    if model.busy { ProgressView().controlSize(.small); Button("Cancel", action: model.cancel) }
                    Text(model.status).font(.headline)
                    Spacer()
                    Button("Save Result…", action: save).disabled(model.busy || model.result.isEmpty)
                }
                Text(model.result).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
                    .padding(12).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                Text("Inputs, tokens and results stay in app memory unless you save a result. Tests do not install hooks or change your support settings.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(24).frame(maxWidth: 1000, alignment: .leading).frame(maxWidth: .infinity)
        }
    }

    private var integration: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Integration sandbox").font(.title2.bold())
            Text("Executable tests run for up to 15 seconds in a disposable folder. Network access and home/vault contents are denied. Only system runtimes and the chosen executable are readable; adapters needing other files may fail.")
                .foregroundStyle(.secondary)
            HStack {
                TextField("Executable path", text: $model.executable)
                Button("Choose…", action: chooseExecutable)
            }
            TextField("Arguments as a JSON array", text: $model.arguments).font(.system(.body, design: .monospaced))
            Text("Standard input / event JSON").font(.headline)
            TextEditor(text: $model.input).font(.system(.body, design: .monospaced)).frame(height: 150).border(.quaternary)
            HStack {
                Button("Run Executable") { model.run("execute") }.buttonStyle(.borderedProminent)
                Spacer()
                Picker("Event host", selection: $model.host) { Text("Codex").tag("codex"); Text("Claude Code").tag("claude") }.frame(width: 190)
                Button("Check Envelope") { model.run("fixture") }
            }
            Text("Check Envelope validates basic JSON fields only; it does not execute a hook or certify host compatibility.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var models: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("LoRA and fine-tuned models").font(.title2.bold())
            Text("Serve your model or LoRA with an OpenAI-compatible runtime, then choose its exact model ID. The server manages weights and may load them on demand or forward requests. A loopback address does not prove inference stays on this Mac.")
                .foregroundStyle(.secondary)
            TextField("Loopback server URL", text: $model.endpoint)
            SecureField("Optional server token (kept in memory)", text: $model.token)
            HStack {
                Button("Refresh Models") { model.run("models") }
                Picker("Model / adapter ID", selection: $model.selectedModel) {
                    Text("Choose a served model").tag("")
                    ForEach(model.models, id: \.self) { Text($0).tag($0) }
                }.disabled(!model.inventoryCurrent)
            }
            Text("Test prompt").font(.headline)
            TextEditor(text: $model.prompt).font(.system(.body, design: .monospaced)).frame(height: 150).border(.quaternary)
            HStack {
                Stepper("Maximum output: \(model.maxTokens) tokens", value: $model.maxTokens, in: 1...2048)
                Spacer()
                Button("Send Test Prompt") { model.run("model") }.buttonStyle(.borderedProminent)
                    .disabled(model.selectedModel.isEmpty || !model.inventoryCurrent || model.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Text("This sends your prompt to the displayed server. No training or adapter weight installation occurs. Server-reported usage may be unavailable.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func chooseExecutable() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.message = "Choose the executable adapter to test in an isolated folder."
        if panel.runModal() == .OK, let url = panel.url { model.executable = url.path }
    }
    private func save() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "adapter-test.txt"
        if panel.runModal() == .OK, let url = panel.url {
            do { try model.result.write(to: url, atomically: true, encoding: .utf8) }
            catch { NSAlert(error: error).runModal() }
        }
    }
}
