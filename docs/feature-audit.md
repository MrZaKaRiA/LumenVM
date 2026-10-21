# Feature audit — 12 October 2026

The four reference screenshots are a product target, not evidence of features implemented in Lumen. This audit covers the current source, including the newer catalog, storage, audio, host resource and Touch ID work.

## Changes made in this review

- Replace bare QEMU process/menu branding with a temporary Lumen VM application identity. Rebuild menus after QEMU finishes initialization, name the three removable drives, and use stable qdev identities for live read-only insert/eject operations. Provide driver repair, Windows settings, keyboard release, screenshots, logs and library actions through a per-launch menu bridge. Real HVF testing verified branding, bridge readiness and driver/setup disc eject/reinsert.
- Start new VMs after creation and existing machines on normal library launch by default, within the memory budget, with visible opt-out controls. Diagnostic/demo launches are excluded. The driver action opens the guest installer through Windows Run and preserves UAC; a logged-in US-layout desktop is required. Installed Windows now confirms the signed VirtIO display driver at 2560×1600, with the graphics resize service running and working 200% scaling; automatic resizing now passes at the Mac's 2× backing scale, including arbitrary window shapes and full screen.
- Bundle a compact, shared ARM64 VirtIO driver disc (0.1.302), including NetKVM, viogpudo, balloon, serial, input, random and storage drivers. The preparation script downloads only selected HTTPS byte ranges, preserves the publisher's driver catalogs and license, checks executable ARM64 headers, and records per-file hashes. It does not enable test signing. Windows remains responsible for validating driver signatures.
- Add a persistent driver ISO picker. Selected discs are attached read-only; the original per-machine `Drivers.iso` convention remains compatible. Driver media is shared rather than duplicated per VM.
- Load network and display drivers during Windows PE and install ARM64 device/display drivers during specialize. A compatibility framebuffer remains available for recovery and staging drivers in older guests. Quiet installation cannot block Setup at a `pause` prompt or fail Setup solely because an optional driver did not install. Manual installation writes `%TEMP%\Lumen-drivers.log` and reports results.
- Generate helper media even when requirement bypasses are disabled. Media creation failures are reported, and building the small ISO runs off the main UI thread.
- Configure Windows with a 2560×1600 VirtIO target and default to a compatibility framebuffer until drivers are installed. The recovery framebuffer uses firmware resolution (800×600 in the boot test). Size its Cocoa window in Mac points using the screen backing scale; retain QEMU's pixel-based display updates when auto-resize is enabled. Add a 5K resolution preset. Fixed resolution now honors the setting in both engines.
- Implement persistent per-VM TPM 2.0 via swtpm. Keep state in the VM and private control sockets in short temporary paths. Disable PPI on this HVF profile: QEMU's 4 KiB PPI RAM mapping fails on the tested 16 KiB-page Mac. TPM command processing is available; firmware physical-presence operations are not.
- Honor Windows speaker/microphone settings independently. Previously enabling speakers also exposed microphone input. Add the host microphone purpose string.
- Add TCP/UDP port forwarding for Windows QEMU guests, bound to `127.0.0.1`. Validate port ranges, duplicate endpoints and rule limits.
- Restore actual `fsync` semantics for Balanced native disk mode. It previously mapped to `.none`, despite claiming crash protection. Maximum safety uses full synchronization; Fastest explicitly disables it.
- Validate settings before growing a disk; reject overflow-sized capacities. Inspect installer contents when creating/updating, including ISO images whose boot record precedes the primary volume descriptor.
- Restore the Windows Show Display action. Restrict QEMU window branding/sizing hooks to the guest window.
- Protect newly saved Keychain passwords with user-presence access control and update existing entries without deleting them first. Never silently substitute unsupported password characters. Native injection requires the actual guest display to retain focus; closing the credential sheet precedes injection. Removing a VM also removes its saved password.

- Repair Finder installer drops, attach file panels to the wizard, keep the selected installer visible across tabs, and explain disabled creation. Add multiple folder selection and per-folder read-only controls. Windows uses a private per-VM SMB2 service instead of changing Mac File Sharing. Clipboard/files drag-and-drop and printer sharing still require separate guest tools.

## Reference feature status

