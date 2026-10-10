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

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if let snapshot = graph.snapshot {
                HStack(spacing: 0) {
                    ZStack(alignment: .bottomLeading) {
                        VaultGraphCanvas(snapshot: snapshot, revision: graph.revision, selectedID: graph.selectedID, query: graph.query,
                            neighborhood: graph.neighborhood, showIsolates: graph.showIsolates,
                            paused: graph.paused, spacing: graph.spacing, pinned: graph.pinned,
                            fitRequest: graph.fitRequest, focusRequest: graph.focusRequest,
                            arrangeRequest: graph.arrangeRequest,
                            onSelect: { graph.select($0, vault: vault) },
                            onOpen: { graph.openNote(vault: vault) },
                            onMoving: { graph.moving = $0 })
                            .clipped()
                        HStack(spacing: 7) {
                            Circle().fill(graph.paused ? Color.secondary : graph.moving ? Color.mint : Color.blue).frame(width: 5, height: 5)
                            Text(graph.paused ? "Motion paused" : graph.moving ? "Finding balance" : "At rest")
                            Text("·  Drag to move  ·  Scroll to zoom").foregroundStyle(.secondary)
                        }
                        .font(.system(size: 10, weight: .medium)).padding(.horizontal, 12).padding(.vertical, 9)
                        .background(.regularMaterial, in: Capsule()).padding(16)
                        .allowsHitTesting(false)
                    }
                    .frame(minWidth: 260, maxWidth: .infinity, maxHeight: .infinity)
                    Divider()
                    inspector(snapshot).frame(width: 262)
                }
                .frame(minHeight: 0, maxHeight: .infinity)
                Divider()
                HStack(spacing: 10) {
                    Text("\(graph.visibleCounts.notes.formatted()) of \(snapshot.nodes.count.formatted()) notes · \(graph.visibleCounts.links.formatted()) links")
                    if graph.neighborhood { Text("· Neighborhood").foregroundStyle(.secondary) }
                    Spacer()
                    Button("Snapshot & scope", systemImage: "info.circle") { scopePresented = true }
                        .buttonStyle(.link)
                        .popover(isPresented: $scopePresented) { scopeDetails(snapshot) }
                }
                .font(.caption).padding(.horizontal, 18).padding(.vertical, 10)
            } else if graph.loading {
                VStack(spacing: 15) {
                    ProgressView()
                    Text("Connecting your notes…").font(.headline)
                    Text("Reading the links in your local Markdown.").font(.callout).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView {
                    Label("Your vault, connected", systemImage: "point.3.connected.trianglepath.dotted")
                } description: {
                    Text(graph.error ?? "Explore the links between your Markdown notes.")
                } actions: {
                    Button("Load Graph") { refresh() }.buttonStyle(.borderedProminent)
                }
            }
            if let error = graph.error, graph.snapshot != nil {
                Text("Refresh failed. Showing the earlier snapshot. \(error)")
                    .font(.caption).foregroundStyle(.orange).textSelection(.enabled).padding(10)
            }
        }
        .task { if graph.snapshot == nil { await graph.load(vault: vault) } }
        .onDisappear { refreshTask?.cancel(); graph.stop() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)) { _ in
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { graph.paused = true }
        }
    }

    private var toolbar: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Find a note…", text: $graph.query)
                        .textFieldStyle(.plain).accessibilityIdentifier("graph-search")
                    if !graph.query.isEmpty {
                        Button { graph.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).accessibilityLabel("Clear graph search")
                    }
                }
                .padding(8).background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 7))
                .frame(maxWidth: 310)
                Spacer(minLength: 0)
                Button("Fit", systemImage: "arrow.up.left.and.arrow.down.right") { graph.fitRequest += 1 }
                    .help("Fit visible notes without changing their layout").accessibilityIdentifier("graph-fit")
                Button(graph.paused ? "Resume" : "Pause", systemImage: graph.paused ? "play.fill" : "pause.fill") { graph.paused.toggle() }
                    .accessibilityIdentifier("graph-pause")
                Button { refresh() } label: {
                    if graph.loading { ProgressView().controlSize(.small) }
                    else { Image(systemName: "arrow.clockwise") }
                }
                .disabled(graph.loading).help("Refresh the graph from this vault")
                .accessibilityLabel("Refresh graph").accessibilityIdentifier("graph-refresh")
            }
            HStack(spacing: 14) {
                Toggle("Neighborhood", isOn: $graph.neighborhood).toggleStyle(.checkbox)
                    .disabled(graph.selectedID == nil).help("Show the selected note and its direct connections")
                Toggle("Unlinked notes", isOn: $graph.showIsolates).toggleStyle(.checkbox)
                Spacer(minLength: 0)
                Text("Spacing").foregroundStyle(.secondary)
                Slider(value: $graph.spacing, in: 0.6...2.0).frame(width: 100)
                    .accessibilityLabel("Graph spacing")
                Menu {
                    Button("Arrange Again") { graph.pinned.removeAll(); graph.arrangeRequest += 1 }
                    Button("Release All Pins") { graph.pinned.removeAll() }.disabled(graph.pinned.isEmpty)
                } label: { Image(systemName: "slider.horizontal.3") }
                .menuStyle(.borderlessButton).frame(width: 24).help("Layout controls")
            }.font(.caption)
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
    }

    @ViewBuilder private func inspector(_ snapshot: GraphSnapshot) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if !graph.query.isEmpty {
                    Text("\(graph.matches.count) MATCHES").font(.system(size: 10, weight: .semibold)).tracking(1).foregroundStyle(.secondary)
                    ForEach(graph.matches.prefix(60)) { node in noteButton(node) }
                    if graph.matches.count > 60 { Text("Refine your search to see more results.").font(.caption).foregroundStyle(.secondary) }
                    if graph.selected != nil { Divider() }
                }
                if let node = graph.selected {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("SELECTED NOTE").font(.system(size: 10, weight: .semibold)).tracking(1).foregroundStyle(.secondary)
                            Spacer()
                            Button { graph.select(nil, vault: vault) } label: { Image(systemName: "xmark") }
                                .buttonStyle(.plain).help("Clear selection").accessibilityLabel("Clear graph selection")
                        }
                        Text(node.title).font(.title3.weight(.semibold)).textSelection(.enabled)
                        Text(node.id).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        Text("\(node.inDegree) incoming · \(node.outDegree) outgoing").font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        Button("Open Note", systemImage: "arrow.up.forward.app") { graph.openNote(vault: vault) }
                            .accessibilityIdentifier("graph-open-note")
                        Button { graph.focusRequest += 1 } label: { Image(systemName: "scope") }
                            .help("Center on this note").accessibilityLabel("Center selected note")
                    }
                    Toggle("Pin position", isOn: Binding(get: { graph.pinned.contains(node.id) }, set: { if $0 { graph.pinned.insert(node.id) } else { graph.pinned.remove(node.id) } }))
                        .toggleStyle(.checkbox).font(.caption)
                    if graph.readingNote { ProgressView().controlSize(.small) }
                    if let text = graph.noteText {
                        Text(text).font(.system(size: 11)).lineSpacing(3).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                            .frame(maxHeight: 220, alignment: .top).clipped()
                    }
                    if let error = graph.noteError { Text(error).font(.caption).foregroundStyle(.secondary) }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([vault.url.appendingPathComponent(node.id)]) }
                        .buttonStyle(.link).font(.caption)
                    Divider()
                    Text("CONNECTED NOTES · \(graph.neighbors.count)").font(.system(size: 10, weight: .semibold)).tracking(0.7).foregroundStyle(.secondary)
                    ForEach(graph.neighbors.prefix(80)) { neighbor in noteButton(neighbor) }
                    if graph.neighbors.isEmpty { Text("No resolved connections in this snapshot.").font(.caption).foregroundStyle(.secondary) }
                } else if graph.query.isEmpty {
                    Image(systemName: "point.3.connected.trianglepath.dotted").font(.system(size: 28, weight: .light)).foregroundStyle(.secondary)
                    Text("Follow a thread.").font(.title3.weight(.semibold))
                    Text("Select a note to read it and explore its connections. Drag to make room; pin a note to keep it in place.")
                        .font(.callout).foregroundStyle(.secondary).lineSpacing(3)
                    Divider()
                    Text("WELL CONNECTED").font(.system(size: 10, weight: .semibold)).tracking(1).foregroundStyle(.secondary)
                    ForEach(graph.matches.prefix(8)) { node in noteButton(node) }
                    Divider()
                    Text("FOLDERS").font(.system(size: 10, weight: .semibold)).tracking(1).foregroundStyle(.secondary)
                    ForEach(folderCounts(snapshot).prefix(12), id: \.0) { folder, count in
                        HStack(spacing: 8) {
                            Circle().fill(Color(nsColor: GraphPalette.color(for: folder))).frame(width: 7, height: 7)
                            Text(folder.isEmpty ? "Vault root" : folder).lineLimit(1)
                            Spacer()
                            Text(count.formatted()).foregroundStyle(.tertiary)
                        }.font(.caption)
                    }
                }
            }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.25))
    }

    private func noteButton(_ node: GraphNode) -> some View {
        Button { graph.select(node.id, vault: vault); graph.focusRequest += 1 } label: {
            HStack(alignment: .top, spacing: 9) {
                Circle().fill(Color(nsColor: GraphPalette.color(for: node.folder))).frame(width: 6, height: 6).padding(.top, 5)
                VStack(alignment: .leading, spacing: 3) {
                    Text(node.title).font(.system(size: 12, weight: .medium)).lineLimit(2)
                    Text(node.id).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }.contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel("Select \(node.id)")
    }

    private func folderCounts(_ snapshot: GraphSnapshot) -> [(String, Int)] {
        Dictionary(grouping: snapshot.nodes, by: { GraphPalette.group($0.folder) })
            .map { ($0.key, $0.value.count) }.sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }
    }

    private func scopeDetails(_ snapshot: GraphSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("A snapshot of your Markdown links").font(.headline)
            Text("Scanned \(snapshot.scannedAt)").font(.caption).foregroundStyle(.secondary)
            Text("Refresh to include edits made in your editor. Colors and starting positions follow folders; size follows connections. Layout distance is for exploration, not a measure of meaning.")
            Text("\(snapshot.unresolvedLinkCount) unresolved · \(snapshot.ambiguousLinkCount) ambiguous · \(snapshot.unsupportedLinkCount) unsupported references")
            Text("\(snapshot.scope.excludedCount.formatted()) excluded locations · \(snapshot.omittedNodeCount.formatted()) notes and \(snapshot.omittedEdgeCount.formatted()) links beyond display limits")
            ForEach(snapshot.limits + snapshot.scope.limitations + snapshot.scope.unsupportedFilters, id: \.self) { Text($0) }
            Text("The graph reads local notes. It does not change links or upload your vault.").foregroundStyle(.secondary)
        }.font(.caption).padding(20).frame(width: 360)
    }

    private func refresh() {
        refreshTask?.cancel()
        refreshTask = Task { await graph.load(vault: vault) }
    }
}
