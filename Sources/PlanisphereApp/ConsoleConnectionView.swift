import SwiftUI
import PlanisphereConnection

struct ConsoleConnectionView: View {
    @Bindable var connection: ConsoleConnectionModel
    @State private var confirmSwitch = false
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
                    if let email = identity.email, !email.isEmpty {
                        Text(email).foregroundStyle(.secondary)
                    }
                    Label(connection.verified ? "Connected" : connection.needsSignIn ? "Reconnect needed" : connection.busy ? "Checking connection…" : "Connection not checked",
                          systemImage: connection.verified ? "checkmark.circle" : "exclamationmark.circle")
                }
                Text(connection.verified ? "Your account is connected. Vault files, checkpoints and policies stay on this Mac." :
                     connection.needsSignIn ? "Sign in again to reconnect this Mac to your account. Your local vaults are ready to use." :
                     connection.busy ? "Checking your saved account connection…" :
                     "Your saved account could not be checked. Try again when you are online. Your local vaults are ready to use.")
            } else {
                Text("Connect this Mac to your Planisphere workspace. Sign in and choose your workspace in the browser, then return here.")
                Text("This first step connects your account. Your vaults and checkpoint history stay on your Mac.").foregroundStyle(.secondary)
            }
            if let message = connection.message {
                Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    .accessibilityIdentifier("console-connection-message")
            }
            if connection.busy { ProgressView("Working…").controlSize(.small) }
            VStack(alignment: .leading, spacing: 12) {
              HStack(spacing: 12) {
                if connection.credential == nil {
                    Button("Connect to Console") { Task { await connection.connect() } }.buttonStyle(PSButtonStyle(primary: true)).disabled(connection.busy)
                } else {
                    if connection.verified && !Set(connection.credential?.connection.permissions ?? []).isSuperset(of: ["prompts:read", "hooks:read"]) {
                        Button("Enable Activity Access…") { confirmSwitch = true }.buttonStyle(PSButtonStyle(primary: true)).disabled(connection.busy)
                    }
                    if connection.needsSignIn {
                        Button("Sign in Again") { Task { await connection.reconnect() } }
                            .buttonStyle(PSButtonStyle(primary: true)).disabled(connection.busy)
                    } else {
                        Button("Check Connection") { Task { await connection.refresh() } }.buttonStyle(PSButtonStyle()).disabled(connection.busy)
                    }
                }
                if connection.canCancelSignIn { Button("Cancel Sign-in") { connection.cancel() } }
                Spacer()
              }
              HStack(spacing: 12) {
                if connection.credential != nil {
                    Button("Switch Workspace…") { confirmSwitch = true }.buttonStyle(PSButtonStyle()).disabled(connection.busy)
                    Button("Disconnect") { Task { await connection.disconnect() } }.buttonStyle(PSButtonStyle()).disabled(connection.busy)
                }
                Spacer()
                Link("Open Console", destination: ConsoleClient.production.appendingPathComponent("console"))
              }
            }
            Text("You can keep using local vaults without a console connection.").font(.caption).foregroundStyle(.secondary)
        }
        .padding(28).frame(width: 660).background(PSStyle.canvas)
        .interactiveDismissDisabled(connection.busy)
        .task { await connection.load() }
        .confirmationDialog("Switch workspace?", isPresented: $confirmSwitch) {
            Button("Disconnect and Choose Workspace") { Task { await connection.switchWorkspace() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The current connection will be disconnected before you choose a workspace in the browser. Local vaults and history stay on this Mac.")
        }
    }
}
