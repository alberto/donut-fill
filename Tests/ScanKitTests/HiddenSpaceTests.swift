import Foundation
import Testing
@testable import ScanKit

struct HiddenSpaceTests {
    private func plist(_ object: Any) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0)
    }

    @Test func findsTheOtherVolumesInTheScannedVolumesContainer() throws {
        let list = try plist(["Containers": [
            ["Volumes": [
                ["DeviceIdentifier": "disk1s1", "Name": "iSCPreboot", "Roles": ["Preboot"], "CapacityInUse": 5_000],
            ]],
            ["Volumes": [
                ["DeviceIdentifier": "disk3s1", "Name": "Macintosh HD", "Roles": ["System"], "CapacityInUse": 16_000],
                ["DeviceIdentifier": "disk3s5", "Name": "Data", "Roles": ["Data"], "CapacityInUse": 300_000],
                ["DeviceIdentifier": "disk3s6", "Name": "VM", "Roles": ["VM"], "CapacityInUse": 2_000],
            ]],
        ]])

        let others = APFSInfo.otherVolumes(inList: list, besides: "disk3s5")

        #expect(others.map(\.name) == ["Macintosh HD", "VM"])
        #expect(others.map(\.size) == [16_000, 2_000])
        #expect(APFSInfo.otherVolumes(inList: list, besides: "disk9s1").isEmpty)
    }

    @Test func readsSnapshotNames() throws {
        let list = try plist(["Snapshots": [
            ["SnapshotName": "com.apple.TimeMachine.2026-10-22-101530.local"],
            ["SnapshotName": "com.bombich.ccc.12345"],
        ]])

        let snapshots = APFSInfo.snapshots(inList: list)

        #expect(snapshots.count == 2)
        #expect(snapshots.filter(\.isMadeByMacOS).count == 1)
    }

    @Test func capsOtherVolumesAtTheHiddenTotal() {
        let hidden = HiddenSpace(total: 50, otherVolumes: [
            APFSVolumeUsage(name: "VM", roles: ["VM"], size: 20),
            APFSVolumeUsage(name: "System", roles: ["System"], size: 40),
        ])

        #expect(hidden.otherVolumes.map(\.name) == ["System", "VM"], "largest first")
        #expect(hidden.otherVolumesSize == 50)
        #expect(hidden.stillHidden == 0)
    }

    @Test func readsTheDeviceOfTheRootVolume() {
        #expect(APFSInfo.deviceIdentifier(forPath: "/")?.hasPrefix("disk") == true)
    }
}
