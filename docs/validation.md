# Validation — 12 October 2026

## Build and regression tests

The release build produces `build/Lumen.app`, locally signed with virtualization and hypervisor entitlements. The nested QEMU helper is also signed. `codesign --verify --deep --strict` passes.

`bash scripts/check.sh` passes **24 tests**. Coverage includes sparse allocation/overwrite protection, disk growth and overflow bounds, identity and configuration persistence, symlink rejection, unsupported media, ISO label/architecture detection including a boot descriptor before the primary descriptor, legacy defaults, Windows driver/helper XML and quiet execution, batch-name escaping, port rules, rejection of unmappable password characters, fixed Windows menu launcher commands, local installer/folder validation, legacy Mac SMB share matching, multiple-folder migration/permissions/naming, and private Windows connection/startup helpers.

No credentials were saved or retrieved to test Keychain behavior. Touch ID and guest password injection need explicit interactive acceptance testing.

## Driver disc

`scripts/prepare-windows-drivers.py` fetched 34 files (about 3.2 MiB before ISO overhead) from the official versioned VirtIO 0.1.302 ISO over HTTPS byte ranges. The resulting `.runtime/WindowsDrivers.iso` is about 3.4 MB. The ISO contains ARM64 NetKVM and viogpudo packages plus other device drivers, original catalogs/license and a provenance manifest with per-file SHA-256 hashes.

PE headers of downloaded executable files were checked for ARM64 (`0xAA64`). Inspection of the viogpudo catalog showed the Microsoft Windows Hardware Compatibility Publisher certificate and its Microsoft issuer. This certificate inspection is not a substitute for Windows verifying the driver catalog and accepting installation. No test-signing policy was enabled.

## Actual Ubuntu live boot

The user-provided `ubuntu-26.04.1-desktop-arm64.iso` booted read-only with four CPUs, 8 GiB RAM and a temporary 64 GiB sparse disk. The current screenshot, `build/ubuntu-review.png`, shows the graphical Ubuntu installer on its account page. Start, pause, resume and force stop passed. The disk allocated zero blocks and the temporary machine was removed. Report: `build/ubuntu-review-report.json`.

Earlier graphical live boots and screenshots remain in `build/ubuntu-desktop.png` and `build/ubuntu-desktop-report.json`. These are live-media tests, not installed-system I/O, clipboard, network or TRIM tests.

## Actual Windows boot and TPM

The supplied `Windows11_Client_arm64_en-us_26300_9457.iso` was booted read-only using the release app, QEMU 11.1.2 + HVF, four CPUs, 8 GiB RAM and a temporary 64 GiB sparse disk.

- QEMU's default TPM PPI mapping aborted with `HV_BAD_ARGUMENT` on this Mac. A focused paused hardware test passed with `tpm-tis-device,ppi=off`, and QMP reported a real emulator-backed TPM. The production profile uses that setting.
- With the VirtIO-only display, QMP control and framebuffer capture worked, but the visible image remained at the firmware screen. Loading the display driver in Windows PE was added; this has **not** yet demonstrated a working VirtIO-only installer display. That path is not marked ready.
- **Compatibility display reached visible Windows 11 Setup**, shown in `build/windows-compatibility-setup.png`. QMP reported the TPM and bundled driver disc. Start, pause, resume and force stop passed; the temporary machine was removed. Its disk allocated only 16 KiB during the live boot. Report: `build/windows-compatibility-report.json`.
- The compatibility screenshot is **800×600 firmware output**, despite the configured VirtIO target of 2560×1600. It is not evidence of Retina Windows output. Compatibility mode is now the default for new and legacy Windows guests so drivers can be installed/staged visibly before selecting VirtIO.
- Diagnostic Space key presses accepted boot prompts and also appeared as an invalid character in the interactive product-key page. No product key was supplied, no target disk was selected, and no Windows installation was automated.
- One long observation report includes a large wall-clock gap; do not use these runs as boot-time or performance benchmarks.

The harness conservatively leaves `guestOSBootTested: false` and asks for screenshot review. Visual confirmation above is separate from that automatic report flag.

