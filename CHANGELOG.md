# Changelog

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
