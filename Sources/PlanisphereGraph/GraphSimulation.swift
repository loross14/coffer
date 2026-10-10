import Foundation

public struct GraphPoint: Sendable, Equatable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

public struct GraphLink: Sendable, Hashable {
    public let source: Int
    public let target: Int
    public init(source: Int, target: Int) { self.source = source; self.target = target }
}

/// A deterministic fixed-frame layout. It performs no I/O and owns no timer.
/// Callers can step on a background task or a display timer, stopping when settled.
public struct GraphSimulation: Sendable {
    public private(set) var positions: [GraphPoint]
    public private(set) var radii: [Double]
    public private(set) var isSettled: Bool
    /// Mean squared velocity in layout points per fixed frame.
    public private(set) var energy: Double = 0

    /// Multiplier for the nominal 80-point link distance; supported range 0.6...2.
    public var spacing: Double {
        get { spacingValue }
        set {
            guard newValue.isFinite else { return }
            let value = min(2, max(0.6, newValue))
            if value != spacingValue { spacingValue = value; reheat() }
        }
    }
    /// Dimensionless many-body repulsion strength; supported range 0.2...3.
    public var repulsion: Double {
        get { repulsionValue }
        set {
            guard newValue.isFinite else { return }
            let value = min(3, max(0.2, newValue))
            if value != repulsionValue { repulsionValue = value; reheat() }
        }
    }

    private var spacingValue = 1.0
    private var repulsionValue = 1.0
    private let links: [GraphLink]
    private let neighbors: [[Int]]
    private let degrees: [Int]
    private let charges: [Double]
    private let initialPositions: [GraphPoint]
    private let componentCenters: [GraphPoint]
    private let folderGrouped: Bool
    private var velocities: [GraphPoint]
    private var heat: [Double]
    private var pinned: [Bool]
    private var dragging: [Bool]
    private var tree = QuadTree()
    private var calmFrames = 0
    private static let zero = GraphPoint(x: 0, y: 0)
    private static let coordinateLimit = 1_000_000.0

    /// `groups` optionally supplies visual folder IDs, not inferred relationships.
    /// A mismatched array is ignored; actual links alone define connectivity.
    public init(nodeCount: Int, links: [GraphLink], groups: [Int]? = nil) {
        let count = max(0, nodeCount)
        var unique: Set<GraphLink> = []
        for link in links where link.source >= 0 && link.target >= 0 && link.source < count && link.target < count && link.source != link.target {
            unique.insert(GraphLink(source: min(link.source, link.target), target: max(link.source, link.target)))
        }
        let cleanLinks = unique.sorted { $0.source == $1.source ? $0.target < $1.target : $0.source < $1.source }
        self.links = cleanLinks
        var adjacency = [[Int]](repeating: [], count: count)
        for link in cleanLinks {
            adjacency[link.source].append(link.target)
            adjacency[link.target].append(link.source)
        }
        for index in adjacency.indices { adjacency[index].sort() }
        neighbors = adjacency
        degrees = adjacency.map(\.count)
        charges = adjacency.map { 1 + min(3, sqrt(Double($0.count)) * 0.14) }
        radii = adjacency.map { 5.5 + min(8, sqrt(Double($0.count)) * 0.9) }
        let folderGroups = groups?.count == count ? groups : nil
        folderGrouped = folderGroups != nil
        let layout = Self.componentLayout(adjacency, groups: folderGroups)
        positions = layout.positions
        initialPositions = layout.positions
        componentCenters = layout.centers
        velocities = [GraphPoint](repeating: Self.zero, count: count)
        heat = [Double](repeating: 1, count: count)
        pinned = [Bool](repeating: false, count: count)
        dragging = [Bool](repeating: false, count: count)
        isSettled = count <= 1
    }

    public func isPinned(index: Int) -> Bool {
        positions.indices.contains(index) && pinned[index]
    }

    /// Drag holds this node exactly at the supplied point and wakes only its
    /// neighbors and nearby nodes. Nonfinite input is ignored; extreme input clamps.
    public mutating func drag(index: Int, to point: GraphPoint) {
        guard positions.indices.contains(index), point.x.isFinite, point.y.isFinite else { return }
        let target = Self.bounded(point)
        if dragging[index] && positions[index] == target { return }
        let previous = positions[index]
        positions[index] = target
        velocities[index] = Self.zero
        dragging[index] = true
        heat[index] = 0
        wakeNeighborhood(index: index, first: previous, second: target)
    }

