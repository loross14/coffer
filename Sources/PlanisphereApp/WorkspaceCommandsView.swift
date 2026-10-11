import SwiftUI

/// An in-window launcher: navigation is quick; consequential work opens its normal review.
struct WorkspaceCommandsView: View {
    @Bindable var model: VaultAppModel
    @State private var query = ""
    @State private var selection = 0
    @FocusState private var searchFocused: Bool

    private struct Command: Identifiable {
        let id: String
        let title: String
        let detail: String
        let symbol: String
        let shortcut: String
        let action: () -> Void
    }

    private var commands: [Command] {
        var result: [Command] = []
        if model.selectedVault != nil {
            for (index, surface) in VaultSurface.allCases.enumerated() {
                result.append(Command(id: surface.rawValue, title: "Open \(surface.rawValue)",
                    detail: surface.subtitle, symbol: surface.symbol, shortcut: "⌘\(index + 1)",
                    action: { model.selectedSurface = surface }))
            }
            if model.historyReadError == nil {
                result.append(Command(id: "checkpoint", title: "Create checkpoint", detail: "Review what to save",
                    symbol: "plus.circle", shortcut: "⌘S", action: { model.createCheckpoint() }))
            }
            result.append(Command(id: "finder", title: "Open vault in Finder", detail: model.selectedVault?.name ?? "",
                symbol: "folder", shortcut: "", action: { model.openSelectedVault() }))

        }
        for (index, surface) in ActivitySurface.allCases.enumerated() {
            result.append(Command(id: surface.rawValue, title: "Open \(surface.rawValue)",
                detail: "Local and workspace activity", symbol: surface.symbol, shortcut: "⌘\(index + 4)",
                action: { model.activitySurface = surface }))
        }
        for vault in model.vaults {
            result.append(Command(id: vault.id.uuidString, title: vault.name, detail: vault.path,
                symbol: "folder", shortcut: "", action: { model.selectVault(vault.id) }))
        }
        result.append(Command(id: "add", title: "Add existing vault…", detail: "Choose a folder on your Mac",
            symbol: "folder.badge.plus", shortcut: "⌘O", action: { model.chooseExistingVault() }))
        result.append(Command(id: "new", title: "Create new vault…", detail: "Start with an empty folder",
            symbol: "plus.square", shortcut: "⌘N", action: { model.chooseNewVault() }))
        result.append(Command(id: "sidebar", title: model.sidebarVisible ? "Hide sidebar" : "Show sidebar",
            detail: "Make room for your work", symbol: "sidebar.left", shortcut: "⌘\\",
            action: { model.sidebarVisible.toggle() }))
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.filter { trimmed.isEmpty || ($0.title + " " + $0.detail).localizedCaseInsensitiveContains(trimmed) }
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.25).ignoresSafeArea()
                .onTapGesture { model.commandPalettePresented = false }
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass").font(.system(size: 18, weight: .regular)).foregroundStyle(.secondary)
                    TextField("Where do you want to go?", text: $query)
                        .textFieldStyle(.plain).font(.system(size: 16))
                        .focused($searchFocused).onSubmit { activateSelection() }
                        .onKeyPress(.downArrow) { move(1); return .handled }
                        .onKeyPress(.upArrow) { move(-1); return .handled }
                        .onKeyPress(.escape) { model.commandPalettePresented = false; return .handled }
                        .accessibilityIdentifier("workspace-command-search")
                    Button("esc") { model.commandPalettePresented = false }
                        .keyboardShortcut(.cancelAction)
                        .buttonStyle(.plain).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                        .padding(5).background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 4))
                        .accessibilityLabel("Close command launcher")
                }.padding(20)
                Divider()
                ScrollViewReader { scroll in
                    ScrollView {
                        LazyVStack(spacing: 3) {
                            if commands.isEmpty {
                                Text("No matching commands or vaults").font(.callout).foregroundStyle(.secondary).padding(32)
                            }
                            ForEach(Array(commands.enumerated()), id: \.element.id) { index, command in
                                Button { activate(command) } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: command.symbol).font(.system(size: 15)).frame(width: 22).foregroundStyle(.secondary)
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(command.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                            Text(command.detail).font(.system(size: 11)).foregroundStyle(.secondary)
                                                .lineLimit(1).truncationMode(.middle)
                                        }
                                        Spacer()
                                        Text(command.shortcut).font(.system(size: 11)).foregroundStyle(.secondary)
                                    }
                                    .padding(.horizontal, 12).padding(.vertical, 10)
                                    .background(selection == index ? PSStyle.accent.opacity(0.12) : Color.clear,
                                                in: RoundedRectangle(cornerRadius: 8))
                                    .contentShape(Rectangle())
                                }.buttonStyle(.plain).id(index)
                                .help(command.detail)
                                .accessibilityAddTraits(selection == index ? .isSelected : [])
                            }
                        }.padding(8)
                    }.frame(maxHeight: 350)
                    .onChange(of: selection) { _, value in scroll.scrollTo(value) }
                }
                Divider()
                HStack(spacing: 14) {
                    Text("↑ ↓ to move"); Text("↵ to open")
                    Spacer(); Text("Planisphere")
                }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 18).padding(.vertical, 11)
            }
            .background(PSStyle.surface, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(PSStyle.border))
            .shadow(color: .black.opacity(0.2), radius: 30, y: 14)
            .frame(width: 540).padding(.top, 68)
        }
        .onAppear {
            // The field must join the window before it can become first responder.
            DispatchQueue.main.async { searchFocused = true }
        }
        .onChange(of: query) { _, _ in selection = 0 }
        .accessibilityIdentifier("workspace-command-launcher")
    }

    private func move(_ offset: Int) { selection = min(max(0, selection + offset), max(0, commands.count - 1)) }
    private func activateSelection() {
        guard commands.indices.contains(selection) else { return }
        activate(commands[selection])
    }
    private func activate(_ command: Command) {
        guard model.canNavigateWorkspace else { return }
        model.commandPalettePresented = false
        // Remove the overlay before another action presents its own sheet or native panel.
        DispatchQueue.main.async { command.action() }
    }
}
