import AppKit
import SwiftUI
import PlanisphereGraph
import PlanisphereGrapheine

enum GraphPalette {
    static func group(_ folder: String) -> String { folder.split(separator: "/").first.map(String.init) ?? "" }
    static func color(for folder: String) -> NSColor {
        let colors: [NSColor] = [
            .init(srgbRed: 0.40, green: 0.70, blue: 1.00, alpha: 1),
            .init(srgbRed: 0.39, green: 0.83, blue: 0.70, alpha: 1),
            .init(srgbRed: 0.77, green: 0.62, blue: 0.97, alpha: 1),
            .init(srgbRed: 0.97, green: 0.70, blue: 0.43, alpha: 1),
            .init(srgbRed: 0.95, green: 0.53, blue: 0.66, alpha: 1),
            .init(srgbRed: 0.58, green: 0.81, blue: 0.92, alpha: 1),
            .init(srgbRed: 0.77, green: 0.82, blue: 0.43, alpha: 1)
        ]
        var hash: UInt64 = 14695981039346656037
        for byte in group(folder).utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        return colors[Int(hash % UInt64(colors.count))]
    }
}

struct VaultGraphCanvas: NSViewRepresentable {
    let snapshot: GraphSnapshot
    let revision: UUID
    let selectedID: String?
    let query: String
    let neighborhood: Bool
    let showIsolates: Bool
    let paused: Bool
    let spacing: Double
    let pinned: Set<String>
    let fitRequest: Int
    let focusRequest: Int
    let arrangeRequest: Int
    var onSelect: (String?) -> Void
    var onOpen: () -> Void
    var onMoving: (Bool) -> Void

    func makeNSView(context: Context) -> GraphDrawingView { GraphDrawingView() }
    func updateNSView(_ view: GraphDrawingView, context: Context) { view.configure(self) }
    static func dismantleNSView(_ view: GraphDrawingView, coordinator: ()) { view.stop() }
}

@MainActor final class GraphDrawingView: NSView {
    private var simulation: GraphSimulation?
    private var nodes: [GraphNode] = []
    private var links: [GraphLink] = []
    private var indexByID: [String: Int] = [:]
    private var adjacency: [Set<Int>] = []
    private var colors: [NSColor] = []
    private var selected: Int?
    private var hovered: Int?
    private var visible: [Bool] = []
    private var matches: Set<Int> = []
    private var labelOrder: [Int] = []
    private var pinnedIDs: Set<String> = []
    private var snapshotKey = ""
    private var search = ""
    private var neighborhood = false
    private var showIsolates = true
    private var paused = false
    private var fitRequest = 0
    private var focusRequest = 0
    private var arrangeRequest = 0
    private var timer: Timer?
    private var tracking: NSTrackingArea?
    private var scale: Double = 1
    private var offset = CGPoint.zero
    private var initialFit = true
    private var userMovedCamera = false
    private var frames = 0
    private var dragging: Int?
    private var mouseStart = CGPoint.zero
    private var panStart = CGPoint.zero
    private var dragOffset = CGPoint.zero
    private var didDrag = false
    private var lastMoving = false
    private var onSelect: ((String?) -> Void)?
    private var onOpen: (() -> Void)?
    private var onMoving: ((Bool) -> Void)?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Vault graph")
        setAccessibilityHelp("Search or use the note list to select a note. Drag notes to move them, drag the background to pan, and scroll to zoom. Arrow keys pan, plus and minus zoom, and zero fits the graph.")
        NotificationCenter.default.addObserver(self, selector: #selector(visibilityChanged), name: NSWindow.didChangeOcclusionStateNotification, object: nil)
    }
    required init?(coder: NSCoder) { nil }