    public mutating func release(index: Int, pin: Bool) {
        guard positions.indices.contains(index) else { return }
        dragging[index] = false
        pinned[index] = pin
        velocities[index] = Self.zero
        heat[index] = pin ? 0 : 0.8
        wakeNeighborhood(index: index, first: positions[index], second: positions[index])
    }

    public mutating func setPinned(index: Int, _ value: Bool) {
        guard positions.indices.contains(index), pinned[index] != value else { return }
        pinned[index] = value
        velocities[index] = Self.zero
        heat[index] = value ? 0 : 0.8
        wakeNeighborhood(index: index, first: positions[index], second: positions[index])
    }

    public mutating func reheat() {
        for index in heat.indices where !pinned[index] && !dragging[index] { heat[index] = 1 }
        isSettled = positions.isEmpty
        calmFrames = 0
    }

    /// Reuses a previous graph's coordinates in one linear pass on refresh.
    /// Existing pins remain unchanged; callers can restore pin choices separately.
    public mutating func restorePositions(_ points: [Int: GraphPoint]) {
        for (index, point) in points where positions.indices.contains(index) && point.x.isFinite && point.y.isFinite {
            positions[index] = Self.bounded(point)
            velocities[index] = Self.zero
            dragging[index] = false
        }
        reheat()
    }

    /// Restores the deterministic initial layout at the current spacing and clears pins.
    public mutating func reset() {
        positions = initialPositions.map { GraphPoint(x: $0.x * spacingValue, y: $0.y * spacingValue) }
        velocities = [GraphPoint](repeating: Self.zero, count: positions.count)
        pinned = [Bool](repeating: false, count: positions.count)
        dragging = pinned
        heat = [Double](repeating: 1, count: positions.count)
        energy = 0
        calmFrames = 0
        isSettled = positions.count <= 1
    }

    /// One fixed simulation frame, independent of wall-clock or display delays.
    public mutating func step() {
        guard !isSettled, !positions.isEmpty else { return }
        let length = 80 * spacingValue
        let previousPositions = positions
        tree.build(positions: positions, charges: charges)
        var forces = [GraphPoint](repeating: Self.zero, count: positions.count)
        var stack: [Int] = []
        stack.reserveCapacity(64)
        for index in positions.indices where movable(index) {
            forces[index] = tree.repulsiveForce(index: index, point: positions[index], charge: charges[index],
                                                strength: repulsionValue * length * length * 0.075, stack: &stack)
            let center = componentCenters[index]
            let gravity = degrees[index] == 0 ? 0.025 : folderGrouped ? 0.002 : 0.0012
            forces[index].x += (center.x * spacingValue - positions[index].x) * gravity
            forces[index].y += (center.y * spacingValue - positions[index].y) * gravity
        }
        for link in links {
            let a = link.source, b = link.target
            let dx = positions[b].x - positions[a].x, dy = positions[b].y - positions[a].y
            let distance = max(0.001, hypot(dx, dy))
            let degree = Double(max(degrees[a], degrees[b]))
            let desired = length * min(2.3, 1 + 0.18 * log2(degree + 1))
            let spring = 0.05 / pow(max(1, degree), 0.35)
            let scale = (distance - desired) * spring / distance
            if movable(a) { forces[a].x += dx * scale; forces[a].y += dy * scale }
            if movable(b) { forces[b].x -= dx * scale; forces[b].y -= dy * scale }
        }
        var maxHeat = 0.0
        for index in positions.indices {
            guard movable(index) else { velocities[index] = Self.zero; continue }
            let force = Self.limited(forces[index], magnitude: 2.8)
            var velocity = GraphPoint(x: (velocities[index].x + force.x * heat[index]) * 0.78,
                                      y: (velocities[index].y + force.y * heat[index]) * 0.78)
            velocity = Self.limited(velocity, magnitude: length * 0.18)
            positions[index] = Self.bounded(GraphPoint(x: positions[index].x + velocity.x, y: positions[index].y + velocity.y))
            velocities[index] = velocity
            heat[index] *= 0.982
            if heat[index] < 0.0004 { heat[index] = 0; velocities[index] = Self.zero }
            maxHeat = max(maxHeat, heat[index])
        }
        resolveCollisions()
        for index in positions.indices where movable(index) {
            let displacement = Self.limited(GraphPoint(x: positions[index].x - previousPositions[index].x,
                                                       y: positions[index].y - previousPositions[index].y), magnitude: length * 0.22)
            positions[index] = Self.bounded(GraphPoint(x: previousPositions[index].x + displacement.x,
                                                       y: previousPositions[index].y + displacement.y))
        }
        var total = 0.0, maxSpeed = 0.0
        for velocity in velocities {
            let square = velocity.x * velocity.x + velocity.y * velocity.y
            total += square
            maxSpeed = max(maxSpeed, sqrt(square))
        }
        energy = total / Double(positions.count)
        if maxHeat < 0.02 && maxSpeed < 0.035 { calmFrames += 1 } else { calmFrames = 0 }
        if maxHeat == 0 || calmFrames >= 12 {
            isSettled = true
            energy = 0
            for index in heat.indices { heat[index] = 0; velocities[index] = Self.zero }
        }
    }

