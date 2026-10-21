import Foundation

/// Uses the upstream ARM64 SPICE agent over a local VirtIO serial port.
/// It never opens a network listener or changes Windows driver-signing policy.
public enum WindowsClipboardAgent {
    public static let installScript = #"""
    @echo off
    setlocal
    set "SOURCE=%~dp0agent"
    set "TARGET=%ProgramFiles%\Lumen\Clipboard"
    if not exist "%SOURCE%\vdservice.exe" exit /b 1
    rem The release archive and these unmodified ARM64 executables are hash pinned.
    powershell -NoProfile -Command "$ErrorActionPreference='Stop';$files=@{'vdagent.exe'='cc5167af34bf5d6dc594e85d0c309af64c1e22b9f1297a5ef69ca99a403c479a';'vdservice.exe'='4862a0ecd865c3f9ede015df4639ab97a4a166a0580e0644ab2f42052b629060'};foreach($n in $files.Keys){if((Get-FileHash -LiteralPath (Join-Path $env:SOURCE $n) -Algorithm SHA256).Hash -ne $files[$n]){throw ('Clipboard agent hash mismatch: '+$n)}}"
    if errorlevel 1 exit /b 1
    rem Preserve an agent installed by another VM product. It uses the same protocol.
    powershell -NoProfile -Command "$ErrorActionPreference='Stop';$s=Get-CimInstance Win32_Service -Filter ('Name='+[char]39+'vdservice'+[char]39);if($s -and $s.PathName -notlike ('*'+$env:TARGET+'*')){exit 2}"
    set "PROBE=%ERRORLEVEL%"
    if "%PROBE%"=="2" (
      echo Starting the existing SPICE clipboard agent without replacing it.
      powershell -NoProfile -Command "$ErrorActionPreference='Stop';try{$s=Get-Service vdservice;if($s.Status -ne 'Running'){Start-Service vdservice};$s.WaitForStatus('Running',[TimeSpan]::FromSeconds(15))}catch{Write-Error $_;exit 1}"
      if errorlevel 1 exit /b 1
      exit /b 0
    )
    if not "%PROBE%"=="0" exit /b 1
    sc query vdservice >nul 2>&1
    if not errorlevel 1 (
      powershell -NoProfile -Command "$ErrorActionPreference='Stop';$s=Get-Service vdservice;if($s.Status -ne 'Stopped'){Stop-Service vdservice;$s.WaitForStatus('Stopped',[TimeSpan]::FromSeconds(15))}"
      if errorlevel 1 exit /b 1
    )
    rem A previous per-user worker can survive service shutdown and lock its binary.
    rem Stop only Lumen's worker, never another product's agent.
    powershell -NoProfile -Command "$ErrorActionPreference='Stop';$path=Join-Path $env:TARGET 'vdagent.exe';Get-CimInstance Win32_Process -Filter ('Name='+[char]39+'vdagent.exe'+[char]39) | Where-Object {$_.ExecutablePath -eq $path} | ForEach-Object {Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop}"
    if errorlevel 1 exit /b 1
    if not exist "%TARGET%" mkdir "%TARGET%"
    if errorlevel 1 exit /b 1
    copy /y "%SOURCE%\vdagent.exe" "%TARGET%\vdagent.exe" >nul
    if errorlevel 1 exit /b 1
    copy /y "%SOURCE%\vdservice.exe" "%TARGET%\vdservice.exe" >nul
    if errorlevel 1 exit /b 1
    copy /y "%SOURCE%\COPYING" "%TARGET%\COPYING" >nul
    copy /y "%SOURCE%\provenance.json" "%TARGET%\provenance.json" >nul
    sc query vdservice >nul 2>&1
    if errorlevel 1 (
      sc create vdservice binPath= "\"%TARGET%\vdservice.exe\"" start= auto DisplayName= "Lumen Clipboard Agent"
      if errorlevel 1 exit /b 1
    ) else (
      sc config vdservice binPath= "\"%TARGET%\vdservice.exe\"" start= auto
      if errorlevel 1 exit /b 1
    )
    powershell -NoProfile -Command "$ErrorActionPreference='Stop';Start-Service vdservice;(Get-Service vdservice).WaitForStatus('Running',[TimeSpan]::FromSeconds(15))"
    if errorlevel 1 exit /b 1
    echo ARM64 clipboard service installed. Enable Shared Clipboard in Lumen and restart the VM.
    exit /b 0

    """#.replacingOccurrences(of: "\n", with: "\r\n")
}