## Installed Windows follow-up

The existing Windows 11 ARM installation was booted using its original disk, firmware and persistent TPM state. Switching the diagnostic launch from the compatibility framebuffer to VirtIO produced a real **2560×1600** desktop. Windows reported the Red Hat VirtIO GPU DOD controller as started, with `viogpudo.inf` / `oem2.inf`, version `100.103.104.30200`, signed by Microsoft Windows Hardware Compatibility Publisher. Evidence: `build/windows-driver-resolution.png`.

The bundled installer was run as administrator inside this installed guest. It staged the eight ARM64 driver packages and installed the previously missing `vgpusrv` graphics service with `viogpuap.exe`. Publisher signature checks passed. After a normal Windows restart and a clean VM launch, Windows reported `vgpusrv` as Running / Automatic and `viogpuap` running in the user session. Evidence: `build/windows-driver-install-log.png` and `build/windows-display-topology.png`.

Windows Display Settings initially remained blank/disabled because an inactive Microsoft Basic Display adapter was registered ahead of the active VirtIO screen. Suppressing the duplicate firmware fallback through `GraphicsDrivers\BasicDisplay\DisableBasicDisplayFallback` restored both controls after reboot. The actual Windows UI was set to **200% scaling at 2560×1600**, with sharp text (`build/windows-retina-200.png`). Windows signature enforcement and the BasicDisplay service remain enabled. Dynamic host-window resizing was verified in the subsequent unlocked-host test below. Several ACPI platform devices remained without drivers; successful package staging is not a claim that Device Manager is free of errors.

A subsequent RAMFB recovery test with fallback suppression enabled stalled at the firmware image and did not respond to normal shutdown requests. The diagnostic process was stopped after those requests failed, then Windows recovered using its original disk/TPM with VirtIO. A SYSTEM startup task was then verified to restore a deliberately removed flag and return success (`build/windows-startup-task-verified.png`). Testing showed that recovery must not depend on this task running with fallback suppressed. The final task therefore clears the temporary flag once VirtIO has booted with it; the loaded display topology is retained. A subsequent VirtIO boot can add one normal restart. The final installer completed repeated live repairs without warnings (`build/windows-final8-installer.png`), refreshed five persistent repair files and its public desktop launcher, and cleared the temporary flag (`build/windows-recovery-flag-cleared.png`). The display package returned 259 when already current; the installer now handles that documented result separately from failures and logs every package return value. The clean compatibility boot now passes with the refreshed desktop repair launcher visible (`build/windows-compatibility-final.png`). The final Retina boot retained **2560×1600 at 200% scaling** (`build/windows-retina-final-settings.png`); opening the resolution menu showed multiple selectable modes (`build/windows-resolution-options.png`). The final startup task returned 0, the temporary registry value was absent, and the graphics service was Running / Automatic (`build/windows-final-startup-cleanup.png`).

Full-screen exit via Control–Command–F and Control–Option–Escape passed in the real guest window. The helper now requests macOS auto-hide presentation rather than hiding the menu bar unconditionally. After unlocking the host, actual top-edge pointer movement revealed the native menu and window controls; **View → Exit Full Screen** passed (`build/fullscreen-final-top-edge.png`). The menu report confirmed full-screen presentation options 1029 (full screen plus auto-hide menu and Dock).

The final diagnostic Windows session shut down normally and QEMU exited with status 0. Its existing machine configuration was backed up and saved with compatibility display disabled and a 2560×1600 target; its identity, disk and TPM were retained. The original Lumen process remains open with the Ubuntu session and its older in-memory configuration. Relaunch the rebuilt app after saving that session to load the verified Windows display settings.

## Unlocked-host Windows resizing follow-up

