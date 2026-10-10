import XCTest
import Foundation
@testable import PlanisphereGraph

final class GraphSimulationTests: XCTestCase {
    private func treeLinks(_ count: Int) -> [GraphLink] {
        (1..<count).map { GraphLink(source: ($0 - 1) / 2, target: $0) }
    }

    private func assertFinite(_ graph: GraphSimulation, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(graph.positions.allSatisfy { $0.x.isFinite && $0.y.isFinite }, file: file, line: line)
        XCTAssertTrue(graph.energy.isFinite, file: file, line: line)
        XCTAssertTrue(graph.radii.allSatisfy { $0 > 0 && $0.isFinite }, file: file, line: line)
    }

    func testDeterministicInitializationSteppingResetAndEdgeSanitization() {
        let links = treeLinks(60)
        var first = GraphSimulation(nodeCount: 64, links: links)
        let duplicates = links.reversed().map { GraphLink(source: $0.target, target: $0.source) }
        var second = GraphSimulation(nodeCount: 64, links: links + duplicates + [GraphLink(source: -1, target: 2), GraphLink(source: 64, target: 0), GraphLink(source: 3, target: 3)])
        let initial = first.positions
        XCTAssertEqual(first.positions, second.positions)
        for _ in 0..<30 { first.step(); second.step() }
        XCTAssertEqual(first.positions, second.positions)
        XCTAssertEqual(first.energy, second.energy)
        first.drag(index: 2, to: GraphPoint(x: 100, y: 200))
        first.release(index: 2, pin: true)
        first.reset()
        XCTAssertFalse(first.isPinned(index: 2))
        XCTAssertEqual(first.positions, initial)
    }

    func testEmptySingletonNonfiniteAndExtremeInputsRemainSafe() {
        var empty = GraphSimulation(nodeCount: -1, links: [GraphLink(source: 0, target: 1)])
        empty.step(); empty.reheat(); empty.reset()
        empty.drag(index: -1, to: GraphPoint(x: 0, y: 0))
        empty.release(index: 0, pin: true)
        XCTAssertTrue(empty.isSettled)
        XCTAssertTrue(empty.positions.isEmpty)
        var graph = GraphSimulation(nodeCount: 1, links: [])
        XCTAssertEqual(graph.positions, [GraphPoint(x: 0, y: 0)])
        graph.drag(index: 0, to: GraphPoint(x: .nan, y: .infinity))
        XCTAssertEqual(graph.positions, [GraphPoint(x: 0, y: 0)])
        graph.drag(index: 0, to: GraphPoint(x: 1e300, y: -1e300))
        graph.release(index: 0, pin: true)
        for _ in 0..<20 { graph.step() }
        XCTAssertEqual(graph.positions, [GraphPoint(x: 1_000_000, y: -1_000_000)])
        graph.spacing = .nan; graph.repulsion = .infinity
        XCTAssertEqual(graph.spacing, 1)
        XCTAssertEqual(graph.repulsion, 1)
        graph.spacing = 20; graph.repulsion = -2
        XCTAssertEqual(graph.spacing, 2)
        XCTAssertEqual(graph.repulsion, 0.2)
        assertFinite(graph)
    }

    func testPinnedAndDraggedPositionsStayExactWhileNeighborsMove() {
        var graph = GraphSimulation(nodeCount: 40, links: treeLinks(40))
        let pinned = GraphPoint(x: 300, y: -200)
        let dragged = GraphPoint(x: 0, y: 0)
        graph.drag(index: 0, to: pinned); graph.release(index: 0, pin: true)
        graph.drag(index: 1, to: dragged)
        let old = graph.positions[2]
        for _ in 0..<80 { graph.step() }
        XCTAssertEqual(graph.positions[0], pinned)
        XCTAssertEqual(graph.positions[1], dragged)
        XCTAssertNotEqual(graph.positions[2], old)
        graph.release(index: 1, pin: false)
        graph.setPinned(index: 0, false)
        for _ in 0..<10 { graph.step() }
        XCTAssertNotEqual(graph.positions[0], pinned)
        assertFinite(graph)
    }

