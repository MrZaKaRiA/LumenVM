import Foundation

/// A one-launch receipt sent only after first-logon tools verify the staged display
/// package and running graphics service. The private SMB share never exposes host data.
public struct WindowsDisplaySetup: Codable {
    public let password: String
    public let share: String
    public let ticket: String
    public init(password: String, share: String, ticket: String) {
        self.password = password; self.share = share; self.ticket = ticket
    }
    public func acceptsReceipt(_ data: Data) -> Bool {
        !ticket.isEmpty && data == Data(ticket.utf8)
    }
    public var configuration: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
    public var script: String { Self.readinessScript }
    // The scheduled task runs this protected copy, never executable code from CD.
    // Only a validated data document is read from the current host-generated disc.
    public static let readinessScript = #"""
        $ErrorActionPreference = 'Stop'
        for ($attempt = 0; $attempt -lt 30; $attempt++) {
            $setupState = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\Setup'
            if ($setupState.OOBEInProgress -ne 1 -and $setupState.SystemSetupInProgress -ne 1) { break }
            Start-Sleep -Seconds 2
        }
        if ($setupState.OOBEInProgress -eq 1 -or $setupState.SystemSetupInProgress -eq 1) { exit 0 }
        $config = $null
        for ($attempt = 0; $attempt -lt 30; $attempt++) {
            foreach ($volume in @(Get-Volume -FileSystemLabel LUMENSETUP -ErrorAction SilentlyContinue)) {
                if (-not $volume.DriveLetter) { continue }
                $path = '{0}:\lumen\display-setup.json' -f $volume.DriveLetter
                if (Test-Path -LiteralPath $path) {
                    $info = Get-Item -LiteralPath $path
                    if ($info.Length -gt 4096) { throw 'Invalid display setup configuration.' }
                    $config = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
                    break
                }
            }
            if ($null -ne $config) { break }
            Start-Sleep -Seconds 2
        }
        if ($null -eq $config) { exit 0 }
        if (-not $config.ticket) {
            Unregister-ScheduledTask -TaskName 'Lumen Display Setup' -Confirm:$false -ErrorAction SilentlyContinue
            exit 0
        }
        if ($config.share -notmatch '^LumenSetup_[0-9A-Fa-f]{32}\$$' -or
            $config.password -notmatch '^[0-9A-Fa-f]{64}$' -or
            $config.ticket -notmatch '^[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}$') {
            throw 'Invalid display setup configuration.'
        }
        $drivers = @(Get-WindowsDriver -Online | Where-Object { $_.OriginalFileName -match '(?i)\\viogpudo\.inf$' })
        if ($drivers.Count -eq 0) { throw 'The ARM64 display driver is not staged. Run Install / Repair Guest Tools.' }
        $service = Get-Service vgpusrv
        if ($service.Status -ne 'Running') { Start-Service vgpusrv }
        $service.WaitForStatus('Running', [TimeSpan]::FromSeconds(15))
        $unc = '\\10.0.2.4\' + $config.share
        for ($attempt = 0; $attempt -lt 30; $attempt++) {
            & "$env:SystemRoot\System32\net.exe" use $unc $config.password '/user:Lumen' '/persistent:no' *> $null
            if ($LASTEXITCODE -eq 0) {
                [IO.File]::WriteAllText(($unc + '\display-ready'), $config.ticket, (New-Object Text.UTF8Encoding $false))
                exit 0
            }
            Start-Sleep -Seconds 2
        }
        throw 'Could not notify Lumen that the display driver is ready.'
        """#
}
