import Foundation

/// Fixed Run-dialog commands. No host paths or user-controlled values enter guest shell code.
public enum WindowsGuestCommands {
    public static let installDrivers = #"powershell -NoProfile -Command "$p='{0}:\lumen\finish-setup.cmd' -f (Get-Volume -FileSystemLabel LUMENSETUP).DriveLetter;Start-Process $p -Verb RunAs""#
    public static let displaySettings = "ms-settings:display"
    public static let networkSettings = "ms-settings:network-status"
    public static let deviceManager = "devmgmt.msc"
    public static let connectFolders = #"powershell -NoProfile -ExecutionPolicy Bypass -Command "$p='{0}:\lumen\connect-folders.ps1' -f (Get-Volume -FileSystemLabel LUMENSETUP).DriveLetter;& $p;if($LASTEXITCODE -ne 1){Start-Process explorer.exe '\\10.0.2.4\'}""#
}
