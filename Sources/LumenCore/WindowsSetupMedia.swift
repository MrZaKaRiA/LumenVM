import Foundation

/// Files placed on Lumen's small helper disc that is attached next to Windows installation media.
///
/// Windows Setup automatically reads `autounattend.xml` from removable media. This file only adds
/// registry values and runs helper scripts; every Setup page (language, edition, disk, account)
/// stays interactive.
public enum WindowsSetupMedia {
    public struct File: Equatable {
        public let relativePath: String
        public let contents: String
    }

    public static func files(bypassChecks: Bool, sharedFolderName: String?, managedSharing: WindowsFolderConnection? = nil, preferLocalAccount: Bool = true, displaySetup: WindowsDisplaySetup? = nil, discMarker: String? = nil) -> [File] {
        var files = [
            File(relativePath: "autounattend.xml", contents: autounattend(bypassChecks: bypassChecks, preferLocalAccount: preferLocalAccount)),
            File(relativePath: "startup.nsh", contents: startupScript),
            File(relativePath: "lumen/install-drivers.cmd", contents: driverScript),
            File(relativePath: "lumen/finish-setup.cmd", contents: finishSetupScript),
            File(relativePath: "lumen/display-ready.ps1", contents: WindowsDisplaySetup.readinessScript),
            File(relativePath: "lumen/display-setup.json", contents: displaySetup?.configuration ?? "{}"),
            File(relativePath: "lumen/install-graphics-service.cmd", contents: graphicsServiceScript),
            File(relativePath: "lumen/configure-display.cmd", contents: displayConfigurationScript),
            File(relativePath: "lumen/connect-folders.ps1", contents: WindowsFolderConnection.script),
            File(relativePath: "lumen/connect-folders.json", contents: (managedSharing ?? WindowsFolderConnection(password: "", shares: [])).configuration),
            File(relativePath: "lumen/install-sharing.cmd", contents: WindowsFolderConnection.installScript),
            File(relativePath: "lumen/install-clipboard.cmd", contents: WindowsClipboardAgent.installScript),
            File(relativePath: "lumen/Install Lumen Drivers.cmd", contents: "@echo off\r\npowershell -NoProfile -Command \"Start-Process -FilePath (Join-Path $env:ProgramData 'Lumen\\Tools\\finish-setup.cmd') -Verb RunAs\"\r\n"),
            File(relativePath: "lumen/Display settings.cmd", contents: "@echo off\r\nstart ms-settings:display\r\n"),
            File(relativePath: "README.txt", contents: readme)
        ]
        if let discMarker, WindowsGuestCommands.isDiscMarker(discMarker) {
            files.append(File(relativePath: "lumen/id-" + discMarker, contents: discMarker))
        }
        if let share = sharedFolderName?.trimmingCharacters(in: .whitespacesAndNewlines), !share.isEmpty,
           share.rangeOfCharacter(from: CharacterSet(charactersIn: "\"\\/:*?<>|").union(.controlCharacters)) == nil {
            files.append(File(relativePath: "lumen/Connect Mac Shared Folder.cmd", contents: shareScript(shareName: share)))
        }
        return files
    }

