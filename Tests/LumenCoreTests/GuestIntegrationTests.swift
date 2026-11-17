import Testing
import Foundation
@testable import LumenCore

@Suite struct GuestIntegrationTests {
    private var testRoot: URL {
        ProcessInfo.processInfo.environment["LUMEN_TEST_ROOT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? URL(fileURLWithPath: "/private/tmp", isDirectory: true)
    }
    @Test func testTransferPreservesFilesAndNeverOverwritesOrAcceptsReadOnlyDestinations() throws {
        let root = testRoot.appendingPathComponent("LumenTransfer-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source"), destination = root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let file = source.appendingPathComponent("text.txt")
        try Data("guest transfer".utf8).write(to: file)
        let copied = try SharedFileTransfer.copy([file], to: SharedFolder(path: destination.path))
        #expect(try Data(contentsOf: copied[0]) == Data(contentsOf: file))
        try Data("changed".utf8).write(to: file)
        #expect(throws: (any Error).self) { try SharedFileTransfer.copy([file], to: SharedFolder(path: destination.path)) }
        #expect(try Data(contentsOf: copied[0]) == Data("guest transfer".utf8))
        #expect(try SharedFileTransfer.copy(copied, to: SharedFolder(path: destination.path)) == copied)
        #expect(throws: (any Error).self) { try SharedFileTransfer.copy([file], to: SharedFolder(path: destination.path, readOnly: true)) }
        #expect(throws: (any Error).self) { try SharedFileTransfer.copy([root], to: SharedFolder(path: destination.path)) }
        let link = source.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        #expect(throws: (any Error).self) { try SharedFileTransfer.copy([link], to: SharedFolder(path: destination.path)) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path) == ["text.txt"])
    }

    @Test func testLinuxInstallerHasValidShellSyntaxForBothSharingConfigurations() throws {
        #expect(GuestKeyboard.supports(LinuxGuestTools.installCommand))
        let file = testRoot.appendingPathComponent("LumenLinuxTools-" + UUID().uuidString + ".sh")
        defer { try? FileManager.default.removeItem(at: file) }
        for sharing in [false, true] {
            for rosetta in [false, true] {
                for (name, script) in LinuxGuestTools.files(sharedFolders: sharing, rosetta: rosetta) {
                    try Data(script.utf8).write(to: file)
                    #expect(try shell(["-n", file.path]) == 0, Comment(rawValue: name))
                }
            }
        }
        let installer = LinuxGuestTools.installer(sharedFolders: false, rosetta: true)
        #expect(installer.contains("[ '1' = 1 ]"))
        #expect(installer.contains("systemctl enable --now fstrim.timer"))
        #expect(installer.contains(LinuxGuestTools.rosettaBinfmt))
        // binfmt_misc fields are colon-separated; the magic and mask must not contain one.
        #expect(LinuxGuestTools.rosettaBinfmt.split(separator: ":", omittingEmptySubsequences: false).count == 8)
        #expect(LinuxGuestTools.rosettaBinfmt.contains(":\(LinuxGuestTools.rosettaMountPoint)/rosetta:"))
        #expect(try shell(["-n", "-c", LinuxGuestTools.installCommand]) == 0)

    }
    @Test func testFstabEntriesAreNoautoAndExistingOnesAreRepaired() throws {
        for rosetta in [false, true] {
            let installer = LinuxGuestTools.installer(sharedFolders: true, rosetta: rosetta)
            #expect(installer.contains("lumen /mnt/lumen virtiofs noauto,nofail 0 0"))
            #expect(!installer.contains("defaults,nofail"))
            #expect(!installer.contains("virtiofs ro,nofail"))
            #expect(installer.contains("lumen-mounts.service"))
            #expect(installer.contains("/etc/rc.local"))
        }
        #expect(LinuxGuestTools.installer(sharedFolders: false, rosetta: true).contains("rosetta /media/rosetta virtiofs ro,noauto,nofail 0 0"))
        #expect(LinuxGuestTools.files(sharedFolders: false)["mount-shares.sh"] != nil)

        let root = testRoot.appendingPathComponent("LumenFstab-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fstab = root.appendingPathComponent("fstab")
        let original = "UUID=abc / ext4 defaults 0 1\nlumen /mnt/lumen virtiofs defaults,nofail 0 0\n"
            + "rosetta /media/rosetta virtiofs ro,nofail 0 0\n# lumen /mnt/lumen is a comment\n/dev/sda2 /data ext4 defaults,nofail 0 2\n"
        try Data(original.utf8).write(to: fstab)
        let script = root.appendingPathComponent("repair.sh")
        try Data(("failed=0\n" + LinuxGuestTools.fstabSnippet(rosetta: false) + "\nexit $failed\n").utf8).write(to: script)
        let environment = ["LUMEN_FSTAB": fstab.path]
        for _ in 0..<2 { #expect(try shell([script.path], environment: environment) == 0) }
        let repaired = try String(contentsOf: fstab, encoding: .utf8)
        #expect(repaired == "UUID=abc / ext4 defaults 0 1\nlumen /mnt/lumen virtiofs noauto,nofail 0 0\n"
            + "rosetta /media/rosetta virtiofs ro,noauto,nofail 0 0\n# lumen /mnt/lumen is a comment\n/dev/sda2 /data ext4 defaults,nofail 0 2\n")
        #expect(try String(contentsOf: root.appendingPathComponent("fstab.lumen-bak"), encoding: .utf8) == original)
        // A missing entry is appended once, as noauto.
        let empty = root.appendingPathComponent("empty-fstab")
        try Data("/dev/sda1 / ext4 defaults 0 1\n".utf8).write(to: empty)
        for _ in 0..<2 { #expect(try shell([script.path], environment: ["LUMEN_FSTAB": empty.path]) == 0) }
        let appended = try String(contentsOf: empty, encoding: .utf8)
        #expect(appended.components(separatedBy: "\n").filter { $0.hasPrefix("lumen /mnt/lumen") } == ["lumen /mnt/lumen virtiofs noauto,nofail 0 0"])
    }

    @Test func testBootMountScriptNeverFailsAndMountsOnlyDeclaredShares() throws {
        let root = testRoot.appendingPathComponent("LumenMountShares-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        for (name, body) in [("mount", "echo \"$*\" >> \"$MOUNT_LOG\"; exit 32"), ("mountpoint", "exit 1"), ("modprobe", "exit 1")] {
            let url = bin.appendingPathComponent(name)
            try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        let script = root.appendingPathComponent("mount-shares.sh")
        try Data(LinuxGuestTools.mountSharesScript.utf8).write(to: script)
        let fstab = root.appendingPathComponent("fstab")
        try Data("lumen /mnt/lumen virtiofs noauto,nofail 0 0\n".utf8).write(to: fstab)
        let log = root.appendingPathComponent("mounts")
        let environment = ["PATH": bin.path + ":/usr/bin:/bin", "LUMEN_FSTAB": fstab.path, "MOUNT_LOG": log.path]
        // mount failing (no such virtiofs tag) must not fail the script, and Rosetta is skipped.
        #expect(try shell([script.path], environment: environment) == 0)
        #expect(try String(contentsOf: log, encoding: .utf8) == "/mnt/lumen\n")
    }

    private func shell(_ arguments: [String], environment: [String: String]? = nil) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = arguments
        if let environment { process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new } }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        _ = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus
    }

    @Test func testRunitSetupStartsBothServicesAndPreservesExistingEntries() throws {
        let root = testRoot.appendingPathComponent("LumenRunit-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("sv"), active = root.appendingPathComponent("active"), bin = root.appendingPathComponent("bin")
        for directory in [source.appendingPathComponent("dbus"), source.appendingPathComponent("spice-vdagentd"), active, bin] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        for name in ["dbus", "spice-vdagentd"] {
            let supervise = source.appendingPathComponent(name + "/supervise")
            try FileManager.default.createDirectory(at: supervise, withIntermediateDirectories: true)
            try Data().write(to: supervise.appendingPathComponent("control"))
        }
        let script = root.appendingPathComponent("runit.sh")
        try Data(LinuxGuestTools.runitScript.utf8).write(to: script)
        let sv = bin.appendingPathComponent("sv")
        try Data("#!/bin/bash\nprintf '%s\\n' \"$*\" >> \"$SV_LOG\"\n".utf8).write(to: sv)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sv.path)
        let log = root.appendingPathComponent("calls")
        let environment = ["PATH": bin.path + ":/usr/bin:/bin", "SV_LOG": log.path]
        let args = [script.path, source.path, active.path, "dbus", "spice-vdagentd"]
        for _ in 0..<2 { #expect(try shell(args, environment: environment) == 0) }
        let calls = try String(contentsOf: log)
        #expect(calls.contains("up " + active.appendingPathComponent("dbus").path))
        #expect(calls.contains("status " + active.appendingPathComponent("spice-vdagentd").path))
        // A broken, unrelated user service entry is reported, never replaced.
        let dbus = active.appendingPathComponent("dbus")
        try FileManager.default.removeItem(at: dbus)
        try FileManager.default.createSymbolicLink(atPath: dbus.path, withDestinationPath: "missing-custom-service")
        #expect(try shell(args, environment: environment) == 1)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: dbus.path) == "missing-custom-service")
        #expect(try shell([script.path, source.path, active.path, "../bad"], environment: environment) == 1)
        // A daemon that cannot start is a failure, even if its status command succeeds.
        try Data("#!/bin/bash\n[ \"$1\" = status ]\n".utf8).write(to: sv)
        let sleep = bin.appendingPathComponent("sleep")
        try Data("#!/bin/bash\nexit 0\n".utf8).write(to: sleep)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sleep.path)
        #expect(try shell([script.path, source.path, active.path, "spice-vdagentd"], environment: environment) == 1)
    }

    @Test func testDesktopSetupPreservesDwmStartupAndDoesNotDuplicateItsHook() throws {
        let root = testRoot.appendingPathComponent("LumenSession-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = root.appendingPathComponent("bin"), home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".dwm"), withIntermediateDirectories: true)
        let startup = home.appendingPathComponent(".dwm/autostart.sh")
        let original = "#!/bin/sh\necho original-startup\n"
        try Data(original.utf8).write(to: startup)
        for (name, body) in ["id": "echo 1000", "pgrep": "exit 0", "spice-vdagent": "exit 0", "mountpoint": "exit 1"] {
            let tool = bin.appendingPathComponent(name)
            try Data(("#!/bin/bash\n" + body + "\n").utf8).write(to: tool)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        }
        let script = root.appendingPathComponent("session.sh")
        try Data(LinuxGuestTools.sessionScript.utf8).write(to: script)
        var environment = ["HOME": home.path, "XDG_CONFIG_HOME": home.appendingPathComponent(".config").path,
                           "DISPLAY": ":1", "WAYLAND_DISPLAY": "", "XDG_SESSION_TYPE": "x11", "PATH": bin.path + ":/usr/bin:/bin"]
        for _ in 0..<2 { #expect(try shell([script.path], environment: environment) == 0) }
        let updated = try String(contentsOf: startup)
        #expect(updated.hasPrefix(original))
        #expect(updated.components(separatedBy: "# Lumen guest tools").count == 2)
        environment["DISPLAY"] = ""
        #expect(try shell([script.path], environment: environment) == 1)
        environment["DISPLAY"] = ":1"
        environment["XDG_SESSION_TYPE"] = "wayland"
        #expect(try shell([script.path], environment: environment) == 1)
    }

    @Test func testPhysicalUSKeyboardKeepsShellSymbolsDistinctFromDigits() {
        var positions = Set<String>()
        for scalar in 32...126 {
            let char = Character(String(UnicodeScalar(scalar)!))
            let key = GuestKeyboard.key(for: char)
            #expect(positions.insert("\(key.keyCode):\(key.shift)").inserted)
        }
        for (symbol, plain) in [("&", "7"), ("|", "\\"), ("(", "9"), (")", "0"), ("A", "a")] {
            let shifted = GuestKeyboard.key(for: Character(symbol))
            let unshifted = GuestKeyboard.key(for: Character(plain))
            #expect(shifted.keyCode == unshifted.keyCode)
            #expect(shifted.shift)
            #expect(!unshifted.shift)
        }
    }

}
