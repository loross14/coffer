import AppKit
import SwiftUI
import SwiftTerm

struct TerminalWorkspaceView: View {
    @Bindable var store: TerminalWorkspaceModel
    let initialDirectory: URL?
    @State private var closing: TerminalSession?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Terminal").font(.title2.weight(.semibold))
                    Text("Local shell · commands run with your Mac account’s permissions")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Choose Folder…", systemImage: "folder") { chooseFolder() }
                Button("New Terminal", systemImage: "plus") {
                    store.open(directory: initialDirectory ?? FileManager.default.homeDirectoryForCurrentUser)
                }.disabled(store.sessions.count >= 8)
                .accessibilityIdentifier("terminal-new")
            }.padding(22)
            Divider()
            if store.sessions.isEmpty {
                ContentUnavailableView {
                    Label("A shell alongside your work", systemImage: "terminal")
                } description: {
                    Text("Open a terminal in your selected vault, choose another folder, or start in your home folder. Sessions stay open while you use other sections.")
                } actions: {
                    Button("Open Terminal") { store.open(directory: initialDirectory ?? FileManager.default.homeDirectoryForCurrentUser) }
                }
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(store.sessions) { session in
                            HStack(spacing: 8) {
                                Button { store.selectedID = session.id } label: {
                                    Label(session.title.isEmpty ? "Shell" : session.title,
                                          systemImage: session.ended ? "checkmark.circle" : "terminal")
                                        .lineLimit(1).frame(maxWidth: 180)
                                }.buttonStyle(.plain)
                                Button {
                                    if session.ended { store.close(session) } else { closing = session }
                                } label: { Image(systemName: "xmark").font(.caption) }
                                    .buttonStyle(.plain).accessibilityLabel("Close \(session.title)")
                            }.padding(10)
                                .background(store.selectedID == session.id ? PSStyle.accent.opacity(0.12) : Color.clear,
                                            in: RoundedRectangle(cornerRadius: 7))
                        }
                    }.padding(8)
                }.fixedSize(horizontal: false, vertical: true)
                Divider()
                if let session = store.selected {
                    HStack {
                        Text("Opened in \(session.initialDirectory.path)").lineLimit(1).truncationMode(.middle)
                        Spacer()
                        if session.ended { Text(session.exitCode.map { "Exited (\($0))" } ?? "Session ended") }
                    }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.vertical, 8)
                    NativeTerminal(session: session).id(session.id)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }.background(PSStyle.canvas)
            .confirmationDialog("Close this terminal?", isPresented: Binding(get: { closing != nil }, set: { if !$0 { closing = nil } })) {
                Button("Close Terminal", role: .destructive) { if let closing { store.close(closing) }; closing = nil }
                Button("Cancel", role: .cancel) { closing = nil }
            } message: { Text("Commands still running in this session may be interrupted.") }
            .alert("Terminal needs attention", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
                Button("OK") { store.error = nil }
            } message: { Text(store.error ?? "") }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.prompt = "Open Terminal"
        panel.directoryURL = initialDirectory
        if panel.runModal() == .OK, let url = panel.url { store.open(directory: url) }
    }
}

private struct NativeTerminal: NSViewRepresentable {
    let session: TerminalSession
    func makeNSView(context: Context) -> LocalProcessTerminalView {
        session.view.removeFromSuperview()
        DispatchQueue.main.async { session.view.window?.makeFirstResponder(session.view) }
        return session.view
    }
    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {}
    // Sessions belong to the model, not this transient navigation view.
    static func dismantleNSView(_ nsView: LocalProcessTerminalView, coordinator: ()) {}
}