    func configure(_ input: VaultGraphCanvas) {
        onSelect = input.onSelect
        onOpen = input.onOpen
        onMoving = input.onMoving
        let key = input.snapshot.vaultPath + "|" + input.revision.uuidString
        if key != snapshotKey {
            stop()
            let oldPositions = Dictionary(uniqueKeysWithValues: nodes.enumerated().compactMap { index, node -> (String, GraphPoint)? in
                guard let simulation, simulation.positions.indices.contains(index) else { return nil }
                return (node.id, simulation.positions[index])
            })
            snapshotKey = key
            hovered = nil
            dragging = nil
            nodes = input.snapshot.nodes
            indexByID = Dictionary(uniqueKeysWithValues: nodes.enumerated().map { ($0.element.id, $0.offset) })
            links = input.snapshot.edges.compactMap { edge in
                guard let a = indexByID[edge.source], let b = indexByID[edge.target] else { return nil }
                return GraphLink(source: a, target: b)
            }
            adjacency = Array(repeating: [], count: nodes.count)
            for edge in links { adjacency[edge.source].insert(edge.target); adjacency[edge.target].insert(edge.source) }
            colors = nodes.map { GraphPalette.color(for: $0.folder) }
            labelOrder = nodes.indices.sorted { a, b in
                let left = nodes[a], right = nodes[b]
                if left.degree == right.degree { return left.id < right.id }
                return left.degree > right.degree
            }
            let folders = Array(Set(nodes.map { GraphPalette.group($0.folder) })).sorted()
            let folderIDs = Dictionary(uniqueKeysWithValues: folders.enumerated().map { ($0.element, $0.offset) })
            simulation = GraphSimulation(nodeCount: nodes.count, links: links,
                groups: nodes.map { folderIDs[GraphPalette.group($0.folder)] ?? 0 })
            var restored: [Int: GraphPoint] = [:]
            for (i, node) in nodes.enumerated() {
                if let point = oldPositions[node.id] { restored[i] = point }
            }
            simulation?.restorePositions(restored)
            frames = 0
            if oldPositions.isEmpty { initialFit = true; userMovedCamera = false }
            pinnedIDs = []
            setAccessibilityValue("\(nodes.count) notes, \(links.count) links")
        }
        let nextSelected = input.selectedID.flatMap { indexByID[$0] }
        let refit = neighborhood != input.neighborhood || showIsolates != input.showIsolates || (input.neighborhood && nextSelected != selected)
        selected = nextSelected
        search = input.query.trimmingCharacters(in: .whitespacesAndNewlines)
        neighborhood = input.neighborhood
        showIsolates = input.showIsolates
        paused = input.paused
        if simulation?.spacing != input.spacing { simulation?.spacing = input.spacing }
        if pinnedIDs != input.pinned {
            for id in pinnedIDs.symmetricDifference(input.pinned) {
                if let i = indexByID[id] { simulation?.setPinned(index: i, input.pinned.contains(id)) }
            }
            pinnedIDs = input.pinned
        }
        visible = nodes.indices.map { i in
            (showIsolates || nodes[i].degree > 0 || selected == i) &&
                (!neighborhood || selected == nil || selected == i || adjacency[selected!].contains(i))
        }
        matches = search.isEmpty ? [] : Set(nodes.indices.filter { nodes[$0].id.localizedCaseInsensitiveContains(search) })
        if refit { userMovedCamera = true; fit() }
        if arrangeRequest != input.arrangeRequest {
            arrangeRequest = input.arrangeRequest
            simulation?.reset()
            simulation?.spacing = input.spacing
            initialFit = true; userMovedCamera = false; frames = 0
        }
        if fitRequest != input.fitRequest {
            fitRequest = input.fitRequest
            userMovedCamera = true
            fit()
        }
        if focusRequest != input.focusRequest {
            focusRequest = input.focusRequest
            if let selected, let point = simulation?.positions[selected] {
                userMovedCamera = true
                if neighborhood { fit() }
                else {
                    scale = max(scale, 1.1)
                    offset = CGPoint(x: bounds.midX - point.x * scale, y: bounds.midY - point.y * scale)
                }
            }
        }
        needsDisplay = true
        runIfNeeded()
    }

