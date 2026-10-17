import Foundation

/// A read-only snapshot of resolved links in the admitted Markdown scope.
/// It is not a pruning decision or a full-folder integrity check.
public struct GraphSnapshot: Decodable, Sendable {
    public let vaultPath: String
    public let scannedAt: String
    public let nodes: [GraphNode]
    public let edges: [GraphEdge]
    public let scope: PruningScanScope
    public let totalNodeCount: Int
    public let totalEdgeCount: Int
    public let omittedNodeCount: Int
    public let omittedEdgeCount: Int
    public let unresolvedLinkCount: Int
    public let ambiguousLinkCount: Int
    public let unsupportedLinkCount: Int
    public let limits: [String]
}

public struct GraphNode: Decodable, Sendable, Hashable, Identifiable {
    public let id: String
    public let title: String
    public let folder: String
    /// Degrees count returned directed edges; a self-edge contributes twice.
    public let degree: Int
    public let inDegree: Int
    public let outDegree: Int

    public init(id: String, title: String, folder: String, degree: Int, inDegree: Int, outDegree: Int) {
        self.id = id; self.title = title; self.folder = folder
        self.degree = degree; self.inDegree = inDegree; self.outDegree = outDegree
    }
}

public struct GraphEdge: Decodable, Sendable, Hashable, Identifiable {
    public let source: String
    public let target: String
    public var id: String { "\(source.utf8.count):\(source)\(target.utf8.count):\(target)" }

    public init(source: String, target: String) {
        self.source = source; self.target = target
    }
}
