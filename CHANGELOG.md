# Changelog

## Unreleased

### Fixed

- Linux guest tools no longer break boot on distributions that run `mount -a` and stop on any error (Void/Abyss runit). The `/mnt/lumen` and Rosetta fstab entries are now `noauto,nofail`, and a small boot hook (systemd unit or `/etc/rc.local` on runit) mounts them only when the host attached the share. Re-running **Install / Repair Linux Guest Tools** repairs existing `defaults,nofail` entries (backup: `/etc/fstab.lumen-bak`).

### External disks for Windows

- Connect a whole USB stick, SD card or external drive to a running Windows (QEMU) VM as a removable USB drive, read-write or read-only. A small non-activating panel offers newly plugged-in disks to running Windows VMs; the library **Devices** menu, the VM row menu and the Windows window's **Devices → External Disks** menu connect, disconnect-and-return or disconnect-and-eject.
- DiskArbitration-based monitor lists only removable/external whole disks, never the startup disk, APFS containers or the disk holding the library, and re-checks each disk with `diskutil` before connecting. A disk can belong to only one VM at a time.
- While a VM owns a disk, macOS mount requests for it are refused, so Windows can format it without macOS grabbing the new volume. Unplugging an in-use disk detaches it from Windows and warns about possible data loss.
- Window-menu disk commands are parsed strictly (valid whole-disk name, and only disks Lumen published to that VM's menu) and always show a confirmation.
- Validation: unit tests for disk-name validation, eligibility, diskutil/DiskArbitration parsing, menu-command parsing and QMP builders; the no-guest QMP hot-plug check passes with a disk image. Not yet validated with physical hardware and an installed Windows guest. Linux/macOS guests and generic USB device passthrough are not implemented.

## v27.2.0

Source release for Apple Silicon. Adds measured sparse-disk reclamation, clearer storage accounting and disposable Linux TRIM validation. Windows remains experimental; the new reclaim path is not validated on Windows/NTFS.

### Storage

- Show maximum guest disk capacity separately from allocated host disk-image blocks, with active-VM refresh every eight seconds. Unreadable images show unavailable instead of a false zero.
- Add a cancellable **Reclaim Disk Space** action for stopped VMs. It releases only verified all-zero blocks, preserves contents and capacity, and reports measured allocation before and after.
- Extend the runtime lease to QEMU so running VMs block concurrent disk operations.
- Validate write → delete → `fstrim` using disposable Linux/ext4 guests on QEMU/NVMe and Apple/Virtio; include a repeatable validation script and report the platform limits.

### Validation

- 48 core tests and the display-redraw regression pass; release app builds and passes deep/strict signature verification.
- Disposable Linux/ext4 TRIM recovered approximately 128 MiB after deleting a 128 MiB file on both tested backends. The disk capacity and sentinel data were preserved.
- Live library checks verified measured reclamation, no-op reporting and unavailable allocation handling.
- Windows/NTFS reclamation, installed macOS guest behavior and general filesystem/host coverage remain unverified.

## v27.1.0

Source release for Apple Silicon. Security hardening, performance work and new opt-in Apple Virtualization features. Windows remains experimental; these changes have not yet been exercised against live Windows or Linux guests.

### Security

- Release builds inject only the `LumenQEMUHelper.dylib` sealed into the app's signature; working-directory, VM-bundle and runtime `clang` fallbacks are debug-only.
- Windows guest commands verify a fresh random marker on the `LUMENSETUP` disc, so a spoofed ISO with the same label is not executed.
- The Windows startup shortcut runs only `%ProgramData%\Lumen\Tools`, owned by Administrators and writable only by Administrators/SYSTEM.
- Shared-folder credentials are stored per Windows user with `cmdkey` instead of being embedded in a world-readable script.
- VirtIO driver preparation checks a committed SHA-256 manifest.
- The app is signed with the hardened runtime; the unused hypervisor entitlement is removed and audio-input is declared so VM microphones keep working.

### Performance

- QEMU receives an explicit CPU topology (one socket, N cores).
- The Windows setup ISO is reused when its staged contents are unchanged, skipping `hdiutil` on every boot.
- The library polls disk usage only while a machine is active and redraws only when values change.
- macOS install progress updates are throttled; the QEMU display helper no longer creates a color space per frame.
- Installer detection runs off the main thread.

### Apple Virtualization features

- Opt-in Rosetta for Linux guests, with guest-tools binfmt registration; Linux guest tools also enable `fstrim.timer` so sparse disks can shrink.
- Opt-in nested virtualization on supported hosts (macOS 15+, M3 or later).
- Download the latest supported macOS restore image from the new-machine flow.

### Validation

- 42 core tests and the display-redraw regression pass; the app builds and passes deep/strict signature verification.

## v27.0.1

Source release for Apple Silicon. This version consolidates the current Lumen implementation and fixes; Windows remains experimental.

### Native guest windows and Dock

- Run each macOS/Linux VM in a separate app process with an OS Dock tile, keeping Lumen's library separate.
- Reopen closed VM windows from their Dock entry; supervise state and pause/resume/shutdown through private parent/child pipes.
- Protect native VM disks and configuration with exclusive runtime leases. Reject duplicate starts and changes to running disks.

### Linux integration

- Supply Lumen Tools through a read-only VirtioFS share, with package-manager and service setup for systemd and Void/runit.
- Start SPICE system and X11 desktop agents, preserve existing dwm startup configuration and mount selected Mac folders.
- Support macOS Edit-menu copy/paste and Command-C/V, with per-VM terminal mode and Command-Shift-V terminal paste.
- Correct shifted-key injection so shell operators are typed correctly.

### Windows integration

- Prepare ARM64 VirtIO drivers and clipboard tools from pinned upstream distributions, preserving driver catalogs and licenses.
- Add driver repair and startup display-readiness tasks, Retina presets and resize controls. The current Windows graphics path remains 2D.
- Provide private authenticated SMB2 sharing for multiple selected folders without enabling macOS LAN File Sharing.
- Refine VM menus, removable-media labels, full-screen exit, installer selection and creation validation.
- Improve fractional display redraws and driver-installer error reporting.

### Storage, documentation and validation

- Keep disks sparse, support stopped-disk growth and prevent unsafe shrinking or deletion of active guests.
- Stage shared-folder transfers without overwriting existing files and enforce read-only destinations.
- Expand compatibility, user, contributor and release documentation; set the app version to 27.0.1.
- Add core coverage for guest integration, keyboard input, file transfer, bounded IPC and runtime leases. The local suite contains 38 tests plus a renderer regression.

### Known limitations

No notarized standalone installer is published. Windows needs external QEMU/firmware, `swtpm` for TPM and Python 3.14 for folder sharing. Windows Direct3D, snapshots/clones, Parallels import, file clipboard, arbitrary desktop file drops and printer sharing are not implemented. Native Wayland and macOS clipboard are not implemented. Full fresh-install Windows acceptance and macOS guest-process installation still require testing. See [compatibility](docs/compatibility.md) and [validation](docs/validation.md).
