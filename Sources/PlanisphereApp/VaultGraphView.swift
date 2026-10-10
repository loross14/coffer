import AppKit
import SwiftUI
import Observation
import PlanisphereCore
import PlanisphereGrapheine

@MainActor @Observable
final class VaultGraphModel {
    var snapshot: GraphSnapshot?
    var revision = UUID()
    var loading = false
    var error: String?
    var selectedID: String?
    var noteText: String?
    var noteError: String?
    var readingNote = false
    var query = ""
    var neighborhood = false
    var showIsolates = true
    var paused = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    var moving = false
    var spacing = 1.0
    var pinned: Set<String> = []
    var fitRequest = 0
    var focusRequest = 0
    var arrangeRequest = 0
    private let service = GrapheineService()
    private var requestID = UUID()
    private var noteTask: Task<Void, Never>?

    var selected: GraphNode? { snapshot?.nodes.first { $0.id == selectedID } }
    var matches: [GraphNode] {
        guard let snapshot else { return [] }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return snapshot.nodes.filter { q.isEmpty || $0.id.localizedCaseInsensitiveContains(q) }
            .sorted { $0.degree == $1.degree ? $0.id < $1.id : $0.degree > $1.degree }
    }
    var neighbors: [GraphNode] {
        guard let snapshot, let selectedID else { return [] }
        var ids = Set<String>()
        for edge in snapshot.edges {
            if edge.source == selectedID { ids.insert(edge.target) }
            if edge.target == selectedID { ids.insert(edge.source) }
        }
        return snapshot.nodes.filter { ids.contains($0.id) }.sorted { $0.id < $1.id }
    }
    var visibleCounts: (notes: Int, links: Int) {
        guard let snapshot else { return (0, 0) }
        let nearby = Set(neighbors.map(\.id))
        let ids = Set(snapshot.nodes.filter {
            (showIsolates || $0.degree > 0 || $0.id == selectedID) &&
            (!neighborhood || selectedID == nil || $0.id == selectedID || nearby.contains($0.id))
        }.map(\.id))
        return (ids.count, snapshot.edges.filter { ids.contains($0.source) && ids.contains($0.target) }.count)
    }

    func load(vault: VaultRecord) async {
        let request = UUID()
        requestID = request
        loading = true
        error = nil
        do {
            let result = try await service.graph(vaultURL: vault.url)
            guard !Task.isCancelled, requestID == request else { return }
            snapshot = result
            revision = UUID()
            pinned.formIntersection(Set(result.nodes.map(\.id)))
            if let selectedID { select(result.nodes.contains(where: { $0.id == selectedID }) ? selectedID : nil, vault: vault) }
            loading = false
        } catch {
            guard requestID == request else { return }
            loading = false
            if !Task.isCancelled { self.error = error.localizedDescription }
        }
    }

    func select(_ id: String?, vault: VaultRecord) {
        selectedID = id
        noteTask?.cancel()
        noteText = nil
        noteError = nil
        readingNote = false
        guard let id else { neighborhood = false; return }
        readingNote = true
        noteTask = Task {
            do {
                let text = try await service.readNote(vaultURL: vault.url, path: id)
                guard !Task.isCancelled, selectedID == id else { return }
                noteText = text.map { String($0.prefix(12_000)) }
                if text == nil { noteError = "This note is too large or is not readable text. Open it in your editor." }
                else if (text?.count ?? 0) > 12_000 { noteError = "Showing the first 12,000 characters." }
            } catch {
                guard !Task.isCancelled, selectedID == id else { return }
                noteError = error.localizedDescription
            }
            readingNote = false
        }
    }

    func stop() { noteTask?.cancel() }

    func openNote(vault: VaultRecord) {
        guard let id = selectedID else { return }
        let url = vault.url.appendingPathComponent(id)
        if !NSWorkspace.shared.open(url) { noteError = "No editor opened this note. Use Show in Finder to choose one." }
    }
}