With automatic resizing enabled, native windows initially retained QEMU's firmware framebuffer aspect ratio. The helper now clears that constraint in automatic mode and leaves fixed-resolution sizing with QEMU. Live checks with the final helper accepted **1100×750** and **1250×850** outer window sizes. After the guest resize settled, framebuffer captures measured **2200×1436** and **2500×1636**, respectively: twice the content dimensions after the 32-point title bar (`build/windows-free-resize-1100-settled.png`, `build/windows-free-resize-1250-settled.png`). Full screen reached **3600×2262** (`build/windows-fullscreen-final.png`), and top-edge reveal and menu exit passed again with this final helper. Windows retained working display controls and 200% scaling after the startup repair (`build/windows-free-resize-settings.png`). External monitors, a different backing scale and 5K output were not tested.

## Remaining acceptance checks

The follow-up menu test (`--boot-menu-test`, report `build/windows-menu-report.json`) ran the actual relocated engine with HVF and a disposable sparse VM. It verified the Lumen VM bundle/process name and macOS application display name, exact six-menu inventory, driver action availability, bridge readiness, disabled driver/Pause controls and enabled Resume while paused, and eject/reinsert of both read-only tool discs by their qdev identity. Start/pause/resume/stop and temporary-machine cleanup passed. The underlying Homebrew executable was hard-linked without modification or re-signing; its resource search path was supplied explicitly after relocation. This test did not use an installed Windows desktop or invoke the Run-dialog driver launcher.

Guest internet, forwarded guest services, audio/mic, installed-Windows automatic folder startup, full Linux disk installation and reclamation still need end-to-end testing. Port syntax/validation is tested, but an actual guest server was not contacted.

macOS IPSW installation, Arch/Void/other Linux distributions, Keychain prompts and password typing were not tested. Android and ChromeOS have no backend. Windows Direct3D acceleration, snapshots, clones, live settings, file clipboard/drag-and-drop, Parallels import and native per-VM process isolation are not implemented; see the [feature audit](feature-audit.md).

## Installer wizard and private Windows folders

Actual Finder drag-and-drop of the user’s Windows ARM64 ISO opened the correct new-machine wizard with its filename visible. All three configuration tabs fit, and the missing-installer case displays a specific reason and Browse action. The folder picker opened as an attached sheet. Create saved the selected installer, folder and 96 GiB capacity in a disposable library, with **zero allocated disk blocks**. Evidence: `build/iso-drop-result.png`, `build/wizard-creation-report.json` and `build/wizard-created-machine.png`.

`PYTHONPATH=.runtime/WindowsSharing python3 scripts/sharing/test-server.py` passes authenticated/signed SMB2, Windows-style negotiation upgrade, multiple-folder enumeration, read/write/delete, read-only write/delete/rename/directory rejection, wrong/anonymous credentials, traversal and escaping-symlink checks. It uses disposable folders and a loopback listener only. Dependencies are pinned by wheel hashes in `scripts/sharing/requirements-macos-arm64-py314.txt`.

A separate disposable Windows 11 ARM64 WinPE guest loaded the bundled NetKVM driver and initialized networking. Through the exact QEMU `guestfwd` endpoint (`10.0.2.4:445` to a random Mac loopback port), Windows read a Mac-created file, created a host-visible test file, read a second folder and received **Access is denied** when writing to that read-only folder. Windows also enumerated the requested Desktop read-only; no Desktop file was modified and private filenames were not retained. Evidence: `build/PrivateSharingLive/permissions.png`. No macOS sharing, firewall or account setting changed.

This proves the Windows client and private transport, not installed Explorer/startup behavior. The PowerShell user-session startup helper is generated and covered by core tests, but needs a completed Windows desktop installation for its sign-in acceptance test. Windows/macOS clipboard, cross-VM clipboard, guest file drag-and-drop and printer sharing are not implemented.

## Installation performance and account setup follow-up

25 core tests pass, including optional local-account answer-file generation and legacy record migration. The local-account preference emits `HideOnlineAccountScreens` in `oobeSystem`; no credentials or automatic logon are generated. The previous live VM was still on Microsoft sign-in when its diagnostic console was opened. Later inspection found Lumen stopped and the machine library empty; bypass completion was not verified.