    func testCoincidentNodesSeparateWithoutUnboundedFrameDisplacement() {
        var graph = GraphSimulation(nodeCount: 100, links: (1..<100).map { GraphLink(source: 0, target: $0) })
        graph.restorePositions(Dictionary(uniqueKeysWithValues: (0..<100).map { ($0, GraphPoint(x: 0, y: 0)) }))
        for _ in 0..<120 {
            let previous = graph.positions
            graph.step()
            for index in graph.positions.indices {
                XCTAssertLessThanOrEqual(hypot(graph.positions[index].x - previous[index].x, graph.positions[index].y - previous[index].y), 17.601)
            }
            assertFinite(graph)
        }
        XCTAssertGreaterThan(graph.positions.map { hypot($0.x, $0.y) }.max() ?? 0, 50)
        var pair = GraphSimulation(nodeCount: 2, links: [])
        pair.restorePositions([0: GraphPoint(x: 0, y: 0), 1: GraphPoint(x: 0, y: 0)])
        for _ in 0..<100 { pair.step() }
        XCTAssertGreaterThanOrEqual(hypot(pair.positions[0].x - pair.positions[1].x, pair.positions[0].y - pair.positions[1].y), pair.radii[0] + pair.radii[1])
    }

    func testThousandNodesSettleAndSleepWithoutDriftOrRunaway() {
        var graph = GraphSimulation(nodeCount: 1_000, links: treeLinks(1_000))
        var frames = 0
        while !graph.isSettled && frames < 600 { graph.step(); frames += 1 }
        XCTAssertTrue(graph.isSettled)
        XCTAssertLessThan(frames, 500)
        XCTAssertEqual(graph.energy, 0)
        XCTAssertLessThan(graph.positions.map { hypot($0.x, $0.y) }.max() ?? 0, 2_000)
        let settled = graph.positions
        for _ in 0..<100 { graph.step() }
        XCTAssertEqual(graph.positions, settled)
        assertFinite(graph)
    }

    func testDraggingAnIsolatedComponentReheatsLocallyAndBatchRestoreKeepsPins() {
        var graph = GraphSimulation(nodeCount: 100, links: [])
        for _ in 0..<500 { graph.step() }
        XCTAssertTrue(graph.isSettled)
        let original = graph.positions
        let farthest = original.indices.max { hypot(original[$0].x - original[0].x, original[$0].y - original[0].y) < hypot(original[$1].x - original[0].x, original[$1].y - original[0].y) }!
        graph.drag(index: 0, to: GraphPoint(x: original[0].x + 20, y: original[0].y + 20))
        graph.release(index: 0, pin: true)
        for _ in 0..<30 { graph.step() }
        XCTAssertEqual(graph.positions[farthest], original[farthest])
        let pin = graph.positions[0]
        graph.restorePositions([1: GraphPoint(x: 10, y: 10), -1: GraphPoint(x: 0, y: 0), 100: GraphPoint(x: 0, y: 0), 2: GraphPoint(x: .nan, y: 3)])
        XCTAssertEqual(graph.positions[0], pin)
        XCTAssertTrue(graph.isPinned(index: 0))
        XCTAssertEqual(graph.positions[1], GraphPoint(x: 10, y: 10))
        assertFinite(graph)
    }

    func testComponentPackingAndCollisionSpacingStayReadable() {
        let links = (1..<40).map { GraphLink(source: 0, target: $0) } + (41..<80).map { GraphLink(source: 40, target: $0) }
        var graph = GraphSimulation(nodeCount: 90, links: links)
        for _ in 0..<500 { graph.step() }
        XCTAssertTrue(graph.isSettled)
        var overlaps = 0
        for a in graph.positions.indices { for b in (a + 1)..<graph.positions.count {
            let distance = hypot(graph.positions[a].x - graph.positions[b].x, graph.positions[a].y - graph.positions[b].y)
            if distance + 0.5 < graph.radii[a] + graph.radii[b] { overlaps += 1 }
        } }
        XCTAssertEqual(overlaps, 0)
        XCTAssertLessThan(graph.positions.map { hypot($0.x, $0.y) }.max() ?? 0, 2_000)
    }

