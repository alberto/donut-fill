import Foundation
import Testing
@testable import ScanKit

struct MountedVolumeTests {
    @Test func startupDiskComesFirstAndScansDataVolume() throws {
        let volumes = MountedVolume.all()
        let startup = try #require(volumes.first)

        #expect(startup.isStartupDisk)
        #expect(startup.scanPath == "/System/Volumes/Data")
        #expect(startup.space.capacity > startup.space.free)
    }

    @Test func spaceMathNeverGoesNegative() {
        let space = VolumeSpace(name: "x", capacity: 100, available: 80, availableIncludingPurgeable: 70)

        #expect(space.purgeable == 0)
        #expect(space.hidden(scanned: 500) == 0)
    }
}
