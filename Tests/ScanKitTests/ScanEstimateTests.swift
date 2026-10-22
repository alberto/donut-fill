import Foundation
import Testing
@testable import ScanKit

struct ScanEstimateTests {
    let defaults: UserDefaults
    let history: ScanHistory

    init() throws {
        let suite = "ScanEstimateTests-\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        history = ScanHistory(defaults: defaults)
    }

    private func progress(files: Int, directories: Int, unreadable: Int = 0) -> ScanProgress.Snapshot {
        var snapshot = ScanProgress.Snapshot()
        snapshot.files = files
        snapshot.directories = directories
        snapshot.unreadable = unreadable
        return snapshot
    }

    @Test func fractionCountsEveryItemAndNeverFills() {
        let estimate = ScanEstimate(expectedItems: 1_000)

        #expect(estimate.fraction(of: progress(files: 400, directories: 90, unreadable: 10)) == 0.5)
        #expect(estimate.fraction(of: progress(files: 2_000, directories: 0)) == 0.99, "a short estimate stops just before full")
    }

    @Test func remainingFollowsTheRateSoFar() throws {
        let estimate = ScanEstimate(expectedItems: 1_000)

        let remaining = try #require(estimate.remaining(after: .seconds(10), progress: progress(files: 200, directories: 50)))
        #expect(remaining == .seconds(30))
        #expect(estimate.remaining(after: .milliseconds(500), progress: progress(files: 200, directories: 50)) == nil, "too early to tell")
        #expect(estimate.remaining(after: .seconds(10), progress: progress(files: 1_000, directories: 0)) == nil, "past the estimate")
    }

    @Test func usesThePreviousScanScaledByVolumeChange() {
        history.save(ScanHistory.Record(items: 1_000, volumeItems: 10_000), forPath: "/Users/me")

        let estimate = ScanEstimate.forScan(atPath: "/Users/me", history: history, volume: { _ in (items: 11_000, isRoot: false) })

        #expect(estimate?.expectedItems == 1_100)
    }

    @Test func firstScanOfAVolumeUsesItsItemCount() {
        let volume = ScanEstimate.forScan(atPath: "/Volumes/Disk", history: history, volume: { _ in (items: 5_000, isRoot: true) })
        let folder = ScanEstimate.forScan(atPath: "/Volumes/Disk/folder", history: history, volume: { _ in (items: 5_000, isRoot: false) })

        #expect(volume?.expectedItems == 5_000)
        #expect(folder == nil, "a folder's share of its volume is unknown")
    }

    @Test func readsTheItemCountOfARealVolume() throws {
        let root = try #require(ScanEstimate.volumeItems(containing: "/"))
        #expect(root.isRoot)
        #expect(root.items > 0)
        #expect(ScanEstimate.volumeItems(containing: NSTemporaryDirectory())?.isRoot == false)
    }

    @Test func historyKeepsTheMostRecentScans() {
        for index in 0..<(ScanHistory.limit + 5) {
            history.save(ScanHistory.Record(items: index, volumeItems: nil), forPath: "/path\(index)")
        }

        #expect(history.record(forPath: "/path0") == nil)
        #expect(history.record(forPath: "/path\(ScanHistory.limit + 4)")?.items == ScanHistory.limit + 4)
    }
}
