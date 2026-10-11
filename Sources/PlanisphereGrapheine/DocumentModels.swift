import Foundation

public struct DocumentLocation: Decodable, Sendable {
    public let page: Int?
    public let line: Int?
    public init(page: Int? = nil, line: Int? = nil) { self.page = page; self.line = line }
    public var label: String { page.map { "Page \($0)" } ?? line.map { "Line \($0)" } ?? "File name" }
}

public struct DocumentRead: Decodable, Sendable {
    public let root: String
    public let path: String
    public let sha256: String
    public let body: String
    public let body_sha256: String
    public let format: String
    public let representation: String
    public let location: DocumentLocation?
    public let page_count: Int?
    public let empty_pages: [Int]?
    public let total_lines: Int?
    public let preview_truncated: Bool
    public let limitations: [String]?
}

public struct DocumentMatch: Decodable, Sendable, Identifiable {
    public var id: String { path }
    public let path: String
    public let sha256: String
    public let snippet: String
    public let format: String
    public let location: DocumentLocation
}

public struct DocumentSearch: Decodable, Sendable {
    public let root: String
    public let matches: [DocumentMatch]
}