    static func autounattend(bypassChecks: Bool, preferLocalAccount: Bool = true) -> String {
        var peCommands: [String] = []
        if bypassChecks {
            // The virtual machine has a TPM 2.0 from swtpm, but its ARM64 UEFI firmware has no
            // Secure Boot keys. These documented LabConfig values let Setup continue.
            for value in ["BypassTPMCheck", "BypassSecureBootCheck", "BypassRAMCheck", "BypassStorageCheck", "BypassCPUCheck"] {
                peCommands.append(#"reg add HKLM\SYSTEM\Setup\LabConfig /v \#(value) /t REG_DWORD /d 1 /f"#)
            }
            peCommands.append(#"reg add HKLM\SYSTEM\Setup\MoSetup /v AllowUpgradesWithUnsupportedTPMOrCPU /t REG_DWORD /d 1 /f"#)
        }
        // The installer can use networking before the specialize pass. Never import x64 drivers.
        peCommands.append(#"cmd /c for %i in (D E F G H I J K L M N O P Q R S T U V W X Y Z) do @if exist %i:\NetKVM\w11\ARM64\netkvm.inf drvload %i:\NetKVM\w11\ARM64\netkvm.inf"#)
        // VirtIO GOP can stop refreshing when Windows leaves UEFI. Load the signed WDDM
        // display driver in WinPE too, before waiting for a visible Setup window.
        peCommands.append(#"cmd /c for %i in (D E F G H I J K L M N O P Q R S T U V W X Y Z) do @if exist %i:\viogpudo\w11\ARM64\viogpudo.inf drvload %i:\viogpudo\w11\ARM64\viogpudo.inf"#)
        let specialize = [
            // Allows "I don't have internet" during the out-of-box experience.
            #"reg add HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE /v BypassNRO /t REG_DWORD /d 1 /f"#,
            #"cmd /c for %i in (D E F G H I J K L M N O P Q R S T U V W X Y Z) do @if exist %i:\lumen\install-drivers.cmd call %i:\lumen\install-drivers.cmd /setup"#,
            #"cmd /c for %i in (D E F G H I J K L M N O P Q R S T U V W X Y Z) do @if exist %i:\lumen\install-drivers.cmd xcopy "%i:\lumen\*" "%ProgramData%\Lumen\Tools\" /E /I /Y"#,
            #"cmd /c del /q "%ProgramData%\Lumen\Tools\*.json" "%ProgramData%\Lumen\Tools\id-*""#,
            #"cmd /c copy /y "%ProgramData%\Lumen\Tools\Install Lumen Drivers.cmd" "%PUBLIC%\Desktop\Install Lumen Drivers.cmd""#,
            #"cmd /c for %i in (D E F G H I J K L M N O P Q R) do @if exist "%i:\lumen\Connect Mac Shared Folder.cmd" copy /y "%i:\lumen\Connect Mac Shared Folder.cmd" "C:\Users\Public\Desktop\""#
        ]
        func block(_ commands: [String]) -> String {
            commands.enumerated().map { index, command in
                """
                        <RunSynchronousCommand wcm:action="add">
                          <Order>\(index + 1)</Order>
                          <Path>\(escape(command))</Path>
                        </RunSynchronousCommand>
                """
            }.joined(separator: "\n")
        }
        let component = #"processorArchitecture="arm64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS""#
        let pe = peCommands.isEmpty ? "" : """
          <settings pass="windowsPE">
            <component name="Microsoft-Windows-Setup" \(component)>
              <!-- Install from the selected ISO without waiting for Setup downloads.
                   Normal Windows Update remains enabled after installation. -->
              <DynamicUpdate><Enable>false</Enable><WillShowUI>Never</WillShowUI></DynamicUpdate>
              <RunSynchronous>
        \(block(peCommands))
              </RunSynchronous>
            </component>
          </settings>

        """
        let accountScreens = preferLocalAccount ? "<OOBE><HideOnlineAccountScreens>true</HideOnlineAccountScreens></OOBE>" : ""
        let firstLogon = escape(#"cmd /d /c for %i in (D E F G H I J K L M N O P Q R S T U V W X Y Z) do @if exist %i:\lumen\finish-setup.cmd call %i:\lumen\finish-setup.cmd /setup"#)
        let accountSetup = """
          <settings pass="oobeSystem">
            <component name="Microsoft-Windows-Shell-Setup" \(component)>
              \(accountScreens)
              <FirstLogonCommands>
                <SynchronousCommand wcm:action="add">
                  <Order>1</Order>
                  <Description>Finish installing Lumen ARM64 guest tools</Description>
                  <CommandLine>\(firstLogon)</CommandLine>
                  <RequiresUserInput>false</RequiresUserInput>
                </SynchronousCommand>
              </FirstLogonCommands>
            </component>
          </settings>
        """
        return """
        <?xml version="1.0" encoding="utf-8"?>
        <!-- Generated by Lumen. Setup pages stay interactive. -->
        <unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
        \(pe)  <settings pass="specialize">
            <component name="Microsoft-Windows-Deployment" \(component)>
              <RunSynchronous>
        \(block(specialize))
              </RunSynchronous>
            </component>
          </settings>
        \(accountSetup)
        </unattend>

        """
    }

    static let finishSetupScript = #"""
    @echo off
    setlocal
    call "%~dp0install-drivers.cmd" /quiet
    set "FAILED=%ERRORLEVEL%"
    rem Readiness is asynchronous so the Windows first-logon pass can finish.
    powershell -NoProfile -Command "Start-ScheduledTask -TaskName 'Lumen Display Setup' -ErrorAction Stop" >> "%TEMP%\Lumen-display-setup.log" 2>&1
    if errorlevel 1 set "FAILED=1"
    if not "%FAILED%"=="0" echo [!] Guest tools need attention. See %TEMP%\Lumen-drivers.log and Lumen-display-setup.log.
    rem Optional integration must never block Windows Setup or wait for a key.
    if /i "%~1"=="/setup" exit /b 0
    if /i not "%~1"=="/quiet" pause
    exit /b %FAILED%
    """#.replacingOccurrences(of: "\n", with: "\r\n")

    /// Called unattended by Setup and manually after installing. Logs failures rather than
    /// stopping Setup at an invisible `pause` prompt. Driver signing remains enforced by Windows.
    static let driverScript = """
    @echo off\r
    rem Generated by Lumen: installs ARM64 VirtIO drivers when the virtio-win disc is attached.\r
    echo ========================================================\r
    echo   Lumen VirtIO ARM64 Driver Installer\r
    echo ========================================================\r
    echo.\r
    echo Scanning drives for VirtIO drivers disc...\r
    setlocal\r
    set "FOUND=0"\r
    set "FAILED=0"\r
    set "LOG=%TEMP%\\Lumen-drivers.log"\r
    echo Lumen ARM64 driver installation > "%LOG%"\r
    rem Startup and elevated shortcuts run these tools, so only administrators and SYSTEM\r
    rem may change them. Protect the folder before copying so new files inherit this.\r
    if not exist "%ProgramData%\\Lumen\\Tools" mkdir "%ProgramData%\\Lumen\\Tools" >> "%LOG%" 2>&1\r
    call :ProtectTools\r
    if errorlevel 1 set "FAILED=1"\r
    rem Refresh the repair tools and desktop launcher for existing installations too.\r
    if /i not "%~dp0"=="%ProgramData%\\Lumen\\Tools\\" (\r
      xcopy "%~dp0*" "%ProgramData%\\Lumen\\Tools\\" /E /I /Y >> "%LOG%" 2>&1\r
      if errorlevel 1 set "FAILED=1"\r
    )\r
    rem Disc data documents hold credentials and one-launch markers. Keep only code.\r
    del /q "%ProgramData%\\Lumen\\Tools\\*.json" "%ProgramData%\\Lumen\\Tools\\id-*" >> "%LOG%" 2>&1\r
    copy /y "%ProgramData%\\Lumen\\Tools\\Install Lumen Drivers.cmd" "%PUBLIC%\\Desktop\\Install Lumen Drivers.cmd" >> "%LOG%" 2>&1\r
    if errorlevel 1 set "FAILED=1"\r
    call "%~dp0install-sharing.cmd" >> "%LOG%" 2>&1\r
    if errorlevel 1 set "FAILED=1"\r
    for %%L in (D E F G H I J K L M N O P Q R S T U V W X Y Z) do (\r
      if exist %%L:\\NetKVM\\w11\\ARM64\\netkvm.inf (\r
        set FOUND=1\r
        echo Found VirtIO driver disc on drive %%L:\r
        echo Installing network and device drivers...\r
        rem Only install drivers for Lumen's attached devices. The disc retains optional drivers.\r
        for %%D in (NetKVM viogpudo Balloon vioserial) do (\r
          if exist "%%L:\\%%D\\w11\\ARM64\\*.inf" (\r
            echo Installing: %%D ARM64...\r
            for %%I in ("%%L:\\%%D\\w11\\ARM64\\*.inf") do (\r
              call :InstallDriver "%%~fI"\r
              if errorlevel 1 set "FAILED=1"\r
            )\r
          )\r
        )\r
        call "%~dp0install-graphics-service.cmd" "%%L:\\viogpudo\\w11\\ARM64" >> "%LOG%" 2>&1\r
        if errorlevel 1 set "FAILED=1"\r
      )\r
    )\r
    echo.\r
        call "%~dp0install-clipboard.cmd" >> "%LOG%" 2>&1\r
        if errorlevel 1 set "FAILED=1"\r
    if "%FOUND%"=="0" (\r
      set "FAILED=1"\r
      echo No VirtIO driver disc was detected. >> "%LOG%"\r
      echo [!] No VirtIO driver disc was detected.\r
      echo     Choose a VirtIO driver ISO in Lumen Settings, then restart this VM.\r
      echo     The disc must contain NetKVM and viogpudo w11/ARM64 drivers.\r
    ) else (\r
      echo [*] Driver scan finished. Check Device Manager and the log for results.\r
    )\r
    if "%FAILED%"=="1" echo [!] A driver or graphics service failed. Details are in the log.\r
    echo.\r
    echo Log: %LOG%\r
    echo For sharp Retina text use Windows Settings, System, Display and set Scale to 200%%.\r
    echo Restart Windows to finish graphics setup.\r
    echo Compatibility display is a fixed-resolution recovery mode. New VMs use VirtIO graphics automatically.\r
    if /i "%~1"=="/setup" exit /b 0\r
    if /i "%~1"=="/quiet" exit /b %FAILED%\r
    pause\r
    exit /b %FAILED%\r
    :InstallDriver\r
    pnputil /add-driver "%~1" /install >> "%LOG%" 2>&1\r
    set "DRIVER_RESULT=%ERRORLEVEL%"\r
    echo Driver result for "%~1": %DRIVER_RESULT% >> "%LOG%"\r
    if "%DRIVER_RESULT%"=="0" exit /b 0\r
    rem 259 means no matching hardware or an equal/better driver is already active.\r
    if "%DRIVER_RESULT%"=="259" exit /b 0\r
    if "%DRIVER_RESULT%"=="3010" exit /b 0\r
    if "%DRIVER_RESULT%"=="1641" exit /b 0\r
    exit /b 1\r
    :ProtectTools\r
    icacls "%ProgramData%\\Lumen" /setowner *S-1-5-32-544 /T /C /Q >> "%LOG%" 2>&1\r
    if errorlevel 1 exit /b 1\r
    icacls "%ProgramData%\\Lumen" /inheritance:r /grant:r *S-1-5-18:(OI)(CI)F *S-1-5-32-544:(OI)(CI)F *S-1-5-32-545:(OI)(CI)RX /Q >> "%LOG%" 2>&1\r
    if errorlevel 1 exit /b 1\r
    icacls "%ProgramData%\\Lumen\\*" /reset /T /C /Q >> "%LOG%" 2>&1\r
    exit /b %ERRORLEVEL%\r

    """

    /// pnputil stages the display driver but does not install its user-session resize service.
    /// Keep both publisher-signed ARM64 executables together on the system disk, never on CD.
    static let graphicsServiceScript = #"""
    @echo off
    setlocal
    set "SOURCE=%~1"
    set "TARGET=%ProgramFiles%\Lumen\Graphics"
    if not exist "%SOURCE%\vgpusrv.exe" exit /b 1
    if not exist "%SOURCE%\viogpuap.exe" exit /b 1
    powershell -NoProfile -Command "$ErrorActionPreference='Stop';foreach($n in @('vgpusrv.exe','viogpuap.exe')){$p=Join-Path $env:SOURCE $n;$s=Get-AuthenticodeSignature -LiteralPath $p;if($s.Status -ne 'Valid'){Write-Error ('Invalid graphics helper signature: '+$n);exit 1}}"
    if errorlevel 1 exit /b 1
    if not exist "%TARGET%" mkdir "%TARGET%"
    if errorlevel 1 exit /b 1
    set "SERVICE_EXISTS=0"
    sc query vgpusrv >nul 2>&1
    if not errorlevel 1 (
      set "SERVICE_EXISTS=1"
      sc stop vgpusrv >nul 2>&1
      powershell -NoProfile -Command "$s=Get-Service vgpusrv;try{$s.WaitForStatus('Stopped',[TimeSpan]::FromSeconds(15))}catch{exit 1}"
      if errorlevel 1 exit /b 1
    )
    copy /y "%SOURCE%\vgpusrv.exe" "%TARGET%\vgpusrv.exe" >nul
    if errorlevel 1 exit /b 1
    copy /y "%SOURCE%\viogpuap.exe" "%TARGET%\viogpuap.exe" >nul
    if errorlevel 1 exit /b 1
    pushd "%TARGET%"
    if "%SERVICE_EXISTS%"=="0" vgpusrv.exe -i
    popd
    rem The installer is idempotent: an existing service is configured and started below.
    sc config vgpusrv binPath= "\"%TARGET%\vgpusrv.exe\"" start= auto
    if errorlevel 1 exit /b 1
    powershell -NoProfile -Command "try{$s=Get-Service vgpusrv;if($s.Status -ne 'Running'){Start-Service vgpusrv};$s.WaitForStatus('Running',[TimeSpan]::FromSeconds(15))}catch{Write-Error $_;exit 1}"
    if errorlevel 1 exit /b 1
    sc query vgpusrv
    rem Keep the elevated startup action in Program Files, protected from ordinary users.
    copy /y "%~dp0configure-display.cmd" "%TARGET%\configure-display.cmd" >nul
    if errorlevel 1 exit /b 1
    copy /y "%~dp0display-ready.ps1" "%TARGET%\display-ready.ps1" >nul
    if errorlevel 1 exit /b 1
    powershell -NoProfile -Command "$ErrorActionPreference='Stop';$exe=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe';$a=New-ScheduledTaskAction -Execute $exe -Argument ('-NoProfile -ExecutionPolicy Bypass -File '+[char]34+$env:TARGET+'\display-ready.ps1'+[char]34);$t=New-ScheduledTaskTrigger -AtStartup;$t.Delay='PT30S';$l=New-ScheduledTaskTrigger -AtLogOn;$s=New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::FromMinutes(4));Register-ScheduledTask -TaskName 'Lumen Display Setup' -Action $a -Trigger @($t,$l) -Settings $s -User SYSTEM -RunLevel Highest -Force | Out-Null"
    if errorlevel 1 exit /b 1
    powershell -NoProfile -Command "$ErrorActionPreference='Stop';$a=New-ScheduledTaskAction -Execute $env:ComSpec -Argument ('/d /c '+[char]34+[char]34+$env:TARGET+'\configure-display.cmd'+[char]34+' /restart'+[char]34);$t=New-ScheduledTaskTrigger -AtStartup;$t.Delay='PT15S';$s=New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::FromMinutes(2));Register-ScheduledTask -TaskName 'Lumen Display Repair' -Action $a -Trigger $t -Settings $s -User SYSTEM -RunLevel Highest -Force | Out-Null"
    if errorlevel 1 exit /b 1
    call "%TARGET%\configure-display.cmd"
    if errorlevel 3011 exit /b 1
    if errorlevel 3010 echo Restart Windows to finish the display repair.
    if errorlevel 1 if not errorlevel 3010 exit /b 1
    echo Display controls and automatic display-mode recovery are configured.
    exit /b 0

    """#.replacingOccurrences(of: "\n", with: "\r\n")

    /// Apply the fallback fix only when the VirtIO PCI GPU is present. On a mode change,
    /// the startup task performs one normal restart, then clears the temporary boot flag.
    /// The loaded VirtIO topology stays sharp; the next firmware-only boot stays usable.
    /// Do not disable the BasicDisplay service or rely on a user logging in to recover.
    static let displayConfigurationScript = #"""
    @echo off
    setlocal
    set "LUMEN_DISPLAY_BOOT=0"
    if /i "%~1"=="/restart" set "LUMEN_DISPLAY_BOOT=1"
    powershell -NoProfile -Command "$ErrorActionPreference='Stop';try{$gpu=@(Get-PnpDevice -PresentOnly | Where-Object {$_.InstanceId -like 'PCI\VEN_1AF4&DEV_1050*'}).Count -gt 0;$p='HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers\BasicDisplay';$v=Get-ItemProperty -LiteralPath $p -Name DisableBasicDisplayFallback -ErrorAction SilentlyContinue;if($env:LUMEN_DISPLAY_BOOT -ne '1'){if($null -ne $v){Remove-ItemProperty -LiteralPath $p -Name DisableBasicDisplayFallback};exit 0};if($gpu){$state='HKLM:\SOFTWARE\Lumen\Display';$done=Get-ItemProperty -LiteralPath $state -Name RepairComplete -ErrorAction SilentlyContinue;$active=@(Get-CimInstance Win32_VideoController | Where-Object {$_.PNPDeviceID -like 'PCI\VEN_1AF4&DEV_1050*' -and $_.CurrentHorizontalResolution -gt 800}).Count -gt 0;if($v.DisableBasicDisplayFallback -eq 1 -or $active){if($null -ne $v){Remove-ItemProperty -LiteralPath $p -Name DisableBasicDisplayFallback};New-Item -Path $state -Force | Out-Null;New-ItemProperty -LiteralPath $state -Name RepairComplete -Value 1 -PropertyType DWord -Force | Out-Null;exit 0};if($done.RepairComplete -eq 1){exit 0};New-Item -Path $p -Force | Out-Null;New-ItemProperty -LiteralPath $p -Name DisableBasicDisplayFallback -Value 1 -PropertyType DWord -Force | Out-Null;exit 3010}else{Remove-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Lumen\Display' -Name RepairComplete -ErrorAction SilentlyContinue;if($null -ne $v){Remove-ItemProperty -LiteralPath $p -Name DisableBasicDisplayFallback};exit 0}}catch{Write-Error $_;exit 1}"
    set "RESULT=%ERRORLEVEL%"
    if "%RESULT%"=="3010" if /i "%~1"=="/restart" (
      rem No /f: never force-close guest applications.
      shutdown.exe /r /t 0 /d p:2:4 /c "Lumen is finishing the display-mode configuration."
      if errorlevel 1 exit /b 1
      exit /b 0
    )
    exit /b %RESULT%

    """#.replacingOccurrences(of: "\n", with: "\r\n")

    static func shareScript(shareName: String) -> String {
        // Encode the PowerShell payload so valid share names containing %, &, !,
        // apostrophes or non-ASCII characters never enter cmd.exe's parser.
        let path = "\\\\10.0.2.2\\" + shareName
        let literal = path.replacingOccurrences(of: "'", with: "''")
        let command = "$ErrorActionPreference='Stop';$p='\(literal)';Start-Process -FilePath explorer.exe -ArgumentList ('\"'+$p+'\"')"
        let encoded = Data(command.utf16.flatMap { [UInt8($0 & 0xff), UInt8($0 >> 8)] }).base64EncodedString()
        return """
        @echo off\r
        rem Windows Explorer handles the Mac account prompt and connection errors.\r
        rem Lumen does not replace a mapped drive or store your Mac password.\r
        powershell -NoProfile -EncodedCommand \(encoded)\r
        if errorlevel 1 (\r
          echo Could not open the shared folder. Check Mac File Sharing and SMB account access.\r
          pause\r
          exit /b 1\r
        )\r

        """
    }

    /// Automatically runs in the EDK2 UEFI shell if the user does not press a key in time,
    /// booting \EFI\BOOT\BOOTAA64.EFI directly without dropping into the interactive shell prompt.
    static let startupScript = """
    @echo -off\r
    mode 0\r
    if exist fs0:\\efi\\boot\\bootaa64.efi then\r
      fs0:\\efi\\boot\\bootaa64.efi\r
    endif\r
    if exist fs1:\\efi\\boot\\bootaa64.efi then\r
      fs1:\\efi\\boot\\bootaa64.efi\r
    endif\r
    if exist fs2:\\efi\\boot\\bootaa64.efi then\r
      fs2:\\efi\\boot\\bootaa64.efi\r
    endif\r
    if exist fs3:\\efi\\boot\\bootaa64.efi then\r
      fs3:\\efi\\boot\\bootaa64.efi\r
    endif\r

    """

    static let readme = """
    Lumen Windows helper disc\r
    \r
    autounattend.xml  - lets Windows Setup run on this virtual machine; all choices stay yours.\r
    startup.nsh       - automatically launches the Windows 11 installer from UEFI.\r
    lumen\\install-drivers.cmd - stages ARM64 VirtIO display, network and device drivers.\r
    lumen\\connect-folders.ps1 - connects folders selected in Lumen over the private VM network.\r
    lumen\\connect-folders.json - this launch's folder list and private VM sharing credential.\r
    lumen\\install-sharing.cmd - registers automatic connection in the signed-in user session.\r

    """

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
