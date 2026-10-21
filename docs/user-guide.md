# User guide


A native SwiftUI VM manager for Apple Silicon, with a translucent library and sparse disks that allocate SSD space as guests write data. macOS and compatible ARM64 Linux guests use Apple's Virtualization framework. Windows 11 ARM uses QEMU with HVF and remains experimental.

The [feature audit](feature-audit.md) compares the current implementation with the requested Parallels/VMPal-style features and records remaining work. Lumen does **not** currently provide Parallels-level Windows 3D graphics, file clipboard/drag-and-drop, snapshots, or Parallels import.

The [Windows graphics integration status](windows-3d-integration.md) records the experimental 3D stack and the validation needed before it can be offered. Run `bash scripts/release-audit.sh` to see why the current local build is not a standalone production release.

## Build and open

Requires Apple Silicon, macOS 14+, and current Xcode or Command Line Tools. Windows additionally needs QEMU with Cocoa/HVF and ARM64 EDK2 firmware; TPM 2.0 needs swtpm.

```sh
brew install qemu swtpm python@3.14
# Builds the app and prepares the compact ARM64 driver disc once (~3.4 MB).
bash scripts/build.sh
open build/Lumen.app
```

The preparation script reads the official versioned VirtIO ISO over HTTPS byte ranges, fetches ARM64 drivers only, and preserves their original catalogs and license. The build prepares `.runtime/WindowsDrivers.iso` if missing and includes it in every app bundle. You can instead choose your own VirtIO driver ISO in VM Settings. The driver ISO is attached read-only and shared between guests rather than duplicated per VM. Windows installs its driver packages inside each guest disk.

The build signs the app locally with virtualization entitlements. This is not a notarized distribution. QEMU and its dependencies occupy additional host space beyond the app itself.

```sh
bash scripts/check.sh
```

## Create and configure

Click **+** or Command-N. Choose an OS/catalog entry and select an Apple Silicon IPSW or ARM64 UEFI ISO. Catalog entries describe available images; they are not a claim that every distribution has been boot-tested. Intel-only media is rejected when detected.

Configure CPU/RAM within the host headroom budget, sparse disk capacity, display resolution, devices and optional sharing. Settings apply on the next start. Disks can grow but cannot shrink; extend the guest partition/filesystem after increasing capacity. Existing machine metadata remains backward compatible.

When removing a machine, **Move to Trash** retains the disk's SSD usage until Trash is emptied. **Delete Permanently…** asks for a second confirmation and deletes that VM's disk immediately. Your original installer ISO stays at its original path.

New machines start after creation by default; clear **Start after creation** to configure without booting. Existing machines start when Lumen opens, within its memory budget. Turn this off under **Virtual Machine → Start Machines When Lumen Opens**, or in Library options. Demo and diagnostic launches never auto-start the real library. Settings can be reviewed while running; saving hardware changes requires shutdown.

Each running macOS or Linux VM has its own app process and OS icon in the Dock. Lumen keeps its separate library icon. Closing a VM window leaves the guest running; click its Dock icon to reopen it. Shut down from the VM menu or Lumen's library to close that guest's app. Native guests reuse the signed Lumen executable and resources, without copying an app bundle for each VM. A runtime disk lock prevents opening the same native VM twice or changing/deleting it while it runs.

Use **Boot from installer** for an explicit installer boot, and **Eject installer** after installation. The current automatic boot preference uses allocated disk bytes as a heuristic; use these explicit controls if it guesses incorrectly. It does not reliably detect installation completion.

## Linux guest tools and shared-folder file transfer

With Shared Clipboard enabled, Linux guest windows support **Edit → Copy/Paste** and **Command-C/V**. Abyss defaults to **Edit → Use Terminal Copy/Paste Shortcuts**, which sends Control-Shift-C/V for terminals such as st. Turn that option off when using Linux desktop applications, which normally use Control-C/V. **Command-Shift-V** always requests terminal paste. This shares text; it does not implement file clipboard.

