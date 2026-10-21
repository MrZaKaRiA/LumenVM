import Foundation

/// Credentials belong only to the private VM transport, never to a Mac account.
public struct WindowsFolderConnection: Codable, Equatable {
    public let password: String
    public let shares: [String]
    public init(password: String, shares: [String]) {
        self.password = password
        self.shares = shares
    }

    /// Data read by the fixed connection script from the current host-generated disc.
    public var configuration: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Fixed code: the protected copy in %ProgramData%\Lumen\Tools never embeds the password.
    /// It validates the disc's data document, saves the credential in the signed-in user's
    /// Credential Manager, and reuses it when the helper disc is not attached.
    public static let script = #"""
        param([switch]$Open)
        $ErrorActionPreference = 'Stop'
        $shortcut = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Lumen Mac Folders.lnk'
        $cache = Join-Path $env:LOCALAPPDATA 'Lumen\shares.json'
        $config = $null
        foreach ($volume in @(Get-Volume -FileSystemLabel LUMENSETUP -ErrorAction SilentlyContinue)) {
            if (-not $volume.DriveLetter) { continue }
            $path = '{0}:\lumen\connect-folders.json' -f $volume.DriveLetter
            if (Test-Path -LiteralPath $path) {
                if ((Get-Item -LiteralPath $path).Length -gt 65536) { throw 'Invalid shared folder configuration.' }
                $config = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
                break
            }
        }
        $password = $null
        if ($null -ne $config) {
            $shares = @($config.shares)
            if ($shares.Count -gt 0 -and $config.password -cnotmatch '^[0-9a-f]{64}$') { throw 'Invalid shared folder configuration.' }
            $password = $config.password
        } elseif (Test-Path -LiteralPath $cache) {
            $shares = @(Get-Content -LiteralPath $cache -Raw | ConvertFrom-Json)
        } else {
            exit 0
        }
        if ($shares.Count -gt 64) { throw 'Invalid shared folder configuration.' }
        foreach ($share in $shares) {
            if ($share -isnot [string] -or $share -notmatch '^[^"\\/:*?<>|\p{Cc}\p{Cf}]{1,64}$') { throw 'Invalid shared folder configuration.' }
        }
        if ($shares.Count -eq 0) {
            Remove-Item -LiteralPath $shortcut, $cache -Force -ErrorAction SilentlyContinue
            if ($null -ne $config) { & "$env:SystemRoot\System32\cmdkey.exe" '/delete:10.0.2.4' *> $null }
            exit 0
        }
        if ($password) {
            # Per-user and DPAPI protected; other Windows accounts cannot read it.
            & "$env:SystemRoot\System32\cmdkey.exe" '/add:10.0.2.4' '/user:Lumen' "/pass:$password" *> $null
            New-Item -ItemType Directory -Path (Split-Path $cache) -Force | Out-Null
            ConvertTo-Json -InputObject @($shares) -Compress | Set-Content -LiteralPath $cache -Encoding UTF8
        }
        $connected = $false
        for ($attempt = 0; $attempt -lt 90; $attempt++) {
            $connected = $true
            foreach ($share in $shares) {
                $unc = '\\10.0.2.4\' + $share
                if ($password) {
                    & "$env:SystemRoot\System32\net.exe" use $unc $password '/user:Lumen' '/persistent:no' *> $null
                } else {
                    & "$env:SystemRoot\System32\net.exe" use $unc '/persistent:no' *> $null
                }
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
        if ($Open) { Start-Process explorer.exe '\\10.0.2.4\' }
        """#

    /// Startup runs in each logged-in user's ordinary session, where Explorer's
    /// network connections belong. Setup/driver installation only creates the shortcut.
    /// It runs only the administrator-protected copy, never code from a CD volume,
    /// since any Windows user can mount an ISO with the same label.
    public static var installScript: String {
        let launch = #"""
        $script = Join-Path $env:ProgramData 'Lumen\Tools\connect-folders.ps1'
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
