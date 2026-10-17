import Foundation

/// One `grapheine-measure-v1` document: the engine's lattice measurements of the
/// admitted Markdown graph, taken on a private copy and bound to the discovery
/// fingerprint. Every number is a heuristic about explicit links; the engine's
/// own `basis` line travels with the document and the UI shows it unchanged.
public struct GraphMeasurement: Decodable, Sendable {
    public struct Vault: Decodable, Sendable { public let name: String; public let roots: [String] }
    public struct Counts: Decodable, Sendable { public let nodes: Int; public let edges: Int }
    public struct RankedPath: Decodable, Sendable, Identifiable {
        public let path: String
        public let degree: Int?
        public let rank: Double?
        public let score: Double?
        public let A: Int?
        public let B: Int?
        public var id: String { path }
    }
    public struct Health: Decodable, Sendable {
        public let nodes: Int, edges: Int, mean_degree: Double, orphans: Int, isolates: Int, unresolved: Int
        public let unresolved_markdown_occurrences: Int?, ambiguous_resolved_occurrences: Int?, unsupported_occurrences: Int?, self_links: Int?
        public let tags: Int?, bipartite: Bool?, A: Int?, B: Int?
    }
    public struct Degree: Decodable, Sendable {
        public let nodes: Int, edges: Int, mean: Double, median: Double, max: Int
        public let isolated: Int?, degree_ge_10: Int?
        public let histogram: [String: Int]?
        public let top: [RankedPath]
    }
    public struct Density: Decodable, Sendable { public let nodes: Int, edges: Int, max_possible: Int; public let density: Double? }
    public struct Components: Decodable, Sendable { public let components: Int, largest: Int, isolates: Int; public let sizes: [Int]? }
    public struct Triangles: Decodable, Sendable { public let triangles: Int }
    public struct Clustering: Decodable, Sendable { public let avg_local_clustering: Double, n_evaluated: Int }
    public struct Girth: Decodable, Sendable { public let girth: Int?; public let acyclic: Bool }
    public struct Bipartite: Decodable, Sendable { public let bipartite: Bool, A: Int, B: Int; public let odd_edge: [String]? }
    public struct Spectrum: Decodable, Sendable {
        public struct Giant: Decodable, Sendable { public let nodes: Int; public let fiedler: Double? }
        public let nodes: Int, components: Int
        public let lam_max: Double?, fiedler: Double?
        public let reading: String?, note: String?
        public let giant_component: Giant?
    }
    public struct Dirac: Decodable, Sendable { public let mode: String; public let candidates: [RankedPath] }
    public struct PageRank: Decodable, Sendable { public let nodes: Int, damping: Double; public let iterations: Int?; public let top: [RankedPath] }
    public struct Communities: Decodable, Sendable {
        public struct Community: Decodable, Sendable, Identifiable {
            public let size: Int, hub: String
            public let sample: [String]?
            public var id: String { hub }
        }
        public let communities: Int, nodes: Int
        public let modularity: Double?, iterations: Int?
        public let analysis_mode: String?, note: String?
        public let top: [Community]
    }
    public struct Hubs: Decodable, Sendable { public let top: [RankedPath] }
    public struct Values: Decodable, Sendable {
        public let health: Health?, degree: Degree?, density: Density?, components: Components?, triangles: Triangles?
        public let clustering: Clustering?, girth: Girth?, bipartite: Bipartite?, spectrum: Spectrum?, dirac: Dirac?
        public let pagerank: PageRank?, communities: Communities?, hubs: Hubs?
    }

    public let schema: String
    public let engine: String
    public let link_rule: String
    public let basis: String
    public let vault: Vault
    public let graph: Counts
    public let gate: Int?
    public let values: Values
    public let skipped: [String: String]
    public let timings: [String: Double]
    public let elapsed: Double
    public let measured_at: String
    public let vaultPath: String
    public let scannedAt: String
    public let scope: PruningScanScope
    public let fingerprint: String
    public let noteCount: Int

    /// Every vault-relative path the document names, for validation.
    public var namedPaths: [String] {
        var paths: [String] = []
        paths += values.degree?.top.map(\.path) ?? []
        paths += values.hubs?.top.map(\.path) ?? []
        paths += values.dirac?.candidates.map(\.path) ?? []
        paths += values.pagerank?.top.map(\.path) ?? []
        paths += values.bipartite?.odd_edge ?? []
        for community in values.communities?.top ?? [] { paths.append(community.hub); paths += community.sample ?? [] }
        return paths
    }
}
