import Foundation

/// Fixed Run-dialog commands. No host paths or user-controlled values enter guest shell code.
///
/// Any Windows user can mount an ISO labelled LUMENSETUP, so commands that run disc scripts
/// first find the volume holding this launch's random marker file, `lumen\id-<marker>`.
public enum WindowsGuestCommands {
    public static func makeDiscMarker() -> String {
        String(format: "%016llx", UInt64.random(in: .min ... .max))
    }

    public static func isDiscMarker(_ marker: String) -> Bool {
        marker.range(of: "^[0-9a-f]{16}$", options: .regularExpression) != nil
    }

    static func discVolume(_ marker: String) -> String {
        precondition(isDiscMarker(marker))
        return #"$v=Get-Volume -FileSystemLabel LUMENSETUP|?{Test-Path ('{0}:\lumen\id-\#(marker)' -f $_.DriveLetter)}|select -f 1;"#
    }

    public static func installDrivers(marker: String) -> String {
        #"powershell -NoProfile -Command "\#(discVolume(marker))if($v){Start-Process ('{0}:\lumen\finish-setup.cmd' -f $v.DriveLetter) -Verb RunAs}""#
    }

    public static func connectFolders(marker: String) -> String {
        #"powershell -NoProfile -ExecutionPolicy Bypass -Command "\#(discVolume(marker))if($v){& ('{0}:\lumen\connect-folders.ps1' -f $v.DriveLetter) -Open}""#
    }

    public static let displaySettings = "ms-settings:display"
    public static let networkSettings = "ms-settings:network-status"
    public static let deviceManager = "devmgmt.msc"
}
