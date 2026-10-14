import SwiftUI

struct LocalSupportCard: View {
    @Bindable var model: LocalSupportModel
    @State private var configuring = false

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            Image(systemName: "cpu").font(.title2).foregroundStyle(PSStyle.accent)
            VStack(alignment: .leading, spacing: 6) {
                Text("Local support").font(.callout.weight(.semibold))
                Text(model.status?.enabled == true
                     ? (model.status?.mode == "observe" ? "Preparing in the background. Evidence delivery is unchanged." : "Prepared evidence can be reused when its sources still match.")
                     : "Let a model on this Mac help prepare evidence for your connected agents.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("Preview · Savings have not yet been measured.").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(model.status?.enabled == true ? "Manage" : "Set up") { configuring = true }
                .buttonStyle(PSButtonStyle())
        }
        .padding(20).background(PSStyle.surface, in: RoundedRectangle(cornerRadius: 14))
        .task { await model.refresh(inventory: false) }
        .sheet(isPresented: $configuring) {
            VStack(alignment: .leading, spacing: 18) {
                Text("Local support").font(.title2.weight(.semibold))
                Text("Planisphere's own model prepares source selections in the background, on this Mac. Your agent still evaluates the evidence.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let status = model.status {
                    Label(status.enabled
                          ? (status.mode == "observe" ? "Observation mode · delivery unchanged" : "Prepared evidence enabled")
                          : "Support is paused",
                          systemImage: status.enabled ? "checkmark.circle" : "pause.circle")
                        .font(.callout.weight(.medium)).foregroundStyle(PSStyle.accent)
                    ModelRuntimeSection(runtime: model.runtime) { await model.refresh() }
                    if status.retrieval_connections == 0 {
                        Text("Connect memory to Codex first. No existing vault is required.")
                            .font(.callout).foregroundStyle(.secondary)
                    } else {
                        Text("\(status.linked_connections) of \(status.retrieval_connections) agent connections linked.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        Button("Observe first") { Task { await model.configure("observe") } }
                        Button("Use prepared evidence") { Task { await model.configure("optimize") } }
                    }.disabled(model.selectedModel.isEmpty || status.retrieval_connections == 0 || model.busy)
                    if status.enabled {
                        Button("Pause support") { Task { await model.configure("off") } }.disabled(model.busy)
                    }
                }
                if model.busy { ProgressView().controlSize(.small) }
                if let message = model.message { Text(message).font(.callout).textSelection(.enabled) }
                Text("Connection updates preserve disabled hooks and require Codex’s normal review. No frontier API calls are made by this support worker.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack { Spacer(); Button("Done") { configuring = false }.keyboardShortcut(.defaultAction) }
            }.padding(28).frame(width: 570).task { await model.refresh() }
        }
    }
}
