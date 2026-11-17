import Testing
import Foundation
@testable import LumenCore

@Suite final class HostDiskTests {
    private func disk(_ name: String = "disk4", size: UInt64 = 62_000_000_000, removable: Bool = true, ejectable: Bool = true,
                      onboard: Bool = false, image: Bool = false, whole: Bool = true, synthesized: Bool = false) -> HostDisk {
        HostDisk(bsdName: name, mediaName: "SanDisk Ultra", sizeBytes: size, isRemovable: removable, isEjectable: ejectable,
                 isInternal: onboard, isDiskImage: image, isWhole: whole, busProtocol: image ? "Disk Image" : "USB",
                 isSynthesized: synthesized)
    }

    @Test func testBSDNameValidation() {
        for name in ["disk4", "disk0", "disk12"] { #expect(HostDisk.isValidBSDName(name), "\(name)") }
        for name in ["disk4s1", "../disk4", "rdisk4", "", "disk4; rm", "disk", "/dev/disk4", "disk4 ", "Disk4", "disk-1",
                     "disk" + String(repeating: "1", count: 20)] {
            #expect(!HostDisk.isValidBSDName(name), "\(name)")
        }
    }

    @Test func testWholeDiskName() {
        #expect(HostDisk.wholeDiskName(of: "disk4") == "disk4")
        #expect(HostDisk.wholeDiskName(of: "disk0s2") == "disk0")
        #expect(HostDisk.wholeDiskName(of: "disk3s1s1") == "disk3")
        #expect(HostDisk.wholeDiskName(of: "rdisk4") == nil)
        #expect(HostDisk.wholeDiskName(of: "disk4x") == nil)
        #expect(HostDisk.wholeDiskName(of: "disk4s") == nil)
        #expect(HostDisk.wholeDiskName(of: "") == nil)
    }

    @Test func testEligibilityMatrix() {
        let none: Set<String> = []
        // External USB stick.
        #expect(DeviceEligibility.canOffer(disk(), bootDiskParents: none))
        // External, non-removable drive (e.g. a USB SSD).
        #expect(DeviceEligibility.canOffer(disk(removable: false, ejectable: false, onboard: false), bootDiskParents: none))
        // Built-in SD card reader: internal but removable media.
        #expect(DeviceEligibility.canOffer(disk(removable: true, ejectable: true, onboard: true), bootDiskParents: none))
        // Internal, non-removable SSD.
        #expect(!DeviceEligibility.canOffer(disk("disk0", removable: false, ejectable: false, onboard: true), bootDiskParents: none))
        // Disk images only with the explicit test hook.
        #expect(!DeviceEligibility.canOffer(disk(image: true), bootDiskParents: none))
        #expect(DeviceEligibility.canOffer(disk(image: true), bootDiskParents: none, allowDiskImages: true))
        // APFS synthesized container.
        #expect(!DeviceEligibility.canOffer(disk(synthesized: true), bootDiskParents: none))
        // The startup disk or library disk, even if external.
        #expect(!DeviceEligibility.canOffer(disk(), bootDiskParents: ["disk4"]))
        #expect(DeviceEligibility.canOffer(disk(), bootDiskParents: ["disk0", "disk3"]))
        // Empty media and slices.
        #expect(!DeviceEligibility.canOffer(disk(size: 0), bootDiskParents: none))
        #expect(!DeviceEligibility.canOffer(disk(whole: false), bootDiskParents: none))
        #expect(!DeviceEligibility.canOffer(disk("disk4s1"), bootDiskParents: none))
    }

    @Test func testDiskutilInfoParsing() throws {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
          <key>BusProtocol</key><string>USB</string>
          <key>DeviceIdentifier</key><string>disk4</string>
          <key>Ejectable</key><true/>
          <key>Internal</key><false/>
          <key>MediaName</key><string>SanDisk Ultra</string>
          <key>Removable</key><true/>
          <key>RemovableMedia</key><true/>
          <key>Size</key><integer>61530439680</integer>
          <key>VirtualOrPhysical</key><string>Physical</string>
          <key>WholeDisk</key><true/>
          <key>Content</key><string>FDisk_partition_scheme</string>
        </dict></plist>
        """
        let info = try #require(try PropertyListSerialization.propertyList(from: Data(plist.utf8), format: nil) as? [String: Any])
        let parsed = try #require(HostDisk(diskutilInfo: info))
        #expect(parsed.bsdName == "disk4")
        #expect(parsed.mediaName == "SanDisk Ultra")
        #expect(parsed.sizeBytes == 61_530_439_680)
        #expect(parsed.isRemovable && parsed.isEjectable && !parsed.isInternal && parsed.isWhole)
        #expect(!parsed.isDiskImage && !parsed.isSynthesized)
        #expect(DeviceEligibility.canOffer(parsed, bootDiskParents: ["disk0", "disk3"]))
        // Missing "Internal" is treated as internal; missing identifier fails.
        #expect(HostDisk(diskutilInfo: ["DeviceIdentifier": "disk5"])?.isInternal == true)
        #expect(HostDisk(diskutilInfo: ["MediaName": "x"]) == nil)
        // Disk images and synthesized APFS containers.
        #expect(HostDisk(diskutilInfo: ["DeviceIdentifier": "disk6", "BusProtocol": "Disk Image"])?.isDiskImage == true)
        let synthesized = HostDisk(diskutilInfo: ["DeviceIdentifier": "disk3", "WholeDisk": true,
                                                  "APFSPhysicalStores": [["APFSPhysicalStore": "disk0s2"]]])
        #expect(synthesized?.isSynthesized == true)
        #expect(HostDisk.backingWholeDisks(diskutilInfo: ["DeviceIdentifier": "disk3s1s1", "ParentWholeDisk": "disk3",
                                                          "APFSPhysicalStores": [["APFSPhysicalStore": "disk0s2"]]]) == ["disk0", "disk3"])
    }

    @Test func testDiskArbitrationDescriptionParsing() throws {
        let stick = try #require(HostDisk(diskArbitrationDescription: [
            "DAMediaBSDName": "disk4", "DAMediaName": "Ultra Media", "DAMediaSize": NSNumber(value: 61_530_439_680),
            "DAMediaRemovable": true, "DAMediaEjectable": true, "DAMediaWhole": true, "DADeviceInternal": false,
            "DADeviceProtocol": "USB", "DADeviceVendor": "SanDisk ", "DADeviceModel": "Ultra"
        ]))
        #expect(stick.mediaName == "SanDisk Ultra")
        #expect(stick.isWhole && !stick.isInternal && !stick.isDiskImage && !stick.isSynthesized)
        #expect(DeviceEligibility.canOffer(stick, bootDiskParents: []))
        // Internal APFS synthesized container, as reported on Apple silicon.
        let container = try #require(HostDisk(diskArbitrationDescription: [
            "DAMediaBSDName": "disk3", "DAMediaName": "AppleAPFSMedia", "DAMediaSize": 494_384_795_648,
            "DAMediaRemovable": false, "DAMediaEjectable": false, "DAMediaWhole": true, "DADeviceInternal": true,
            "DADeviceProtocol": "Apple Fabric", "DAMediaContent": "EF57347C-0000-11AA-AA11-00306543ECAC"
        ]))
        #expect(container.isSynthesized)
        #expect(!DeviceEligibility.canOffer(container, bootDiskParents: []))
        // hdiutil image: no DADeviceInternal key, "Disk Image" model.
        let image = try #require(HostDisk(diskArbitrationDescription: [
            "DAMediaBSDName": "disk7", "DAMediaName": "Apple read/write Media", "DAMediaSize": 16_777_216,
            "DAMediaRemovable": true, "DAMediaEjectable": true, "DAMediaWhole": true,
            "DADeviceProtocol": "Virtual Interface", "DADeviceModel": "Disk Image", "DADeviceVendor": "Apple"
        ]))
        #expect(image.isDiskImage && image.isInternal)
        #expect(!DeviceEligibility.canOffer(image, bootDiskParents: []))
        #expect(DeviceEligibility.canOffer(image, bootDiskParents: [], allowDiskImages: true))
        // A slice with a volume name.
        let slice = try #require(HostDisk(diskArbitrationDescription: ["DAMediaBSDName": "disk4s1", "DAMediaWhole": false, "DAVolumeName": "STICK"]))
        #expect(!slice.isWhole && slice.volumeNames == ["STICK"])
        #expect(HostDisk(diskArbitrationDescription: ["DAMediaName": "x"]) == nil)
    }

    @Test func testDisplayTitle() {
        var stick = disk()
        stick.volumeNames = ["STICK"]
        #expect(stick.displayTitle.hasPrefix("SanDisk Ultra (STICK) — "))
        #expect(stick.displayTitle.contains("GB"))
        var anonymous = disk()
        anonymous.mediaName = ""
        #expect(anonymous.displayName == "disk4")
        anonymous.volumeNames = ["DATA"]
        #expect(anonymous.displayName == "DATA")
        #expect(anonymous.displayTitle.hasPrefix("DATA — "))
    }

    @Test func testDiskMenuActionParsing() {
        let published: Set<String> = ["disk4", "disk5"]
        #expect(DiskMenuAction.parse("disk-attach:disk4", published: published) == .attach(bsdName: "disk4", readOnly: false))
        #expect(DiskMenuAction.parse("disk-attach-ro:disk4", published: published) == .attach(bsdName: "disk4", readOnly: true))
        #expect(DiskMenuAction.parse("disk-return:disk5", published: published) == .returnToMac(bsdName: "disk5"))
        #expect(DiskMenuAction.parse("disk-eject:disk5", published: published) == .eject(bsdName: "disk5"))
        // Not published, invalid names, unknown or malformed prefixes.
        for action in ["disk-attach:disk6", "disk-attach:disk4s1", "disk-attach:../disk4", "disk-attach:rdisk4",
                       "disk-attach:", "disk-attach:disk4; rm", "disk-attach: disk4", "disk-format:disk4",
                       "disk-attach-rw:disk4", "Disk-attach:disk4", "disk4", "", "refresh", "disk-eject:disk4\n"] {
            #expect(DiskMenuAction.parse(action, published: published) == nil, "\(action)")
        }
        #expect(DiskMenuAction.parse("disk-attach:disk4", published: []) == nil)
        for action in [DiskMenuAction.attach(bsdName: "disk4", readOnly: false), .attach(bsdName: "disk4", readOnly: true),
                       .returnToMac(bsdName: "disk4"), .eject(bsdName: "disk4")] {
            #expect(DiskMenuAction.parse(action.command, published: published) == action)
            #expect(action.bsdName == "disk4")
        }
    }

    @Test func testMenuItemPayloadAndMountPolicy() {
        let item = ExternalDiskMenuItem(id: "disk4", title: "SanDisk Ultra — 62 GB", attachedHere: true, attachedElsewhere: false)
        let dictionary = item.dictionary
        #expect(dictionary["id"] as? String == "disk4")
        #expect(dictionary["title"] as? String == "SanDisk Ultra — 62 GB")
        #expect(dictionary["attachedHere"] as? Bool == true)
        #expect(dictionary["attachedElsewhere"] as? Bool == false)
        #expect(PropertyListSerialization.propertyList(["externalDisks": [dictionary]], isValidFor: .binary))

        #expect(HostDiskMountPolicy.shouldBlockMount(of: "disk4s1", ownedWholeDisks: ["disk4"]))
        #expect(HostDiskMountPolicy.shouldBlockMount(of: "disk4", ownedWholeDisks: ["disk4"]))
        #expect(!HostDiskMountPolicy.shouldBlockMount(of: "disk41s1", ownedWholeDisks: ["disk4"]))
        #expect(!HostDiskMountPolicy.shouldBlockMount(of: "disk5s1", ownedWholeDisks: ["disk4"]))
        #expect(!HostDiskMountPolicy.shouldBlockMount(of: "garbage", ownedWholeDisks: ["disk4"]))
    }

    @Test func testQMPBuilders() throws {
        let ids = AttachedHostDisk.identifiers(for: "disk4")
        #expect(ids.deviceID == "lumen-usb-disk4")
        #expect(ids.nodeName == "lumen-hd-disk4")
        #expect(ids.serial == "LUMENDISK4")

        let add = QMPMessages.blockdevAddNBD(nodeName: ids.nodeName, socketPath: "/tmp/x/nbd.sock", readOnly: true)
        #expect(add["driver"] as? String == "nbd")
        #expect(add["node-name"] as? String == "lumen-hd-disk4")
        #expect(add["export"] as? String == QMPMessages.nbdExportName)
        #expect(add["read-only"] as? Bool == true)
        #expect(add["auto-read-only"] as? Bool == false)
        let server = try #require(add["server"] as? [String: String])
        #expect(server == ["type": "unix", "path": "/tmp/x/nbd.sock"])

        let device = QMPMessages.deviceAddUSBStorage(id: ids.deviceID, drive: ids.nodeName, serial: ids.serial)
        #expect(device["driver"] as? String == "usb-storage")
        #expect(device["id"] as? String == "lumen-usb-disk4")
        #expect(device["drive"] as? String == "lumen-hd-disk4")
        #expect(device["bus"] as? String == "usb.0")
        #expect(device["removable"] as? Bool == true)
        #expect(QMPMessages.deviceDel(id: ids.deviceID) as? [String: String] == ["id": "lumen-usb-disk4"])
        #expect(QMPMessages.blockdevDel(nodeName: ids.nodeName) as? [String: String] == ["node-name": "lumen-hd-disk4"])

        let line = try QMPMessages.command("device_del", arguments: QMPMessages.deviceDel(id: ids.deviceID), id: "7")
        #expect(line.last == 10)
        let decoded = try #require(try JSONSerialization.jsonObject(with: line) as? [String: Any])
        #expect(decoded["execute"] as? String == "device_del")
        #expect(decoded["id"] as? String == "7")
        #expect((decoded["arguments"] as? [String: String])?["id"] == "lumen-usb-disk4")

        let nbd = QMPMessages.qemuNBDArguments(socketPath: "/tmp/x/nbd.sock", readOnly: true)
        #expect(nbd.contains("--read-only"))
        #expect(nbd.contains("driver=host_device,filename=/dev/fd/0"))
        #expect(!nbd.contains("--persistent"))
        #expect(!QMPMessages.qemuNBDArguments(socketPath: "/tmp/s", readOnly: false).contains("--read-only"))
    }

    @Test func testQMPLineParsing() {
        let deleted = QMPLine(Data(#"{"event": "DEVICE_DELETED", "data": {"device": "lumen-usb-disk4", "path": "/machine/peripheral/lumen-usb-disk4"}, "timestamp": {"seconds": 1, "microseconds": 2}}"#.utf8))
        #expect(deleted?.deletedDeviceID == "lumen-usb-disk4")
        let child = QMPLine(Data(#"{"event": "DEVICE_DELETED", "data": {"path": "/machine/peripheral/lumen-usb-disk4/virtio-backend"}}"#.utf8))
        #expect(child != nil && child?.deletedDeviceID == nil)
        let other = QMPLine(Data(#"{"event": "STOP", "data": {}}"#.utf8))
        #expect(other?.deletedDeviceID == nil)
        if case .greeting? = QMPLine(Data(#"{"QMP": {"version": {}}}"#.utf8)) {} else { Issue.record("greeting") }
        if case let .reply(id, result)? = QMPLine(Data(#"{"return": {}, "id": "3"}"#.utf8)) {
            #expect(id == "3")
            if case .failure = result { Issue.record("expected success") }
        } else { Issue.record("reply") }
        if case let .reply(_, result)? = QMPLine(Data(#"{"error": {"class": "DeviceNotFound", "desc": "Device 'x' not found"}, "id": "4"}"#.utf8)),
           case let .failure(error) = result {
            #expect(error.errorClass == "DeviceNotFound")
        } else { Issue.record("error reply") }
        #expect(QMPLine(Data("not json".utf8)) == nil)
    }
}