    override func layout() {
        super.layout()
        if initialFit, bounds.width > 20, bounds.height > 20, !nodes.isEmpty { fit(); initialFit = false }
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); runIfNeeded() }
    @objc private func visibilityChanged() { runIfNeeded() }

    func stop() {
        timer?.invalidate(); timer = nil
        reportMoving(false)
    }
    private func runIfNeeded() {
        guard window != nil, window?.occlusionState.contains(.visible) == true, !paused,
              let simulation, !simulation.isSettled, !nodes.isEmpty else { stop(); return }
        guard timer == nil else { return }
        let timer = Timer(timeInterval: nodes.count > 2000 ? 1.0 / 30 : 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        reportMoving(true)
    }
    private func tick() {
        guard !paused, window?.occlusionState.contains(.visible) == true else { stop(); return }
        simulation?.step()
        frames += 1
        if !userMovedCamera && frames <= 120 && frames % 10 == 0 { fit(smooth: true) }
        needsDisplay = true
        if simulation?.isSettled == true { stop() }
    }
    private func reportMoving(_ moving: Bool) {
        guard moving != lastMoving else { return }
        lastMoving = moving
        // Defer observable state publication outside updateNSView/drawing.
        Task { @MainActor [weak self] in self?.onMoving?(moving) }
    }

    private func fit(smooth: Bool = false) {
        guard let simulation, bounds.width > 10, bounds.height > 10 else { return }
        let points = simulation.positions.enumerated().filter { visible.indices.contains($0.offset) && visible[$0.offset] }.map(\.element)
        guard let first = points.first else { return }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in points { minX = min(minX, p.x); maxX = max(maxX, p.x); minY = min(minY, p.y); maxY = max(maxY, p.y) }
        let nextScale = min(1.7, max(0.025, min(max(40, bounds.width - 110) / max(120, maxX - minX), max(40, bounds.height - 110) / max(120, maxY - minY))))
        let nextOffset = CGPoint(x: bounds.midX - (minX + maxX) * 0.5 * nextScale, y: bounds.midY - (minY + maxY) * 0.5 * nextScale)
        let blend = smooth ? 0.24 : 1
        scale += (nextScale - scale) * blend
        offset.x += (nextOffset.x - offset.x) * blend
        offset.y += (nextOffset.y - offset.y) * blend
        needsDisplay = true
    }
    private func screen(_ p: GraphPoint) -> CGPoint { CGPoint(x: p.x * scale + offset.x, y: p.y * scale + offset.y) }
    private func world(_ p: CGPoint) -> GraphPoint { GraphPoint(x: (p.x - offset.x) / scale, y: (p.y - offset.y) / scale) }
    private func radius(_ i: Int) -> Double { max(2.2, min(17, (3.3 + sqrt(Double(nodes[i].degree)) * 0.65) * sqrt(scale))) }

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let background = dark ? NSColor(srgbRed: 0.055, green: 0.065, blue: 0.09, alpha: 1) : NSColor(srgbRed: 0.955, green: 0.965, blue: 0.985, alpha: 1)
        background.setFill(); bounds.fill()
        guard let context = NSGraphicsContext.current?.cgContext, let simulation else { return }
        let points = simulation.positions.map(screen)
        let foreground = dark ? NSColor.white : NSColor.black
        // A quiet, viewport-fixed field makes panning legible without more graph edges.
        context.setFillColor(foreground.withAlphaComponent(0.055).cgColor)
        for x in stride(from: 24.0, to: bounds.width, by: 32) {
            for y in stride(from: 24.0, to: bounds.height, by: 32) { context.fillEllipse(in: CGRect(x: x, y: y, width: 1, height: 1)) }
        }
        let ordinary = CGMutablePath(), emphasized = CGMutablePath()
        let focus = selected ?? hovered
        for edge in links where visible[edge.source] && visible[edge.target] {
            let a = points[edge.source], b = points[edge.target]
            guard min(a.x, b.x) <= bounds.maxX, max(a.x, b.x) >= 0,
                  min(a.y, b.y) <= bounds.maxY, max(a.y, b.y) >= 0 else { continue }
            let path = focus == edge.source || focus == edge.target ? emphasized : ordinary
            path.move(to: a); path.addLine(to: b)
        }
        context.addPath(ordinary)
        context.setStrokeColor(foreground.withAlphaComponent(focus == nil && search.isEmpty ? (dark ? 0.14 : 0.12) : 0.04).cgColor)
        context.setLineWidth(0.65); context.strokePath()
        context.addPath(emphasized)
        context.setStrokeColor(NSColor(srgbRed: 0.50, green: 0.70, blue: 1, alpha: dark ? 0.72 : 0.75).cgColor)
        context.setLineWidth(1.25); context.strokePath()
        for i in nodes.indices where visible[i] {
            let point = points[i], r = radius(i)
            guard bounds.insetBy(dx: -30, dy: -30).contains(point) else { continue }
            let nearby = focus == nil || focus == i || adjacency[focus!].contains(i)
            let found = search.isEmpty || matches.contains(i)
            let active = i == selected || i == hovered
            let alpha = active ? 1.0 : nearby && found ? 0.90 : 0.18
            let color = dark ? colors[i] : colors[i].blended(withFraction: 0.22, of: .black) ?? colors[i]
            if active {
                context.setFillColor(color.withAlphaComponent(0.12).cgColor)
                context.fillEllipse(in: CGRect(x: point.x - r - 9, y: point.y - r - 9, width: 2 * r + 18, height: 2 * r + 18))
            }
            context.setFillColor(color.withAlphaComponent(alpha).cgColor)
            context.fillEllipse(in: CGRect(x: point.x - r, y: point.y - r, width: 2 * r, height: 2 * r))
            if active || pinnedIDs.contains(nodes[i].id) {
                context.setStrokeColor(foreground.withAlphaComponent(active ? 0.95 : 0.6).cgColor)
                context.setLineWidth(active ? 1.5 : 1)
                context.strokeEllipse(in: CGRect(x: point.x - r - 2.5, y: point.y - r - 2.5, width: 2 * r + 5, height: 2 * r + 5))
            }
        }
        var occupied: [CGRect] = []
        var candidates: [Int] = []
        if let selected { candidates.append(selected) }
        if let hovered, hovered != selected { candidates.append(hovered) }
        if !search.isEmpty { candidates += labelOrder.filter { matches.contains($0) }.prefix(70) }
        else if let focus { candidates += labelOrder.filter { adjacency[focus].contains($0) }.prefix(35) }
        else { candidates += labelOrder.prefix(scale > 0.65 ? 35 : 12) }
        var labeled = Set<Int>()
        for i in candidates where visible[i] && labeled.insert(i).inserted {
            let point = points[i]
            guard bounds.insetBy(dx: 5, dy: 5).contains(point) else { continue }
            let prominent = i == selected || i == hovered
            let font = NSFont.systemFont(ofSize: prominent ? 12 : 10, weight: prominent ? .semibold : .medium)
            let title = nodes[i].title.count > 37 ? String(nodes[i].title.prefix(35)) + "…" : nodes[i].title
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: foreground.withAlphaComponent(prominent ? 1 : 0.72)]
            let size = (title as NSString).size(withAttributes: attributes)
            let rect = CGRect(x: point.x + radius(i) + 7, y: point.y - size.height / 2, width: size.width, height: size.height)
            guard prominent || !occupied.contains(where: { $0.intersects(rect.insetBy(dx: -4, dy: -3)) }) else { continue }
            occupied.append(rect)
            background.withAlphaComponent(0.88).setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: -3, dy: -2), xRadius: 3, yRadius: 3).fill()
            (title as NSString).draw(in: rect, withAttributes: attributes)
        }
        if nodes.isEmpty || !visible.contains(true) {
            let text = nodes.isEmpty ? "No Markdown notes in this scope" : "No connected notes to show"
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 16, weight: .medium), .foregroundColor: NSColor.secondaryLabelColor]
            let size = (text as NSString).size(withAttributes: attributes)
            (text as NSString).draw(at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY), withAttributes: attributes)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    private func hit(_ point: CGPoint) -> Int? {
        guard let simulation else { return nil }
        var best: Int?, distance = Double.infinity
        for i in nodes.indices where visible[i] {
            let p = screen(simulation.positions[i])
            let d = hypot(p.x - point.x, p.y - point.y)
            if d < max(8, radius(i) + 4), d < distance { best = i; distance = d }
        }
        return best
    }
    override func mouseMoved(with event: NSEvent) {
        let next = hit(convert(event.locationInWindow, from: nil))
        if next != hovered { hovered = next; needsDisplay = true; next == nil ? NSCursor.openHand.set() : NSCursor.pointingHand.set() }
    }
    override func mouseExited(with event: NSEvent) { hovered = nil; needsDisplay = true; NSCursor.arrow.set() }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        mouseStart = convert(event.locationInWindow, from: nil)
        panStart = offset
        dragging = hit(mouseStart)
        didDrag = false
        if let dragging, let p = simulation?.positions[dragging] {
            let start = world(mouseStart)
            dragOffset = CGPoint(x: p.x - start.x, y: p.y - start.y)
            onSelect?(nodes[dragging].id)
            if event.clickCount == 2 { onOpen?() }
        }
        NSCursor.closedHand.set()
    }
    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if hypot(point.x - mouseStart.x, point.y - mouseStart.y) > 2 { didDrag = true }
        guard didDrag else { return }
        userMovedCamera = true
        if let dragging {
            let p = world(point)
            simulation?.drag(index: dragging, to: GraphPoint(x: p.x + dragOffset.x, y: p.y + dragOffset.y))
            runIfNeeded()
        } else {
            offset = CGPoint(x: panStart.x + point.x - mouseStart.x, y: panStart.y + point.y - mouseStart.y)
        }
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        if let dragging {
            if didDrag {
                simulation?.release(index: dragging, pin: pinnedIDs.contains(nodes[dragging].id))
                runIfNeeded()
            }
        } else if !didDrag { onSelect?(nil) }
        dragging = nil
        NSCursor.openHand.set()
    }
    private func zoom(_ multiplier: Double, at point: CGPoint) {
        let anchor = world(point)
        scale = max(0.025, min(5, scale * multiplier))
        offset = CGPoint(x: point.x - anchor.x * scale, y: point.y - anchor.y * scale)
        userMovedCamera = true
        needsDisplay = true
    }
    override func scrollWheel(with event: NSEvent) {
        let amount = max(-0.28, min(0.28, event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.008 : 0.075)))
        zoom(exp(amount), at: convert(event.locationInWindow, from: nil))
    }
    override func magnify(with event: NSEvent) { zoom(exp(event.magnification), at: convert(event.locationInWindow, from: nil)) }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123: offset.x += 35
        case 124: offset.x -= 35
        case 125: offset.y -= 35
        case 126: offset.y += 35
        case 53: onSelect?(nil)
        default:
            switch event.charactersIgnoringModifiers {
            case "+", "=": zoom(1.2, at: CGPoint(x: bounds.midX, y: bounds.midY))
            case "-": zoom(1 / 1.2, at: CGPoint(x: bounds.midX, y: bounds.midY))
            case "0": fit()
            default: super.keyDown(with: event); return
            }
        }
        userMovedCamera = true
        needsDisplay = true
    }
}