    private func movable(_ index: Int) -> Bool { !pinned[index] && !dragging[index] && heat[index] > 0 }

    private mutating func wakeNeighborhood(index: Int, first: GraphPoint, second: GraphPoint) {
        let radius = 80 * spacingValue * (degrees[index] == 0 ? 1 : 2.5)
        let squared = radius * radius
        for node in positions.indices where !pinned[node] && !dragging[node] {
            let point = positions[node]
            let firstDistance = (point.x - first.x) * (point.x - first.x) + (point.y - first.y) * (point.y - first.y)
            let secondDistance = (point.x - second.x) * (point.x - second.x) + (point.y - second.y) * (point.y - second.y)
            if min(firstDistance, secondDistance) < squared { heat[node] = max(heat[node], 0.7) }
        }
        for node in neighbors[index] where !pinned[node] && !dragging[node] { heat[node] = max(heat[node], 0.85) }
        isSettled = false
        calmFrames = 0
    }

    private struct GridCell: Hashable { let x: Int; let y: Int }

    private mutating func resolveCollisions() {
        let cellSize = (radii.max() ?? 6) * 2 + 6
        var cells: [GridCell: [Int]] = [:]
        cells.reserveCapacity(positions.count)
        for index in positions.indices {
            let key = GridCell(x: Int(floor(positions[index].x / cellSize)), y: Int(floor(positions[index].y / cellSize)))
            cells[key, default: []].append(index)
        }
        for index in positions.indices {
            let key = GridCell(x: Int(floor(positions[index].x / cellSize)), y: Int(floor(positions[index].y / cellSize)))
            for y in -1...1 { for x in -1...1 {
                guard let bucket = cells[GridCell(x: key.x + x, y: key.y + y)] else { continue }
                // Bound pathological coincidence work; repulsion separates dense
                // buckets over subsequent frames instead of doing quadratic work.
                var lower = 0, upper = bucket.count
                while lower < upper {
                    let middle = (lower + upper) / 2
                    if bucket[middle] <= index { lower = middle + 1 } else { upper = middle }
                }
                for other in bucket[lower..<min(bucket.count, lower + 96)] {
                    let moveA = movable(index), moveB = movable(other)
                    if !moveA && !moveB { continue }
                    var dx = positions[other].x - positions[index].x, dy = positions[other].y - positions[index].y
                    var distance = hypot(dx, dy)
                    let minimum = radii[index] + radii[other] + 5
                    guard distance < minimum else { continue }
                    if distance < 0.001 {
                        let direction = Self.direction(index, other)
                        dx = direction.x; dy = direction.y; distance = 1
                    }
                    let correction = min(8, (minimum - distance) * 0.55)
                    let weightA = moveA ? 1 / sqrt(Double(degrees[index] + 1)) : 0
                    let weightB = moveB ? 1 / sqrt(Double(degrees[other] + 1)) : 0
                    let weight = weightA + weightB
                    if moveA {
                        positions[index].x -= dx / distance * correction * weightA / weight
                        positions[index].y -= dy / distance * correction * weightA / weight
                    }
                    if moveB {
                        positions[other].x += dx / distance * correction * weightB / weight
                        positions[other].y += dy / distance * correction * weightB / weight
                    }
                }
            } }
        }
    }

    private static func limited(_ point: GraphPoint, magnitude: Double) -> GraphPoint {
        guard point.x.isFinite, point.y.isFinite else { return zero }
        let length = hypot(point.x, point.y)
        if length > magnitude { return GraphPoint(x: point.x / length * magnitude, y: point.y / length * magnitude) }
        return point
    }

    private static func bounded(_ point: GraphPoint) -> GraphPoint {
        GraphPoint(x: min(coordinateLimit, max(-coordinateLimit, point.x)),
                   y: min(coordinateLimit, max(-coordinateLimit, point.y)))
    }

