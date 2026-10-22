import Foundation

/// Items staged for deletion. Never holds both a folder and something inside it,
/// so sizes are never double counted and nothing is deleted twice.
public struct Collector: Sendable {
    public private(set) var items: [FileNode] = []

    public init() {}

    public var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }
    public var isEmpty: Bool { items.isEmpty }

    public func contains(_ node: FileNode) -> Bool {
        items.contains { $0 === node || node.isDescendant(of: $0) }
    }

    /// Adds `node`, replacing any collected items inside it.
    /// Returns false if it is already covered by a collected folder.
    @discardableResult
    public mutating func add(_ node: FileNode) -> Bool {
        guard node.parent != nil, !contains(node) else { return false }
        items.removeAll { $0.isDescendant(of: node) }
        items.append(node)
        return true
    }

    public mutating func remove(_ node: FileNode) {
        items.removeAll { $0 === node }
    }

    public mutating func removeAll() {
        items.removeAll()
    }
}