Linux VMs started with the updated app receive a small read-only `lumentools` VirtioFS share. Open Terminal inside Linux, choose **Install / Repair Linux Guest Tools…**, then **Type in Guest Terminal** (US guest keyboard layout required). This types the command without requiring an existing shared clipboard; sudo still asks for your Linux password. You can instead copy/type the command yourself. It installs `spice-vdagent` and D-Bus through apt, dnf, pacman, xbps or zypper, starts the system daemon and the agent in your current X11 desktop, and mounts configured Mac folders at `/mnt/lumen`. Void/runit services are enabled and checked. Minimal dwm/startx sessions receive a startup hook without replacing their existing configuration; XDG autostart is also installed. A **Lumen Mac Folders** shortcut points to the mounted share. No Mac folders are exposed until you select them in the VM settings. System setup logs to `/var/log/lumen-guest-tools.log`; desktop agent errors go to `~/.config/lumen/clipboard.log`. Native Wayland clipboard and Linux 3D acceleration are not provided by these tools.

**Send Files to Shared Folder…** copies selected files/folders into an existing writable share for Windows, Linux or macOS. You can also drop files on a VM's library row, on a native guest window, or on the Windows QEMU window. Lumen asks which writable folder should receive them. Read-only destinations, duplicate names, symbolic-link sources and self-copying folders are rejected; copies are staged and published with an atomic no-overwrite operation. Open the shared folder in the guest to use the files, or open the same folder on the Mac to receive guest-created files. This is shared-folder transfer, not arbitrary guest-desktop drag/drop or a file clipboard protocol. Installed Windows/Linux drag UI acceptance remains pending.

## Windows ARM64 drivers and Retina

The bundled ARM64 VirtIO disc includes **NetKVM** networking and **viogpudo** display drivers, plus device drivers. Windows starts with a compatibility framebuffer so Setup is visible before display drivers exist. The helper media attempts networking/display driver loading in Windows PE and stages device drivers in the specialize pass. New VMs run a protected readiness task after first login and at subsequent startup/login, using the current host-generated setup configuration before Lumen switches to VirtIO graphics. This lets an interrupted handoff retry after restarting Lumen. The complete fresh-install handoff still needs guest acceptance testing. Existing recovery-mode guests can use **View → Enable Retina Display After Installing Drivers…**. Installed Windows has separately demonstrated working 2560×1600 output and 200% scaling. Requirement bypasses remain optional; they do not provide Secure Boot or certify the VM.

For an already installed Windows VM:

1. Restart it using the updated Lumen app to attach the new helper/driver discs.
2. Log in to the Windows desktop. Choose **Devices → Install / Repair Windows Drivers…** in the guest menu, or the same action in Lumen's machine menu. Lumen reattaches the tool/driver discs and opens an elevated installer using Windows Run; approve Windows' administrator prompt. A US guest keyboard layout is required. Alternatively, open **LUMENSETUP → lumen → install-drivers.cmd** in File Explorer and **Run as administrator**.
3. Check `%TEMP%\Lumen-drivers.log` and Device Manager; restart Windows if requested. If **Compatibility display** is enabled, use **View → Enable Retina Display After Installing Drivers…** after the driver is staged. Older guests start with this recovery display so the installer stays visible.
4. Choose **2560×1600** in Lumen settings and **200%** scaling in Windows Settings → System → Display for a Retina window around 1280×800 Mac points.

Windows enforces driver signatures. Lumen never enables test signing. Higher pixel resolution plus guest scaling provides sharp, readable text; stretching a low-resolution framebuffer does not. The graphics resize service is installed automatically. Its display-control workaround can add one normal restart during boot, then clears the temporary flag to preserve compatibility recovery. Live Windows tests confirmed automatic resizing at the Mac's 2× backing scale, arbitrary window shapes, and full-screen output at 3600×2262. Moving the pointer to the top edge reveals the native menu and exit controls. Presets include 5K, but that is not a claim of tested 5K guest support or Direct3D acceleration. The current Windows path is 2D/display-only.

