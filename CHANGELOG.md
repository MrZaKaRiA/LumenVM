# Changelog

## Unreleased

### Storage accounting and reclamation

- Explicitly label allocated host disk-image bytes and maximum guest capacity; retain the eight-second active-VM refresh, including while a separate guest app is frontmost.
- Show unavailable allocation explicitly when an image cannot be inspected, instead of reporting a false zero or incomplete combined total.
- Add **Storage & Reclamation…** and **Reclaim Disk Space…** to the library and VM menu, with progress, cancellation and measured before/after results.
- Reclaim only verified all-zero host blocks in stopped images, preserving byte contents and capacity without copying or preallocating a second disk.
- Extend the runtime lease to QEMU so a running Windows guest also blocks disk maintenance across Lumen processes.
- Validate disposable Linux/ext4 write/delete/TRIM through QEMU/NVMe and Apple/Virtio; document Windows/NTFS and other untested paths separately.

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