| Reference feature | Current status | Work needed for parity |
| --- | --- | --- |
| Sparse growing disks | Implemented; no capacity preallocation | Guest TRIM/compaction validation and aggregate snapshot accounting |
| Retina / 5K | Resolution presets, native auto-resize, Windows VirtIO display driver path | External-display matrix and 5K hardware test; installed Windows resizing passed at 2× |
| Windows graphics | VirtIO display-only driver, Cocoa framebuffer, CPU virtualization through HVF | A Windows ARM64 WDDM 3D driver and host Metal graphics translation; this is substantial engine work |
| macOS / Linux graphics | Existing Apple Virtualization devices | Measure guest API/3D capabilities before promising OpenGL/Metal versions |
| Automatic installation | macOS IPSW installer; Windows driver/helper automation; interactive Windows/Linux Setup | Verified unattended OS-specific install profiles, image catalog/download verification, account provisioning and progress |
| Clipboard and files | Linux tools installer for spice-vdagent and VirtioFS mounts; private Windows SMB2 shares; file picker/drop into selected writable shares | Installed guest validation; arbitrary desktop/file clipboard transfer; guest-to-host drag protocol |
| Printer sharing | Not implemented; no printer currently connected for acceptance testing | Selected-queue IPP/USB integration, guest discovery, permissions and real print-job tests |
| Snapshots / clones | Not implemented | APFS clone-based disk checkpoints plus firmware/TPM/identity, safe rollback, memory state where supported, accounting and recovery tests |
| Port forwarding | Windows QEMU TCP/UDP, localhost only | A supported native guest forwarding service and live rule editing |
| Live settings | Full configuration changes require shutdown | Separate metadata changes from backend hotplug, sharing/network APIs, transactional rollback and runtime confirmations |
| Sound / mic per VM | Independent configuration in both engines | Installed guest tests, live controls and a truthful microphone-use indicator |
| One Dock app / crash isolation per VM | Windows has a branded QEMU process; each Apple guest has a separate signed Lumen process with an OS Dock icon, private command/status pipes and an exclusive runtime lease. Abyss start, library pause/resume and Dock reopening passed live. | Reattach after a library crash; installed macOS process-path acceptance and crash/recovery stress tests |
| Parallels import | Not implemented | Non-destructive ARM disk conversion, identity mapping, driver replacement, encrypted disk/TPM recovery and migration fixtures |
| Rosetta / nested virtualization | Not exposed in Lumen | Capability-gated native options, guest setup, licensing/install handling and real guest tests |
| USB passthrough | Keyboard/tablet/CD only | Device picker, hotplug, ownership and disconnect handling; Windows driver verification |

## Windows driver and sharpness workflow

For an **existing** Windows VM, reopen the updated Lumen app and restart the VM so both helper discs attach. Log in, choose **Devices → Install / Repair Windows Drivers…**, and approve the Windows administrator prompt. The launcher requires a US keyboard layout. Alternatively, in Windows File Explorer open `LUMENSETUP`, then `lumen`, and run `install-drivers.cmd` as administrator. Restart Windows if requested. Older guests default to Compatibility display; after staging drivers, use **View → Enable Retina Display After Installing Drivers…** to shut down normally and switch to VirtIO. The driver installer on the desktop may be from an older Lumen version; prefer the new disc copy.

The driver installer also registers and starts the publisher-signed graphics resize service (`vgpusrv`) with its per-session helper (`viogpuap`). It repairs blank Display Settings caused by the duplicate firmware adapter. New and existing desktop repair launchers retain their helper scripts under ProgramData and request Windows UAC. The display workaround uses a temporary boot flag and can add one normal restart, then clears the flag to preserve the compatibility screen. Full-screen exits through Control–Command–F or Control–Option–Escape; top-edge pointer movement now reveals the native menu and window controls in a live visual check.

For a **new** Windows installation, leave explicit Compatibility recovery mode off. Automatic setup still uses the working firmware framebuffer initially. First-logon tools verify the staged display package and running graphics service, then send a per-launch receipt over the private VM transport. Lumen shuts down normally and relaunches with VirtIO. This automatic handoff still needs full fresh-install acceptance testing. If Windows refuses a driver, inspect the log and Device Manager; Lumen does not relax Windows signature enforcement. Installed Windows has separately demonstrated the signed WDDM driver at 2560×1600 and 200% scaling.

For readable Retina text, set Windows **Settings → System → Display → Scale** to **200%** and use a 2560×1600 resolution in a roughly 1280×800-point window. A different Mac display may need another scale. Enlarging a 1280×800 framebuffer to fill a Retina window cannot create additional text detail. The ARM64 viogpudo driver is a display-only path, not Direct3D acceleration.

## Recommended engineering order

The current Homebrew QEMU has no 3D VirtIO graphics device. UTM's newer Triton/Neptune stack is an experimental integration candidate, documented in [Windows graphics integration status](windows-3d-integration.md). Lumen's current `viogpudo` driver remains a 2D display driver.

1. Complete installed Windows audio, network and external-display acceptance tests; extend signed guest tools.
2. Implement stopped snapshots and clones with recovery tests, then memory snapshots only where the backend supports safe restore.
3. Extend native per-VM process recovery and reconnection before adding live hardware changes.
4. Add Parallels migration and unattended install profiles with real fixtures.
5. Develop or integrate a maintained Windows ARM64 graphics translation stack and benchmark it against Parallels. Driver installation alone cannot satisfy this requirement.

## Primary references

- [VirtIO Windows source and ARM64 package definition](https://github.com/virtio-win/kvm-guest-drivers-windows/blob/master/win11_arm64.ddf)
- [VirtIO Windows release distribution](https://github.com/virtio-win/virtio-win-pkg-scripts/blob/master/README.md)
- [VirtIO graphics service requirement](https://github.com/virtio-win/kvm-guest-drivers-windows/issues/1391)
- [UTM guest installer fallback display repair](https://github.com/utmapp/spice-nsis/blob/main/win-guest-tools.nsis)
- [QEMU Cocoa display and Retina pixel-size reporting](https://github.com/qemu/qemu/blob/master/ui/cocoa.m)
- [QEMU TPM documentation](https://www.qemu.org/docs/master/specs/tpm)
- [Apple automatic display reconfiguration](https://developer.apple.com/documentation/virtualization/vzvirtualmachineview/automaticallyreconfiguresdisplay)
