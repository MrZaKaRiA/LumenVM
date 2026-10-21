import XCTest
@testable import LumenCore

final class GuestIntegrationTests: XCTestCase {
    private var testRoot: URL {
        ProcessInfo.processInfo.environment["LUMEN_TEST_ROOT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? URL(fileURLWithPath: "/private/tmp", isDirectory: true)
    }
    func testTransferPreservesFilesAndNeverOverwritesOrAcceptsReadOnlyDestinations() throws {
        let root = testRoot.appendingPathComponent("LumenTransfer-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source"), destination = root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let file = source.appendingPathComponent("text.txt")
        try Data("guest transfer".utf8).write(to: file)
        let copied = try SharedFileTransfer.copy([file], to: SharedFolder(path: destination.path))
        XCTAssertEqual(try Data(contentsOf: copied[0]), try Data(contentsOf: file))
        try Data("changed".utf8).write(to: file)
        XCTAssertThrowsError(try SharedFileTransfer.copy([file], to: SharedFolder(path: destination.path)))
        XCTAssertEqual(try Data(contentsOf: copied[0]), Data("guest transfer".utf8))
        XCTAssertEqual(try SharedFileTransfer.copy(copied, to: SharedFolder(path: destination.path)), copied)
        XCTAssertThrowsError(try SharedFileTransfer.copy([file], to: SharedFolder(path: destination.path, readOnly: true)))
        XCTAssertThrowsError(try SharedFileTransfer.copy([root], to: SharedFolder(path: destination.path)))
        let link = source.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertThrowsError(try SharedFileTransfer.copy([link], to: SharedFolder(path: destination.path)))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), ["text.txt"])
    }

    func testLinuxInstallerHasValidShellSyntaxForBothSharingConfigurations() throws {
        XCTAssertTrue(GuestKeyboard.supports(LinuxGuestTools.installCommand))
        let file = testRoot.appendingPathComponent("LumenLinuxTools-" + UUID().uuidString + ".sh")
        defer { try? FileManager.default.removeItem(at: file) }
        for sharing in [false, true] {
            for rosetta in [false, true] {
                for (name, script) in LinuxGuestTools.files(sharedFolders: sharing, rosetta: rosetta) {
                    try Data(script.utf8).write(to: file)
                    XCTAssertEqual(try shell(["-n", file.path]), 0, name)
                }
            }
        }
        let installer = LinuxGuestTools.installer(sharedFolders: false, rosetta: true)
        XCTAssertTrue(installer.contains("[ '1' = 1 ]"))
        XCTAssertTrue(installer.contains("systemctl enable --now fstrim.timer"))
        XCTAssertTrue(installer.contains(LinuxGuestTools.rosettaBinfmt))
        // binfmt_misc fields are colon-separated; the magic and mask must not contain one.
        XCTAssertEqual(LinuxGuestTools.rosettaBinfmt.split(separator: ":", omittingEmptySubsequences: false).count, 8)
        XCTAssertTrue(LinuxGuestTools.rosettaBinfmt.contains(":\(LinuxGuestTools.rosettaMountPoint)/rosetta:"))
        XCTAssertEqual(try shell(["-n", "-c", LinuxGuestTools.installCommand]), 0)

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

    func testRunitSetupStartsBothServicesAndPreservesExistingEntries() throws {
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
        for _ in 0..<2 { XCTAssertEqual(try shell(args, environment: environment), 0) }
        let calls = try String(contentsOf: log)
        XCTAssertTrue(calls.contains("up " + active.appendingPathComponent("dbus").path))
        XCTAssertTrue(calls.contains("status " + active.appendingPathComponent("spice-vdagentd").path))
        // A broken, unrelated user service entry is reported, never replaced.
        let dbus = active.appendingPathComponent("dbus")
        try FileManager.default.removeItem(at: dbus)
        try FileManager.default.createSymbolicLink(atPath: dbus.path, withDestinationPath: "missing-custom-service")
        XCTAssertEqual(try shell(args, environment: environment), 1)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: dbus.path), "missing-custom-service")
        XCTAssertEqual(try shell([script.path, source.path, active.path, "../bad"], environment: environment), 1)
        // A daemon that cannot start is a failure, even if its status command succeeds.
        try Data("#!/bin/bash\n[ \"$1\" = status ]\n".utf8).write(to: sv)
        let sleep = bin.appendingPathComponent("sleep")
        try Data("#!/bin/bash\nexit 0\n".utf8).write(to: sleep)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sleep.path)
        XCTAssertEqual(try shell([script.path, source.path, active.path, "spice-vdagentd"], environment: environment), 1)
    }

    func testDesktopSetupPreservesDwmStartupAndDoesNotDuplicateItsHook() throws {
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
        for _ in 0..<2 { XCTAssertEqual(try shell([script.path], environment: environment), 0) }
        let updated = try String(contentsOf: startup)
        XCTAssertTrue(updated.hasPrefix(original))
        XCTAssertEqual(updated.components(separatedBy: "# Lumen guest tools").count, 2)
        environment["DISPLAY"] = ""
        XCTAssertEqual(try shell([script.path], environment: environment), 1)
        environment["DISPLAY"] = ":1"
        environment["XDG_SESSION_TYPE"] = "wayland"
        XCTAssertEqual(try shell([script.path], environment: environment), 1)
    }

    func testPhysicalUSKeyboardKeepsShellSymbolsDistinctFromDigits() {
        var positions = Set<String>()
        for scalar in 32...126 {
            let char = Character(String(UnicodeScalar(scalar)!))
            let key = GuestKeyboard.key(for: char)
            XCTAssertTrue(positions.insert("\(key.keyCode):\(key.shift)").inserted)
        }
        for (symbol, plain) in [("&", "7"), ("|", "\\"), ("(", "9"), (")", "0"), ("A", "a")] {
            let shifted = GuestKeyboard.key(for: Character(symbol))
            let unshifted = GuestKeyboard.key(for: Character(plain))
            XCTAssertEqual(shifted.keyCode, unshifted.keyCode)
            XCTAssertTrue(shifted.shift)
            XCTAssertFalse(unshifted.shift)
        }
    }

}
