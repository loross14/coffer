import SwiftUI
import PlanisphereConnection

struct ConsoleConnectionView: View {
    @Bindable var connection: ConsoleConnectionModel
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("Console connection", systemImage: "network").font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { connection.presented = false }.disabled(connection.busy)
            }
            if let identity = connection.credential?.connection {
                VStack(alignment: .leading, spacing: 6) {
                    Text(identity.workspace.name).font(.headline)
                    Text(identity.email).foregroundStyle(.secondary)
                    Label(connection.verified ? "Connected" : connection.needsSignIn ? "Reconnect needed" : "Connection not checked",
                          systemImage: connection.verified ? "checkmark.circle" : "exclamationmark.circle")
                }
                Text("Your account is connected. Vault files, checkpoints and policies are not synced yet.")
            } else {
                Text("Connect this Mac to your Planisphere workspace. Sign in and choose your workspace in the browser, then return here.")
                Text("This first step connects your account. Your vaults and checkpoint history stay on your Mac.").foregroundStyle(.secondary)
            }
            if let message = connection.message {
                Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    .accessibilityIdentifier("console-connection-message")
            }
            if connection.busy { ProgressView("Working…").controlSize(.small) }
            HStack(spacing: 12) {
                if connection.credential == nil {
                    Button("Connect to Console") { Task { await connection.connect() } }.buttonStyle(PSButtonStyle(primary: true)).disabled(connection.busy)
                } else {
                    Button("Check Connection") { Task { await connection.refresh() } }.buttonStyle(PSButtonStyle()).disabled(connection.busy)
                    Button("Disconnect") { Task { await connection.disconnect() } }.buttonStyle(PSButtonStyle()).disabled(connection.busy)
                }
                if connection.canCancelSignIn { Button("Cancel Sign-in") { connection.cancel() } }
                Spacer()
                Link("Open Console", destination: ConsoleClient.production.appendingPathComponent("console"))
            }
            Text("You can keep using local vaults without a console connection.").font(.caption).foregroundStyle(.secondary)
        }
        .padding(28).frame(width: 540).background(PSStyle.canvas)
        .interactiveDismissDisabled(connection.busy)
        .task { await connection.load() }
    }
}