    func testPerformanceFixturesStayFiniteAtOneAndFiveThousandNodes() {
        for count in [1_000, 5_000] {
            var graph = GraphSimulation(nodeCount: count, links: treeLinks(count))
            let start = ContinuousClock.now
            for _ in 0..<8 { graph.step() }
            print("GRAPH_BENCH nodes=\(count) frames=8 elapsed=\(start.duration(to: .now))")
            assertFinite(graph)
        }
    }

    func testDenseThousandNodeGraphAndLargeStarHaveBoundedMotion() {
        let dense = (0..<1_000).flatMap { source in
            (1...24).map { GraphLink(source: source, target: (source + $0) % 1_000) }
        }
        let star = (1..<1_000).map { GraphLink(source: 0, target: $0) }
        for links in [dense, star] {
            var graph = GraphSimulation(nodeCount: 1_000, links: links)
            for _ in 0..<8 {
                let old = graph.positions
                graph.step()
                for index in old.indices {
                    XCTAssertLessThanOrEqual(hypot(graph.positions[index].x - old[index].x, graph.positions[index].y - old[index].y), 17.601)
                }
            }
            assertFinite(graph)
        }
    }

    func testFolderDisksStaySeparatedDespiteBridgesInsideOneConnectedComponent() {
        let count = 900, size = 150
        let groups = (0..<count).map { $0 / size }
        var links: [GraphLink] = []
        for index in 0..<count {
            let base = index / size * size, local = index % size
            links.append(GraphLink(source: index, target: base + (local + 1) % size))
            links.append(GraphLink(source: index, target: base + (local + 7) % size))
        }
        for group in 0..<5 { links.append(GraphLink(source: group * size, target: (group + 1) * size)) }
        var graph = GraphSimulation(nodeCount: count, links: links, groups: groups)
        let identical = GraphSimulation(nodeCount: count, links: links.reversed(), groups: groups)
        XCTAssertEqual(graph.positions, identical.positions)
        var frames = 0
        while !graph.isSettled && frames < 500 { graph.step(); frames += 1 }
        XCTAssertTrue(graph.isSettled)
        assertFinite(graph)
        let centers = (0..<6).map { group -> GraphPoint in
            let points = graph.positions[(group * size)..<((group + 1) * size)]
            return GraphPoint(x: points.reduce(0) { $0 + $1.x } / Double(size),
                              y: points.reduce(0) { $0 + $1.y } / Double(size))
        }
        var minimumSeparation = Double.infinity
        for a in centers.indices { for b in (a + 1)..<centers.count {
            minimumSeparation = min(minimumSeparation, hypot(centers[a].x - centers[b].x, centers[a].y - centers[b].y))
        } }
        XCTAssertGreaterThan(minimumSeparation, 400)
        for group in 0..<6 {
            let center = centers[group]
            let squared = graph.positions[(group * size)..<((group + 1) * size)].reduce(0.0) {
                $0 + ($1.x - center.x) * ($1.x - center.x) + ($1.y - center.y) * ($1.y - center.y)
            }
            XCTAssertLessThan(sqrt(squared / Double(size)), minimumSeparation * 0.4)
        }
        print("GRAPH_FOLDER_FIXTURE nodes=900 groups=6 frames=\(frames) minimumCentroidSeparation=\(minimumSeparation)")
    }

    func testUnlinkedNotesPackCompactlyAndInvalidGroupingFallsBack() {
        let graph = GraphSimulation(nodeCount: 1_000, links: [], groups: (0..<1_000).map { $0 % 6 })
        XCTAssertLessThan(graph.positions.map { hypot($0.x, $0.y) }.max() ?? 0, 400)
        let links = treeLinks(100)
        let normal = GraphSimulation(nodeCount: 100, links: links)
        let invalid = GraphSimulation(nodeCount: 100, links: links, groups: [1, 2])
        XCTAssertEqual(normal.positions, invalid.positions)
        let oneGroup = GraphSimulation(nodeCount: 100, links: links, groups: [Int](repeating: 5, count: 100))
        XCTAssertEqual(normal.positions, oneGroup.positions)
    }
}