Windows text clipboard now has an opt-in QEMU vdagent transport, bundled hash-verified ARM64 upstream agents, and an automatic service installer. Installed-desktop/cross-VM clipboard acceptance remains pending. This supersedes the earlier statement that no Windows clipboard implementation exists. File clipboard, file drag/drop and printer sharing remain unfinished.

A disk-sync shim probe verified normal fsync behavior for Balanced and hardware-cache flushing for Maximum safety. The zero-write probe verified readback correctness but did not reduce APFS allocated blocks. No full Windows installation speedup has been measured.

The rebuilt app passed ad-hoc signature verification and a disposable Windows ARM64 boot using the supplied ISO. Windows reached its language-selection page. Start, pause/resume, six-menu inventory, tool-disc eject/reinsert, and temporary-machine cleanup passed (`build/account-boot-report.json`, `build/account-boot.png`). The new vdagent transport was accepted by the actual QEMU engine; guest clipboard exchange and local-account OOBE were not exercised by this boot-only test.

## Setup retry follow-up, October 14

Linux guest tools are now supplied through a read-only `lumentools` VirtioFS device alongside any user shares. The installer uses the guest's native package manager and mounts the `lumen` share at `/mnt/lumen`; its shell syntax is checked for both sharing configurations. Shared-folder file transfer rejects read-only destinations, self-copy and top-level symlinks, stages copies and publishes with `renamex_np(RENAME_EXCL)` to avoid overwriting. File-content preservation, destination collisions and staging cleanup are tested. Native SwiftUI and Windows Cocoa drop receivers ask the user to choose a writable share. These are shared-folder transfers; direct arbitrary guest desktop drops, file clipboard and installed-guest drag acceptance remain unverified.

The supplied Ubuntu ARM64 ISO reached its graphical installer language screen in a disposable Apple Virtualization VM with the new tools device, 8 GiB RAM and a 120-second observation. Start/pause/resume/stop and cleanup passed; the 64 GiB sparse disk allocated zero bytes. This confirms boot/configuration compatibility, not execution of the Linux tools installer or clipboard/drag behavior inside an installed guest. The installer action can type its fixed US-layout bootstrap command directly into an already-open guest Terminal, so clipboard setup does not depend on a working clipboard. Files already inside the selected share are accepted without creating another copy.

The display handoff previously ran only once at first login with a launch-specific receipt. Restarting Lumen before receipt delivery could leave a new guest using compatibility graphics. The readiness task now reads bounded, validated JSON from the current LUMENSETUP disc and runs protected code from Program Files at startup/login. It waits briefly for OOBE to finish and retries graphics-service startup. The first-login wrapper starts this task asynchronously, allowing Windows setup to return. Manual guest-tools repair also starts the task. A completed handoff supplies an empty configuration, causing the task to unregister itself. This code and media generation are covered by core checks, but a full installed Windows handoff remains unverified because the user's VM was deleted.

VM deletion also checks the live QEMU process independently of the displayed state, preventing deletion while a failed-labelled backend still holds the disk open. The resolution guidance distinguishes initial preset pixels, subsequent auto-resize and guest-selected DPI scaling. Earlier diagnostic images and logs were deleted at the user's cleanup request; their descriptions above record previous observations.

## Windows 800×600 repair, October 13

The user's new installation successfully skipped Microsoft sign-in. Its Machine.json and running QEMU arguments still selected RAMFB compatibility graphics. A normal shutdown through Lumen's existing display transition switched it to VirtIO; the installed desktop then reported 2560×1600 with enabled resolution controls (`build/resolution-virtio-current.png`). This proves the driver was installed and the fixed compatibility adapter caused the 800×600 limitation.

A VirtIO-first installer test remained at firmware after 120 seconds, so new machines use the compatibility framebuffer until verified first-logon driver readiness. The private per-launch receipt then triggers a normal switch to VirtIO. Legacy saved recovery settings are preserved. An elevated first-logon guest-tools command supplements the existing specialize pass. Startup display recovery now records completion and skips an extra restart when the VirtIO adapter already has a working high-resolution mode. Full fresh-install acceptance of the new first-logon path remains pending.