TPM state persists in the VM's `TPM` directory and must travel with it. Disabling/removing it can affect BitLocker or Windows Hello. The tested HVF profile disables QEMU's physical-presence interface because its 4 KiB mapping fails on this Mac's 16 KiB pages; the TPM command interface remains present. Standard QEMU ARM firmware does not provide Secure Boot.

Windows settings support TCP/UDP forwarding from **127.0.0.1** on the Mac to guest ports. The guest needs a working network driver and firewall permission. Ports already in use fail at QEMU startup; rules apply on the next start.

Windows folder sharing is managed by Lumen: select multiple folders, with a separate read-only setting for each. Its authenticated, signed SMB2 server binds only to Mac loopback and is forwarded into that VM’s private network. No macOS File Sharing configuration or Mac password is required. Windows text clipboard transport and an ARM64 guest agent are bundled; live bidirectional clipboard validation is pending. File drag/drop and printer sharing are not implemented.

## Windows guest menus

Windows runs as **Lumen VM**, with its VM name in the Dock. The temporary application wrapper shares the existing QEMU executable through a hard link when possible; Lumen never modifies or re-signs Homebrew's binary. A cross-volume fallback copy is removed when the guest exits.

- **Virtual Machine:** pause/resume, Ctrl-Alt-Delete, immediate restart, shutdown/force stop, start/shut down all, Finder/log access and CPU speed limits.
- **View:** native full screen, fit-to-window, optional smoothing, Windows display settings and PNG screenshots. Smoothing stretched pixels does not create Retina detail.
- **Devices:** driver installation, shared-folder connection, Device Manager, network settings, keyboard/mouse release and separate installer/driver/setup-tool disc menus. Eject/insert affects this running session; use library settings to change the saved installer reference. Locked media reports an error rather than forcing eject.
- **Help:** bundled driver/Retina guidance, compatibility information and engine documentation.

Driver staging during new Windows Setup remains automatic. Menu actions that open Windows tools require a logged-in desktop; Lumen cannot detect login readiness or bypass UAC. Driver success is reported by Windows, not inferred from typing the launcher command.

## Installer selection and Windows folders

Drop an ISO or IPSW onto the library or new-machine wizard, or use Browse. The wizard detects the guest and keeps the selected filename visible in every settings tab. If creation is disabled, the footer explains what is missing. Installer and folder pickers open as sheets attached to the wizard.

Choose **Sharing & Devices → Add folders…**; the picker accepts multiple folders, and folders can also be dropped onto that card. Save and restart the VM. New Windows installations register Lumen Tools during Setup; existing installations can use **Devices → Install / Repair Windows Drivers…** once. At sign-in, the tools connect the selected folders and create **Lumen Mac Folders** on the Windows desktop. **Devices → Connect / Open Shared Folders…** also connects immediately from a logged-in desktop. Networking and the ARM64 network driver must be enabled.

