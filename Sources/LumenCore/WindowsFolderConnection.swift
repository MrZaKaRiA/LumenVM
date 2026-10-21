import Foundation

/// Credentials belong only to the private VM transport, never to a Mac account.
public struct WindowsFolderConnection: Codable, Equatable {
    public let password: String
    public let shares: [String]
    public init(password: String, shares: [String]) {
        self.password = password
        self.shares = shares
    }

    public var script: String {
        let payload = ((try? JSONEncoder().encode(self)) ?? Data()).base64EncodedString()
        return #"""
        $ErrorActionPreference = 'Stop'
        $config = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('\#(payload)')) | ConvertFrom-Json
        $shortcut = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Lumen Mac Folders.lnk'
        if ($config.shares.Count -eq 0) { Remove-Item -LiteralPath $shortcut -Force -ErrorAction SilentlyContinue; exit 0 }
        $connected = $false
        for ($attempt = 0; $attempt -lt 90; $attempt++) {
            $connected = $true
            foreach ($share in $config.shares) {
                $unc = '\\10.0.2.4\' + $share
                & "$env:SystemRoot\System32\net.exe" use $unc $config.password '/user:Lumen' '/persistent:no' *> $null
                if ($LASTEXITCODE -ne 0) { $connected = $false }
            }
            if ($connected) { break }
            Start-Sleep -Seconds 2
        }
        if (!$connected) { exit 1 }
        $shell = New-Object -ComObject WScript.Shell
        $link = $shell.CreateShortcut($shortcut)
        $link.TargetPath = '\\10.0.2.4\'
        $link.Description = 'Folders selected in Lumen on your Mac'
        $link.Save()
        """#
    }

    /// Startup runs in each logged-in user's ordinary session, where Explorer's
    /// network connections belong. Setup/driver installation only creates the shortcut.
    public static var installScript: String {
        let launch = #"""
        $script = Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=5' | Where-Object { $_.VolumeName -eq 'LUMENSETUP' } | ForEach-Object { Join-Path $_.DeviceID 'lumen\connect-folders.ps1' } | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
        if (!$script) { $script = Join-Path $env:ProgramData 'Lumen\Tools\connect-folders.ps1' }
        if (Test-Path -LiteralPath $script) { & $script }
        """#
        let encodedLaunch = launch.data(using: .utf16LittleEndian)!.base64EncodedString()
        let installer = #"""
        $ErrorActionPreference='Stop'
        $shell=New-Object -ComObject WScript.Shell
        $path=Join-Path ([Environment]::GetFolderPath('CommonStartup')) 'Lumen Shared Folders.lnk'
        $link=$shell.CreateShortcut($path)
        $link.TargetPath=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $link.Arguments='-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -EncodedCommand \#(encodedLaunch)'
        $link.WindowStyle=7
        $link.Save()
        """#
        return "@echo off\r\npowershell -NoProfile -EncodedCommand \(installer.data(using: .utf16LittleEndian)!.base64EncodedString())\r\nexit /b %ERRORLEVEL%\r\n"
    }
}