The final automatic-setup profile reached Windows Setup's keyboard-selection screen with the supplied ISO (`build/display-handoff-installer.png`). Start/stop and disposable-machine cleanup passed. All 26 core tests and the private SMB transport checks passed. Runtime bytecode writes were disabled and bundled Python caches excluded, fixing a discovered signature mutation; deep/strict app signature verification passed after the final VM boot. The rebuilt executable takes effect when Lumen is next relaunched; the user's running VM was left intact.


## Void/Abyss guest tools, October 20

A live test in the user's installed ARM64 Abyss guest reproduced the failed tools command: synthetic key-down flags alone turned `&&` into `77`, parentheses into digits and uppercase into lowercase. Physical Shift events also need the device-specific left-Shift mask (`0x2`). A live physical-key test with the modifier state restored all those characters. The native app injector now sends paired modifier events; passwords use the same path.

The revised VirtioFS tools bundle separates privileged package/service setup from the ordinary desktop session. In the actual guest it installed Void's `spice-vdagent` 0.22.1, found D-Bus already running, enabled/started `spice-vdagentd` under runit, and launched the per-user agent in dwm. The first run caught runsvdir's service discovery delay; waiting for supervision before calling `sv up` fixed the false failure. A repeat system/session setup returned zero. The user's existing `.dwm/autostart.sh` was preserved with a single integration hook. A controlled `xclip` check passed Mac-to-guest and guest-to-Mac text transfer; the original Mac clipboard was restored without logging its contents.

Windows repair now distinguishes unattended Setup from quiet/manual repair: missing media and component failures are returned by repair, while optional integration cannot block OS Setup. The first-logon wrapper preserves driver errors when starting the asynchronous display task. Existing third-party SPICE services are started without replacement, and stale Lumen agent workers are stopped before replacing their binaries. The user-session folder launcher selects the labelled LUMENSETUP disc. These Windows changes have generated-media/core coverage; no installed Windows guest was available for live validation this turn.

The build script selects versioned Python 3.14 for the pinned SMB runtime even when Homebrew's generic `python3` is 3.15. Lumen's library retains its app icon; native guest windows use separate non-tabbing windows, guest titlebar and minimized-window icons. Windows helper windows also disable tabbing and show their guest icon.

The final checks passed 34 core tests, the fractional-redraw renderer regression, the private SMB transport suite, `git diff --check`, and deep/strict ad-hoc signature verification. The VM shut down normally, retained its original disk/identity, and relaunched with the previously requested Mac Desktop selected. The guest titlebar OS icon and separate library/guest windows were observed. The post-login follow-up below completed the remaining checks. Completed build/test caches were removed (about 585 MiB logical); the signed app and VM were retained.


After the user logged in, both clipboard directions passed again without manually starting either SPICE component. `/mnt/lumen` was already mounted from the `lumen` VirtioFS device. A temporary script placed on the Mac Desktop was read and run as the ordinary Linux desktop user; it wrote a known receipt back to the Mac Desktop, whose exact contents were verified on the host. The `~/Desktop/Lumen Mac Folders` symlink pointed to `/mnt/lumen`, and both the system daemon and per-user agent were running. No private Desktop filenames or contents were enumerated.

The real **Install / Repair Linux Guest Tools… → Type in Guest Terminal** action typed the bootstrap correctly, including `&&`, `||` and parentheses. With the user's guest authentication, the current installer detected the existing Void packages, checked both runit services, recognized the mounted folders and desktop agent, and returned system result zero. These observations complete the native command-entry, automatic X11 clipboard startup and selected-Desktop sharing acceptance checks for this Abyss VM. Temporary Desktop test files, screenshots and the host-side diagnostic helper were removed; the running guest and its selected share were retained. Windows installed-guest and native Wayland acceptance remain outside this result.


## Native Linux paste actions, October 20

