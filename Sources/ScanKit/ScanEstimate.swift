import Darwin
import Foundation

/// How many items a scan is expected to reach, so its progress can show as a
/// fraction. Counts items rather than bytes: scan time goes by items, and one
/// big file would make a byte-based bar jump.
public struct ScanEstimate: Sendable, Equatable {
    public var expectedItems: Int

    public init(expectedItems: Int) {
        self.expectedItems = max(1, expectedItems)
    }

    /// Files and folders reached so far, as `ScanProgress` counts them.
    public static func items(in progress: ScanProgress.Snapshot) -> Int {
        progress.files + progress.directories + progress.unreadable
    }

    /// How far along the scan is. Stops at `ceiling`, short of full, since the
    /// estimate can be low; the scan finishing is what completes it.
    public func fraction(of progress: ScanProgress.Snapshot, ceiling: Double = 0.99) -> Double {
        min(ceiling, Double(Self.items(in: progress)) / Double(expectedItems))
    }

    /// Time left at the rate so far; nil while it's too early to tell or once
    /// the scan has passed the estimate.
    public func remaining(after elapsed: Duration, progress: ScanProgress.Snapshot) -> Duration? {
        let done = Self.items(in: progress)
        guard elapsed >= .seconds(2), done > 0, done < expectedItems else { return nil }
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        return .seconds(seconds * Double(expectedItems - done) / Double(done))
    }

    /// The estimate for scanning `path`: its previous scan, scaled by how much
    /// its volume changed since, or for a whole volume its item count. Nil when
    /// there's nothing to go on (a folder scanned for the first time).
    public static func forScan(
        atPath path: String,
        history: ScanHistory,
        volume: (String) -> (items: Int, isRoot: Bool)? = volumeItems(containing:)
    ) -> ScanEstimate? {
        let volume = volume(path)
        if let last = history.record(forPath: path) {
            if let now = volume?.items, let then = last.volumeItems, then > 0 {
                return ScanEstimate(expectedItems: Int(Double(last.items) * Double(now) / Double(then)))
            }
            return ScanEstimate(expectedItems: last.items)
        }
        guard let volume, volume.isRoot else { return nil }
        return ScanEstimate(expectedItems: volume.items)
    }

    /// Files and folders on the volume holding `path`, and whether `path` is
    /// that volume's root.
    public static func volumeItems(containing path: String) -> (items: Int, isRoot: Bool)? {
        var info = statfs()
        guard statfs(path, &info) == 0, info.f_files >= info.f_ffree else { return nil }
        let mountPoint = withUnsafePointer(to: &info.f_mntonname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        let normalized = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        return (Int(info.f_files - info.f_ffree), mountPoint == normalized)
    }
}

/// Item counts of past scans by path, kept in user defaults, for estimating
/// the next scan of the same path.
public struct ScanHistory {
    public struct Record: Codable, Equatable, Sendable {
        /// Items the scan reached.
        public var items: Int
        /// Items on the volume when it finished, to scale the next estimate.
        public var volumeItems: Int?
        var date = Date()

        public init(items: Int, volumeItems: Int?) {
            self.items = items
            self.volumeItems = volumeItems
        }
    }

    /// Paths remembered; the least recently scanned go first.
    static let limit = 50
    private static let key = "scanHistory"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func record(forPath path: String) -> Record? {
        records()[path]
    }

    public func save(_ record: Record, forPath path: String) {
        var all = records()
        all[path] = record
        if all.count > Self.limit {
            for (stale, _) in all.sorted(by: { $0.value.date < $1.value.date }).prefix(all.count - Self.limit) {
                all[stale] = nil
            }
        }
        defaults.set(try? JSONEncoder().encode(all), forKey: Self.key)
    }

    private func records() -> [String: Record] {
        guard let data = defaults.data(forKey: Self.key) else { return [:] }
        return (try? JSONDecoder().decode([String: Record].self, from: data)) ?? [:]
    }
}