The Windows endpoint is `\\10.0.2.4\`; each VM has a random account stored with mode 0600 in its bundle. Only selected folders are exposed, and read-only access is enforced by the server. macOS must still allow Lumen/Python to read protected folders such as Desktop. The server stops with its VM, leaves Mac sharing/accounts/firewall unchanged, and is not advertised on the local network. The project build packages Impacket 0.13.1 and hash-pinned dependencies; the current runtime requires Homebrew Python 3.14. This is an experimental integration, not a notarized standalone distribution.

## Linux and macOS integration

- Native guest windows, keyboard/pointer and configurable resolution with optional automatic resizing.
- NAT internet when networking is enabled.
- Multiple virtiofs shared folders with separate read-only controls; macOS guests use Apple's automount tag. With multiple folders, their names appear inside the shared mount.
- Linux text clipboard via `spice-vdagent` in the guest. macOS clipboard needs additional tools and is not implemented.
- Independent speaker and microphone configuration. macOS asks for microphone permission when needed.
- Balanced disk mode uses `fsync`; Maximum safety uses full synchronization; Fastest disables flushes and risks data loss on host failure.

For Ubuntu/Debian clipboard and folder sharing:

```sh
sudo apt update && sudo apt install spice-vdagent
sudo mkdir -p /mnt/lumen
sudo mount -t virtiofs lumen /mnt/lumen
```

## Resource limits and login helpers

The memory budget leaves 25% of host RAM (4–16 GiB) and 1–2 CPU cores as configuration headroom. This is a budget, not dedicated reserved RAM or a guarantee about macOS memory pressure. Start All respects the memory budget; Stop All requests guest shutdown. Sleep/wake notifications attempt to pause/resume previously running guests, but cannot guarantee completion before macOS sleeps.

Touch ID login stores newly saved guest passwords in the macOS Keychain with user-presence access control. Existing credentials should be saved again to gain the new protection. Focus the guest's password field before unlocking. Automatic typing supports printable ASCII passwords with a US guest keyboard layout; it does not recognize a login screen or support arbitrary keyboard layouts. Local builds use ad-hoc signing, so Keychain prompts/access can change after rebuilding.

## Storage and compatibility

A 64 GiB sparse disk is a capacity limit, not 64 GiB reserved on the SSD. Guest writes allocate blocks; deleting guest files may require TRIM or compaction before the host reclaims them. Snapshot/clone accounting is not implemented. The live library counter currently reports disk-image blocks, not total firmware, logs, runtime or installer storage.

Arch, Void and board-specific ARM distributions may need prepared UEFI images. Android and ChromeOS are not implemented. See [compatibility](compatibility.md) and [validation evidence](validation.md).

## Local diagnostics

These boot read-only media using a disposable sparse VM, capture guest output, exercise pause/resume/stop, and remove the temporary VM after it exits. They do not install an OS or validate installed drivers.

```sh
open -n -W build/Lumen.app --args \
  --windows-boot-test /absolute/path/to/windows-arm64.iso \
  --boot-compatibility-display \
  --boot-wait 120 --boot-snapshot /absolute/path/to/windows.png \
  --smoke-report /absolute/path/to/windows-report.json

open -n -W build/Lumen.app --args \
  --boot-test /absolute/path/to/ubuntu-arm64.iso \
  --boot-wait 180 --boot-memory 8 \
  --boot-snapshot /absolute/path/to/ubuntu.png \
  --smoke-report /absolute/path/to/ubuntu-report.json
```

Reports deliberately separate lifecycle success from visual guest-boot verification. Omit `--boot-compatibility-display` only to investigate the unverified VirtIO-only installer path. `--smoke-test` exercises native EFI without an OS. `--demo --snapshot /absolute/path/to/library.png` captures a separate preview library whose fixtures cannot run.

Windows installations offer **Use a local Windows account during installation**, enabled for new machines. This emits Microsoft’s `HideOnlineAccountScreens` OOBE setting while leaving username/password creation interactive. Existing machine settings retain their earlier account behavior. Acceptance on build 26300.9457 is pending a new installation.

Windows installation defaults now use the host performance-core count within the CPU budget (8 vCPUs on the 12-core M4 Pro). Setup Dynamic Update is disabled so installation uses the selected ISO without download delays. Balanced storage preserves guest flushes; Maximum safety additionally flushes the SSD hardware cache. No full-install time improvement has been measured yet.

New Windows VMs install using the compatibility framebuffer, then automatically switch to VirtIO graphics after first-logon tools verify the display package and graphics service. A private per-launch receipt triggers one normal shutdown/relaunch; it does not enable Mac File Sharing. ARM64 drivers run during Setup and again automatically at first logon. Existing VMs retain their saved graphics mode. Explicit recovery mode stays at 800×600.