    fileprivate static func direction(_ first: Int, _ second: Int) -> GraphPoint {
        let seed = (UInt64(first) &* 0x9E3779B185EBCA87) ^ (UInt64(second) &* 0xC2B2AE3D27D4EB4F)
        let angle = Double(seed % 65_536) / 65_536 * 2 * Double.pi
        return GraphPoint(x: cos(angle), y: sin(angle))
    }

    private struct LayoutIsland {
        let nodes: [Int]
        let positions: [GraphPoint]
        let anchors: [GraphPoint]
        let size: GraphPoint
    }

    private static func packedCenters(_ sizes: [GraphPoint], gap: Double) -> (centers: [GraphPoint], size: GraphPoint) {
        let area = sizes.reduce(0) { $0 + ($1.x + gap) * ($1.y + gap) }
        let width = max(sizes.map(\.x).max() ?? 0, sqrt(area) * 1.15)
        var x = 0.0, y = 0.0, rowHeight = 0.0, maxX = 0.0
        var centers: [GraphPoint] = []
        for size in sizes {
            if x > 0 && x + size.x > width { x = 0; y += rowHeight + gap; rowHeight = 0 }
            centers.append(GraphPoint(x: x + size.x / 2, y: y + size.y / 2))
            x += size.x + gap; rowHeight = max(rowHeight, size.y); maxX = max(maxX, x - gap)
        }
        let size = GraphPoint(x: maxX, y: y + rowHeight)
        return (centers.map { GraphPoint(x: $0.x - size.x / 2, y: $0.y - size.y / 2) }, size)
    }

    private static func connectedIsland(_ nodes: [Int], groups: [Int]?) -> LayoutIsland {
        let disks: [[Int]]
        if let groups {
            var folders: [Int: [Int]] = [:]
            for node in nodes { folders[groups[node], default: []].append(node) }
            disks = folders.keys.sorted {
                folders[$0]!.count == folders[$1]!.count ? $0 < $1 : folders[$0]!.count > folders[$1]!.count
            }.map { folders[$0]! }
        } else { disks = [nodes] }
        let sizes = disks.map { nodes -> GraphPoint in
            let diameter = max(60, sqrt(Double(nodes.count)) * 58 + 44)
            return GraphPoint(x: diameter, y: diameter)
        }
        let packing = packedCenters(sizes, gap: 36)
        var orderedNodes: [Int] = [], points: [GraphPoint] = [], anchors: [GraphPoint] = []
        for (disk, members) in disks.enumerated() {
            let center = packing.centers[disk]
            for (order, node) in members.enumerated() {
                let radial = 27 * sqrt(Double(order))
                let angle = Double(order) * 2.399963229728653
                orderedNodes.append(node)
                points.append(GraphPoint(x: center.x + radial * cos(angle), y: center.y + radial * sin(angle)))
                anchors.append(center)
            }
        }
        return LayoutIsland(nodes: orderedNodes, positions: points, anchors: anchors, size: packing.size)
    }

    private static func isolatedIsland(_ nodes: [Int]) -> LayoutIsland {
        let points = nodes.indices.map { index -> GraphPoint in
            let radial = 12 * sqrt(Double(index)), angle = Double(index) * 2.399963229728653
            return GraphPoint(x: radial * cos(angle), y: radial * sin(angle))
        }
        let diameter = max(40, 24 * sqrt(Double(nodes.count)) + 36)
        // Isolates keep individual weak anchors in a compact island. They do not
        // gain links or a fabricated common semantic/group center.
        return LayoutIsland(nodes: nodes, positions: points, anchors: points, size: GraphPoint(x: diameter, y: diameter))
    }

    private static func componentLayout(_ neighbors: [[Int]], groups: [Int]?) -> (positions: [GraphPoint], centers: [GraphPoint]) {
        guard !neighbors.isEmpty else { return ([], []) }
        var seen = [Bool](repeating: false, count: neighbors.count), components: [[Int]] = []
        for start in neighbors.indices where !seen[start] {
            var queue = [start], cursor = 0
            seen[start] = true
            while cursor < queue.count {
                let node = queue[cursor]; cursor += 1
                for next in neighbors[node] where !seen[next] { seen[next] = true; queue.append(next) }
            }
            components.append(queue)
        }
        var islands = components.filter { $0.count > 1 }.map { connectedIsland($0, groups: groups) }
        let isolates = components.filter { $0.count == 1 }.map { $0[0] }.sorted()
        if !isolates.isEmpty { islands.append(isolatedIsland(isolates)) }
        islands.sort {
            let firstArea = $0.size.x * $0.size.y, secondArea = $1.size.x * $1.size.y
            return firstArea == secondArea ? $0.nodes[0] < $1.nodes[0] : firstArea > secondArea
        }
        let packing = packedCenters(islands.map(\.size), gap: 30)
        var positions = [GraphPoint](repeating: zero, count: neighbors.count), centers = positions
        for (index, island) in islands.enumerated() {
            let offset = packing.centers[index]
            for (order, node) in island.nodes.enumerated() {
                positions[node] = GraphPoint(x: island.positions[order].x + offset.x, y: island.positions[order].y + offset.y)
                centers[node] = GraphPoint(x: island.anchors[order].x + offset.x, y: island.anchors[order].y + offset.y)
            }
        }
        return (positions, centers)
    }
}

