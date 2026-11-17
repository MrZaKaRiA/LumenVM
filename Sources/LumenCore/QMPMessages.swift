import Foundation

/// Pure builders for the QMP commands used to hot-plug a host disk as a USB drive.
///
/// Verified against QEMU 11.1.2 by scripts/validate-device-hotplug.py. A macOS disk-device fd
/// cannot be passed to QEMU with add-fd: QEMU's socket chardev clears O_NONBLOCK on every
/// SCM_RIGHTS fd with fcntl(F_SETFL), which XNU forwards to the disk driver as FIONBIO, which
/// fails with ENOTTY, so QEMU drops the monitor connection. Lumen instead gives the disk fd to a
/// `qemu-nbd` child (as its stdin, opened as /dev/fd/0) and attaches QEMU to that over a private
/// unix socket. `addFD`/`removeFD` remain for non-device descriptors.
public enum QMPMessages {
    public static let nbdExportName = "lumen"

    /// `{"execute": name, "id": id, "arguments": ...}` as one line of JSON.
    public static func command(_ name: String, arguments: [String: Any]? = nil, id: String) throws -> Data {
        var message: [String: Any] = ["execute": name, "id": id]
        if let arguments { message["arguments"] = arguments }
        var data = try JSONSerialization.data(withJSONObject: message, options: [.sortedKeys])
        data.append(10)
        return data
    }

    public static func addFD(fdsetID: Int, opaque: String? = nil) -> [String: Any] {
        var arguments: [String: Any] = ["fdset-id": fdsetID]
        if let opaque { arguments["opaque"] = opaque }
        return arguments
    }

    public static func removeFD(fdsetID: Int) -> [String: Any] { ["fdset-id": fdsetID] }

    /// An NBD client node connected to Lumen's per-disk qemu-nbd export.
    public static func blockdevAddNBD(nodeName: String, socketPath: String, readOnly: Bool) -> [String: Any] {
        [
            "driver": "nbd", "node-name": nodeName,
            "server": ["type": "unix", "path": socketPath],
            "export": nbdExportName,
            "read-only": readOnly, "auto-read-only": false,
            // Guest flushes become NBD_CMD_FLUSH, which qemu-nbd turns into a device flush.
            "cache": ["direct": true, "no-flush": false],
            "discard": "ignore"
        ]
    }

    public static func blockdevDel(nodeName: String) -> [String: Any] { ["node-name": nodeName] }

    /// A removable USB mass-storage device on the xHCI controller (`-device qemu-xhci,id=usb`).
    public static func deviceAddUSBStorage(id: String, drive: String, serial: String) -> [String: Any] {
        ["driver": "usb-storage", "id": id, "drive": drive, "bus": "usb.0", "removable": true, "serial": serial]
    }

    public static func deviceDel(id: String) -> [String: Any] { ["id": id] }

    /// Arguments for `qemu-nbd` serving the disk fd it inherits as stdin to exactly one client.
    /// Without --persistent, qemu-nbd exits (closing the disk) when QEMU disconnects.
    public static func qemuNBDArguments(socketPath: String, readOnly: Bool) -> [String] {
        ["--socket=\(socketPath)", "--export-name=\(nbdExportName)", "--cache=none", "--discard=ignore",
         "--image-opts", "driver=host_device,filename=/dev/fd/0"] + (readOnly ? ["--read-only"] : [])
    }
}

/// One parsed line from a QMP monitor.
public enum QMPLine {
    case greeting
    case reply(id: String?, result: Result<Any, QMPCommandError>)
    case event(name: String, data: [String: Any])

    public init?(_ line: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return nil }
        if object["QMP"] != nil {
            self = .greeting
        } else if let name = object["event"] as? String {
            self = .event(name: name, data: object["data"] as? [String: Any] ?? [:])
        } else if let failure = object["error"] as? [String: Any] {
            self = .reply(id: object["id"] as? String, result: .failure(QMPCommandError(
                errorClass: failure["class"] as? String ?? "GenericError",
                description: failure["desc"] as? String ?? "command failed")))
        } else if object.keys.contains("return") {
            self = .reply(id: object["id"] as? String, result: .success(object["return"] ?? [:]))
        } else {
            return nil
        }
    }

    /// The qdev id of a DEVICE_DELETED event (events for unnamed child devices have none).
    public var deletedDeviceID: String? {
        guard case let .event(name, data) = self, name == "DEVICE_DELETED" else { return nil }
        return data["device"] as? String
    }
}

public struct QMPCommandError: Error, LocalizedError, Equatable {
    public let errorClass: String
    public let description: String
    public init(errorClass: String, description: String) {
        self.errorClass = errorClass
        self.description = description
    }
    public var errorDescription: String? { description }
}
