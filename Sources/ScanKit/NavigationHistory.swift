/// Back/forward history of the places visited, like a browser's.
public struct NavigationHistory<Place: Equatable> {
    /// Places before the current one, oldest first.
    private var back: [Place] = []
    /// Places gone back from, the next one last.
    private var forward: [Place] = []

    public init() {}

    /// Records leaving `old` for a new place; the places gone back from are dropped.
    public mutating func visit(from old: Place) {
        back.append(old)
        forward.removeAll()
    }

    public func canGoBack(from current: Place) -> Bool {
        back.contains { $0 != current }
    }

    public var canGoForward: Bool { !forward.isEmpty }

    /// The previous place, or nil when there's none; `current` becomes the next forward.
    public mutating func goBack(from current: Place) -> Place? {
        while let place = back.popLast() {
            guard place != current else { continue }
            forward.append(current)
            return place
        }
        return nil
    }

    /// The place gone back from, or nil when there's none; `current` becomes the previous one.
    public mutating func goForward(from current: Place) -> Place? {
        while let place = forward.popLast() {
            guard place != current else { continue }
            back.append(current)
            return place
        }
        return nil
    }

    /// Forgets places that no longer exist, merging the neighbours this leaves side by side.
    public mutating func removeAll(where shouldRemove: (Place) -> Bool) {
        back = Self.collapsed(back.filter { !shouldRemove($0) })
        forward = Self.collapsed(forward.filter { !shouldRemove($0) })
    }

    public mutating func removeAll() {
        back.removeAll()
        forward.removeAll()
    }

    private static func collapsed(_ places: [Place]) -> [Place] {
        places.reduce(into: []) { result, place in
            if result.last != place { result.append(place) }
        }
    }
}
