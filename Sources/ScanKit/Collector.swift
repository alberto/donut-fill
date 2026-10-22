import Foundation

/// Items staged for deletion. Never holds both a folder and something inside it,
/// so sizes are never double counted and nothing is deleted twice.
public struct Collector: Sendable {
    public enum AddResult: Equatable, Sendable {
        case added
        /// The item, or a folder containing it, is already collected.
        case alreadyCollected
        case refused(reason: String)
    }

    public private(set) var items: [FileNode] = []
    public let protected: ProtectedPaths

    public init(protected: ProtectedPaths = ProtectedPaths()) {
        self.protected = protected
    }

    public var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }
    public var isEmpty: Bool { items.isEmpty }

    public func contains(_ node: FileNode) -> Bool {
        items.contains { $0 == node || node.isDescendant(of: $0) }
    }

    /// Why `node` can never be collected, or nil if it can.
    public func refusal(for node: FileNode) -> String? {
        guard node.parent != nil else { return "The scanned folder itself can't be collected." }
        return protected.refusal(forPath: node.path)
    }

    /// Adds `node`, replacing any collected items inside it.
    @discardableResult
    public mutating func add(_ node: FileNode) -> AddResult {
        if let reason = refusal(for: node) { return .refused(reason: reason) }
        guard !contains(node) else { return .alreadyCollected }
        items.removeAll { $0.isDescendant(of: node) }
        items.append(node)
        return .added
    }

    public mutating func remove(_ node: FileNode) {
        items.removeAll { $0 == node }
    }

    public mutating func removeAll() {
        items.removeAll()
    }
}