struct VaultGraphView: View {
    let vault: VaultRecord
    @State private var graph = VaultGraphModel()
    @State private var refreshTask: Task<Void, Never>?
    @State private var scopePresented = false
    @State private var settingsPresented = false
    @State private var inspectorPresented = false
    @FocusState private var searchFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            PSStyle.canvas
            if let snapshot = graph.snapshot {
                HStack(spacing: 0) {
                    graphSurface(snapshot)
                        .frame(minWidth: 260, maxWidth: .infinity, maxHeight: .infinity)
                    if inspectorPresented {
                        inspector(snapshot)
                            .frame(width: 286)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
            } else if graph.loading {
                VStack(spacing: 14) {
                    ProgressView().controlSize(.small)
                    Text("Connecting your notes").font(.system(size: 18, weight: .semibold))
                    Text("Reading the links in your local Markdown.")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView {
                    Label("Your vault, connected", systemImage: "point.3.connected.trianglepath.dotted")
                } description: {
                    Text(graph.error ?? "Explore the links between your Markdown notes.")
                } actions: {
                    Button("Load graph") { refresh() }.buttonStyle(PSButtonStyle(primary: true))
                }
            }
        }
        .clipped()
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: inspectorPresented)
        .background {
            Button("Find a note in the graph") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command).hidden().accessibilityHidden(true)
        }
        .onChange(of: graph.query) { _, query in
            if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { inspectorPresented = true }
            else if graph.selectedID == nil { inspectorPresented = false }
        }
        .task { if graph.snapshot == nil { await graph.load(vault: vault) } }
        .onDisappear { refreshTask?.cancel(); graph.stop() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)) { _ in
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { graph.paused = true }
        }
    }

    private func graphSurface(_ snapshot: GraphSnapshot) -> some View {
        GeometryReader { geometry in
            VaultGraphCanvas(snapshot: snapshot, revision: graph.revision, selectedID: graph.selectedID, query: graph.query,
                neighborhood: graph.neighborhood, showIsolates: graph.showIsolates,
                paused: graph.paused, spacing: graph.spacing, pinned: graph.pinned,
                fitRequest: graph.fitRequest, focusRequest: graph.focusRequest,
                arrangeRequest: graph.arrangeRequest,
                onSelect: { id in
                    graph.select(id, vault: vault)
                    if id != nil { inspectorPresented = true }
                },
                onOpen: { graph.openNote(vault: vault) },
                onMoving: { graph.moving = $0 })
                .clipped()
                .overlay(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: 10) {
                        searchControl(snapshot)
                            .frame(width: min(280, max(150, geometry.size.width - 90)))
                        if let error = graph.error {
                            VStack(alignment: .leading, spacing: 5) {
                                Label("Showing the earlier snapshot", systemImage: "exclamationmark.circle")
                                    .font(.system(size: 12, weight: .medium))
                                Text("Refresh failed. \(error)").font(.system(size: 11)).foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                            .padding(12).frame(width: min(350, max(150, geometry.size.width - 36)), alignment: .leading)
                            .background(PSStyle.surface, in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(PSStyle.border))
                        }
                    }.padding(18)
                }
                .overlay(alignment: .topTrailing) {
                    PSIconButton(symbol: "sidebar.right", help: inspectorPresented ? "Hide graph details" : "Show graph details") {
                        inspectorPresented.toggle()
                    }
                    .accessibilityLabel(inspectorPresented ? "Hide graph details" : "Show graph details")
                    .accessibilityIdentifier("graph-inspector-toggle")
                    .padding(4).background(PSStyle.surface, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(PSStyle.border))
                    .padding(18)
                }
                .overlay(alignment: .bottom) { actionDock(snapshot).padding(.bottom, 20) }
                .overlay(alignment: .bottomLeading) {
                    if geometry.size.width > 540 {
                        HStack(spacing: 6) {
                            Circle().fill(graph.moving && !graph.paused ? PSStyle.accent : Color.secondary.opacity(0.5))
                                .frame(width: 4, height: 4)
                            Text(graph.paused ? "Paused" : graph.moving ? "Finding balance" : "At rest")
                                .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                        }
                        .padding(.leading, 20).padding(.bottom, 33).allowsHitTesting(false)
                    }
                }
        }.clipped()
    }

    private func searchControl(_ snapshot: GraphSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                TextField("Find a note", text: $graph.query)
                    .font(.system(size: 13)).textFieldStyle(.plain).focused($searchFocused)
                    .accessibilityIdentifier("graph-search")
                    .onExitCommand {
                        searchFocused = false
                        if !graph.query.isEmpty { graph.query = "" }
                        else { inspectorPresented = false }
                    }
                if !graph.query.isEmpty {
                    Button { graph.query = ""; searchFocused = true } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }.buttonStyle(.plain).accessibilityLabel("Clear graph search")
                } else {
                    Text("⌘F").font(.system(size: 10, weight: .medium)).foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }
            HStack(spacing: 5) {
                if graph.loading { ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 10, height: 10) }
                Text(graph.loading ? "Refreshing…" : "\(graph.visibleCounts.notes.formatted()) notes · \(graph.visibleCounts.links.formatted()) links")
                if graph.neighborhood { Text("· Neighborhood") }
            }.font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.horizontal, 13).padding(.vertical, 11)
        .background(PSStyle.surface.opacity(0.97), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(PSStyle.border))
        .shadow(color: .black.opacity(0.035), radius: 12, x: 0, y: 4)
    }

    private func actionDock(_ snapshot: GraphSnapshot) -> some View {
        HStack(spacing: 3) {
            PSIconButton(symbol: "arrow.up.left.and.arrow.down.right", help: "Fit visible notes") { graph.fitRequest += 1 }
                .accessibilityIdentifier("graph-fit")
            PSIconButton(symbol: graph.paused ? "play.fill" : "pause.fill", help: graph.paused ? "Resume motion" : "Pause motion") { graph.paused.toggle() }
                .accessibilityIdentifier("graph-pause")
            PSIconButton(symbol: "arrow.clockwise", help: "Refresh graph") { refresh() }
                .disabled(graph.loading).accessibilityIdentifier("graph-refresh")
            Rectangle().fill(PSStyle.border).frame(width: 1, height: 18).padding(.horizontal, 5)
            PSIconButton(symbol: "slider.horizontal.3", help: "Graph settings") { settingsPresented.toggle() }
                .accessibilityIdentifier("graph-settings")
                .popover(isPresented: $settingsPresented, arrowEdge: .bottom) { graphSettings }
            PSIconButton(symbol: "info.circle", help: "Snapshot and scope") { scopePresented.toggle() }
                .popover(isPresented: $scopePresented, arrowEdge: .bottom) { scopeDetails(snapshot) }
        }
        .padding(6)
        .background(PSStyle.surface.opacity(0.98), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(PSStyle.border))
        .shadow(color: .black.opacity(0.07), radius: 16, x: 0, y: 5)
    }

    private var graphSettings: some View {
        VStack(alignment: .leading, spacing: 17) {
            Text("Graph settings").font(.system(size: 15, weight: .semibold))
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Selected note’s neighborhood", isOn: $graph.neighborhood)
                    .disabled(graph.selectedID == nil)
                    .help("Show the selected note and its direct connections")
                Toggle("Include unlinked notes", isOn: $graph.showIsolates)
            }.toggleStyle(.switch).controlSize(.small)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Spacing")
                    Spacer()
                    Text("\(graph.spacing, specifier: "%.1f")×").monospacedDigit().foregroundStyle(.secondary)
                }
                Slider(value: $graph.spacing, in: 0.6...2.0).accessibilityLabel("Graph spacing")
            }
            if let node = graph.selected {
                Toggle("Pin selected note", isOn: Binding(get: { graph.pinned.contains(node.id) }, set: {
                    if $0 { graph.pinned.insert(node.id) } else { graph.pinned.remove(node.id) }
                })).toggleStyle(.switch).controlSize(.small)
            }
            HStack {
                Text("\(graph.pinned.count) pinned").foregroundStyle(.secondary)
                Spacer()
                Button("Release all") { graph.pinned.removeAll() }
                    .buttonStyle(.link).disabled(graph.pinned.isEmpty)
            }
            Divider()
            Button("Arrange again", systemImage: "arrow.triangle.2.circlepath") {
                graph.pinned.removeAll(); graph.arrangeRequest += 1; settingsPresented = false
            }.buttonStyle(PSButtonStyle())
                .help("Reset the layout and release all pinned positions")
            Text("Folders guide the layout. Connections come from the links in your notes.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.font(.system(size: 12)).padding(20).frame(width: 290)
    }

    private func inspector(_ snapshot: GraphSnapshot) -> some View {
        VStack(spacing: 0) {
            HStack {
                PSSectionLabel(title: graph.selected == nil ? "Explore" : "Note details")
                Spacer()
                PSIconButton(symbol: "xmark", help: "Hide graph details") { inspectorPresented = false }
                    .accessibilityIdentifier("graph-inspector-close")
            }.padding(.leading, 20).padding(.trailing, 12).padding(.vertical, 12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if !graph.query.isEmpty {
                        VStack(alignment: .leading, spacing: 7) {
                            HStack {
                                PSSectionLabel(title: "Search results")
                                Spacer()
                                Text(graph.matches.count.formatted()).font(.system(size: 11)).foregroundStyle(.secondary)
                            }.padding(.bottom, 3)
                            ForEach(graph.matches.prefix(60)) { node in noteButton(node) }
                            if graph.matches.isEmpty { Text("No notes match this search.").font(.system(size: 12)).foregroundStyle(.secondary) }
                            if graph.matches.count > 60 { Text("Refine your search for more results.").font(.system(size: 11)).foregroundStyle(.secondary) }
                        }
                        if graph.selected != nil { Divider() }
                    }
                    if let node = graph.selected {
                        VStack(alignment: .leading, spacing: 9) {
                            HStack(alignment: .top, spacing: 8) {
                                Circle().fill(Color(nsColor: GraphPalette.color(for: node.folder)))
                                    .frame(width: 7, height: 7).padding(.top, 6)
                                Text(node.title).font(.system(size: 18, weight: .semibold)).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            Text(node.id).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            Text("\(node.inDegree) incoming · \(node.outDegree) outgoing\(graph.pinned.contains(node.id) ? " · Pinned" : "")")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        HStack(spacing: 7) {
                            Button("Open note", systemImage: "arrow.up.forward.app") { graph.openNote(vault: vault) }
                                .buttonStyle(PSButtonStyle(primary: true)).accessibilityIdentifier("graph-open-note")
                            PSIconButton(symbol: "scope", help: "Center selected note") { graph.focusRequest += 1 }
                        }
                        if graph.readingNote { ProgressView().controlSize(.small) }
                        if let text = graph.noteText {
                            VStack(alignment: .leading, spacing: 9) {
                                PSSectionLabel(title: "Preview")
                                ScrollView {
                                    Text(text).font(.system(size: 12)).lineSpacing(4).textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(12)
                                }
                                .frame(height: 220)
                                .background(PSStyle.canvas, in: RoundedRectangle(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(PSStyle.border))
                            }
                        }
                        if let error = graph.noteError { Text(error).font(.system(size: 11)).foregroundStyle(.secondary) }
                        HStack {
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([vault.url.appendingPathComponent(node.id)]) }
                                .buttonStyle(.link)
                            Spacer()
                            Button("Clear selection") { graph.select(nil, vault: vault) }.buttonStyle(.link)
                        }.font(.system(size: 11))
                        Divider()
                        VStack(alignment: .leading, spacing: 7) {
                            PSSectionLabel(title: "Connected notes · \(graph.neighbors.count)").padding(.bottom, 3)
                            ForEach(graph.neighbors.prefix(80)) { neighbor in noteButton(neighbor) }
                            if graph.neighbors.isEmpty { Text("No resolved connections in this snapshot.").font(.system(size: 12)).foregroundStyle(.secondary) }
                        }
                    } else if graph.query.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Follow a thread.").font(.system(size: 18, weight: .semibold))
                            Text("Choose a note to read it and explore its connections.")
                                .font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(3)
                        }
                        VStack(alignment: .leading, spacing: 7) {
                            PSSectionLabel(title: "Well connected").padding(.bottom, 3)
                            ForEach(graph.matches.prefix(8)) { node in noteButton(node) }
                        }
                        Divider()
                        VStack(alignment: .leading, spacing: 12) {
                            PSSectionLabel(title: "Folders")
                            ForEach(folderCounts(snapshot).prefix(12), id: \.0) { folder, count in
                                HStack(spacing: 8) {
                                    Circle().fill(Color(nsColor: GraphPalette.color(for: folder))).frame(width: 7, height: 7)
                                    Text(folder.isEmpty ? "Vault root" : folder).lineLimit(1)
                                    Spacer()
                                    Text(count.formatted()).foregroundStyle(.secondary)
                                }.font(.system(size: 12))
                            }
                        }
                    }
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(PSStyle.surface)
        .overlay(alignment: .leading) { Rectangle().fill(PSStyle.border).frame(width: 1) }
    }

    private func noteButton(_ node: GraphNode) -> some View {
        GraphInspectorNoteRow(node: node, selected: graph.selectedID == node.id) {
            graph.select(node.id, vault: vault); graph.focusRequest += 1; inspectorPresented = true
        }
    }

    private func folderCounts(_ snapshot: GraphSnapshot) -> [(String, Int)] {
        Dictionary(grouping: snapshot.nodes, by: { GraphPalette.group($0.folder) })
            .map { ($0.key, $0.value.count) }.sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }
    }

    private func scopeDetails(_ snapshot: GraphSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Your graph snapshot").font(.system(size: 15, weight: .semibold))
            Text("\(snapshot.nodes.count.formatted()) notes · Scanned \(snapshot.scannedAt)").foregroundStyle(.secondary)
            Text("Refresh to include edits made in your editor. Colors and starting positions follow folders; size follows connections. Layout distance is for exploration, not a measure of meaning.")
            Divider()
            Text("\(snapshot.unresolvedLinkCount) unresolved · \(snapshot.ambiguousLinkCount) ambiguous · \(snapshot.unsupportedLinkCount) unsupported references")
            Text("\(snapshot.scope.excludedCount.formatted()) excluded locations · \(snapshot.omittedNodeCount.formatted()) notes and \(snapshot.omittedEdgeCount.formatted()) links beyond display limits")
            ForEach(snapshot.limits + snapshot.scope.limitations + snapshot.scope.unsupportedFilters, id: \.self) { Text($0) }
            Text("The graph reads local notes. It does not change links or upload your vault.").foregroundStyle(.secondary)
        }.font(.system(size: 12)).padding(20).frame(width: 350)
    }

    private func refresh() {
        refreshTask?.cancel()
        refreshTask = Task { await graph.load(vault: vault) }
    }
}

private struct GraphInspectorNoteRow: View {
    let node: GraphNode
    let selected: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 8) {
                Circle().fill(Color(nsColor: GraphPalette.color(for: node.folder))).frame(width: 6, height: 6).padding(.top, 5)
                VStack(alignment: .leading, spacing: 3) {
                    Text(node.title).font(.system(size: 12, weight: .medium)).lineLimit(2)
                    Text(node.id).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8).padding(.vertical, 7)
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .background(selected ? PSStyle.accent.opacity(0.10) : hovered ? Color.primary.opacity(0.035) : .clear, in: RoundedRectangle(cornerRadius: 7))
        .onHover { hovered = $0 }
        .accessibilityLabel("Select \(node.id)")
    }
}