The user's follow-up exposed a gap in the previous acceptance test: transferring clipboard text with `xclip` did not test Command-V or the macOS Edit menu. The original VZ view had no Cocoa `paste:` handler and forwarded Command as Linux Super. A guest-view subclass now implements and validates native copy/paste actions and translates Mac shortcuts into Linux desktop or terminal combinations. Abyss defaults to terminal mode; other Linux guests default to desktop mode. Terminal Cut/Select All stay disabled rather than issuing disruptive control characters. Other host text responders keep their normal actions.

A real Command-V into st inserted a controlled test string, and clicking the now-enabled native Edit → Paste inserted a second controlled string. Neither string contained a newline and neither was submitted to the shell. The Mac clipboard was restored after each check. A per-VM Edit-menu toggle selects terminal Control-Shift-C/V or desktop Control-C/V, with Command-Shift-V providing explicit terminal paste. The final build exposes both Edit-menu items. After its restart and guest login, the user confirmed that copy and paste work.


The final check run passed all 34 core tests and the renderer regression. Deep/strict app signature verification and `git diff --check` passed. Live acceptance covered the actual macOS Command-V key equivalent and Edit → Paste in st, followed by the user's confirmation in the final build. Copy/paste shortcut mode is stored per VM. The Edit menu exposes **Paste into Linux Terminal** and **Use Terminal Copy/Paste Shortcuts**. Completed build caches and temporary paste-check helpers/images/logs were removed; the working guest remains running.

## Native VM Dock apps, October 20

Native guests now launch another instance of the signed Lumen app, scoped to one machine, with its OS artwork as the application icon and explicit Dock tile content. Lumen keeps the library in its own process. Command and status messages travel through inherited pipes; the child retains clipboard, shared folders, guest-tools installation, Touch ID and display controls. Guest runtime leases block duplicate native boots and configuration/disk mutation while a guest is running. The same signed executable/resources are reused without per-guest app copies.

The installed Abyss VM shut down normally and restarted in a distinct child PID with its own Virtualization XPC process. Dock accessibility exposed two independent app entries. The child’s Window menu contained its guest window; the library remained in the parent. Closing the guest window and pressing the child's Dock entry reopened the Abyss window. Pause from Lumen changed both processes' menus to Resume; Resume returned the guest to running. Shutdown from Lumen closed only the guest app, released the disk and removed its Dock entry; the library stayed open and disabled its stopped-guest controls. The rebuilt app then restarted Abyss successfully. Native guests reuse the bundle name Lumen in Dock tooltips, with separate OS tile artwork and VM window titles. Dock pixel capture was inconclusive because its tiles were outside the captured screen bounds; app/process separation and Dock reopening were verified through accessibility.

All 38 core tests passed, including fragmented/bounded control messages and exclusive lease protection/release. The renderer regression and final release compilation passed. The existing Windows path was unchanged; no Windows guest or macOS IPSW installation was exercised. Relaunched-library reconnection after a parent crash is not implemented; a surviving native guest remains controllable from its own app. Temporary probes, screenshots, logs and completed build caches were removed, retaining the signed app and the original VM.

## v27.0.1 source release

Fresh release preparation passed all 38 core tests, the fractional display-redraw regression and private signed-SMB2 transport/permission tests. Release compilation completed with both app version strings set to 27.0.1, and deep/strict ad-hoc signature verification passed. Local documentation links and plist/shell syntax were checked. Source packaging rejects mismatched versions and uncommitted work; staged source and historical text blobs were checked for common credential patterns and generated VM/runtime files.

This publication is source-only. No guest disk, installer image, downloaded runtime binary, credential file or local app bundle is included. The standalone-distribution blockers in the release audit remain documented. The user's running guest was not restarted for release preparation.

## v27.1.0 source release

Release preparation passed all 42 core tests and the fractional display-redraw regression. Release compilation completed with both app version strings set to 27.1.0, the app is signed with the hardened runtime, and deep/strict ad-hoc signature verification passed. The security hardening, QEMU/library performance changes, Rosetta, nested virtualization and macOS restore-image download were verified by build and unit tests only; no live Windows, Linux or macOS guest was exercised for this release.