private struct QuadTree: Sendable {
    private struct Cell: Sendable {
        let x: Double, y: Double, half: Double
        var mass = 0.0, weightedX = 0.0, weightedY = 0.0
        var body = -1
        var children = -1 // Four contiguous child cells, or a leaf.
    }
    private var cells: [Cell] = []

    mutating func build(positions: [GraphPoint], charges: [Double]) {
        cells.removeAll(keepingCapacity: true)
        guard let first = positions.first else { return }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for point in positions { minX = min(minX, point.x); maxX = max(maxX, point.x); minY = min(minY, point.y); maxY = max(maxY, point.y) }
        cells.reserveCapacity(positions.count * 3)
        cells.append(Cell(x: (minX + maxX) / 2, y: (minY + maxY) / 2, half: max(1, max(maxX - minX, maxY - minY) / 2 + 1)))
        for index in positions.indices { insert(index, into: 0, depth: 0, positions: positions, charges: charges) }
    }

    private mutating func insert(_ index: Int, into cellIndex: Int, depth: Int, positions: [GraphPoint], charges: [Double]) {
        let point = positions[index], charge = charges[index]
        cells[cellIndex].mass += charge
        cells[cellIndex].weightedX += point.x * charge
        cells[cellIndex].weightedY += point.y * charge
        if cells[cellIndex].children < 0 {
            if cells[cellIndex].body == -1 { cells[cellIndex].body = index; return }
            if depth >= 20 { cells[cellIndex].body = -2; return }
            let old = cells[cellIndex].body
            let cell = cells[cellIndex], half = cell.half / 2, start = cells.count
            cells[cellIndex].children = start
            cells[cellIndex].body = -1
            for quadrant in 0..<4 {
                cells.append(Cell(x: cell.x + (quadrant & 1 == 0 ? -half : half),
                                  y: cell.y + (quadrant & 2 == 0 ? -half : half), half: half))
            }
            if old >= 0 {
                insert(old, into: start + quadrant(positions[old], cell: cell), depth: depth + 1, positions: positions, charges: charges)
            }
        }
        let cell = cells[cellIndex]
        insert(index, into: cell.children + quadrant(point, cell: cell), depth: depth + 1, positions: positions, charges: charges)
    }

    private func quadrant(_ point: GraphPoint, cell: Cell) -> Int { (point.x >= cell.x ? 1 : 0) + (point.y >= cell.y ? 2 : 0) }

    func repulsiveForce(index: Int, point: GraphPoint, charge: Double, strength: Double, stack: inout [Int]) -> GraphPoint {
        var result = GraphPoint(x: 0, y: 0)
        stack.removeAll(keepingCapacity: true)
        stack.append(0)
        while let next = stack.popLast() {
            let cell = cells[next]
            guard cell.mass > 0, !(cell.children < 0 && cell.body == index) else { continue }
            var dx = point.x - cell.weightedX / cell.mass, dy = point.y - cell.weightedY / cell.mass
            let distanceSquared = dx * dx + dy * dy
            let contains = abs(point.x - cell.x) <= cell.half && abs(point.y - cell.y) <= cell.half
            if cell.children >= 0 && (contains || cell.half * cell.half * 4 > distanceSquared * 0.81) {
                for child in 0..<4 { stack.append(cell.children + child) }
                continue
            }
            let mass = cell.children < 0 && cell.body == -2 && contains ? max(0, cell.mass - charge) : cell.mass
            if distanceSquared < 0.000001 {
                let direction = GraphSimulation.direction(index, next)
                dx = direction.x; dy = direction.y
            }
            let softened = dx * dx + dy * dy + 100
            let scale = strength * charge * mass / (softened * sqrt(softened))
            result.x += dx * scale; result.y += dy * scale
        }
        return result
    }
}
