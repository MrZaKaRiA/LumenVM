# Guest compatibility and storage

Lumen targets Apple Silicon and ARM64 guests. macOS and Linux use Apple Virtualization; Windows uses QEMU + HVF and remains experimental. A build or running vCPU is not evidence of installed guest compatibility. See [the feature audit](feature-audit.md) for the comparison with the reference screenshots.

| Guest | Installer | Practical limits |
| --- | --- | --- |
| macOS | Compatible Apple Silicon IPSW | Apple's framework validates the hardware model; Intel installers do not apply. IPSW installation has not been tested in this review. |
| Ubuntu, Debian, Fedora and other Linux | Generic ARM64/AArch64 UEFI ISO | Requires compatible VirtIO devices. Catalog presence is not proof of a completed boot/install test for each release. |
| Arch / Void / board-specific Linux | Prepared ARM64 UEFI media | Rootfs archives, Raspberry Pi and Asahi images are not drop-in generic VM installers. |
| Windows 11 ARM64 | ARM64 ISO and ARM64 VirtIO drivers | 2D display, native NVMe storage, driver-dependent networking and resize. No Direct3D acceleration. Text clipboard transport/agent bundled; live acceptance pending. |
| Android / ChromeOS | No implemented backend | Not currently supported. |

## Windows runtime

Install QEMU with Cocoa, HVF and EDK2 firmware. Lumen searches Homebrew paths and PATH; advanced defaults `qemuExecutablePath` and `qemuFirmwareDirectory` override discovery. Firmware templates include `edk2-aarch64-code.fd` and either `edk2-aarch64-vars.fd` or `edk2-arm-vars.fd`. Each VM preserves its own firmware and EFI variables.

`swtpm` supplies a real TPM 2.0 with persistent per-VM state. The HVF profile uses `ppi=off` because the tested Mac rejects the 4 KiB PPI RAM mapping. This does not disable the TPM command interface, but firmware physical-presence operations are unavailable. Standard QEMU ARM firmware does not provide Secure Boot. Optional LabConfig helper settings bypass installation checks; they do not replace those missing capabilities or guarantee installation on every Windows release.

The compact bundled driver disc contains original ARM64 NetKVM and viogpudo packages from VirtIO 0.1.302. The original catalogs are preserved, and Windows signature enforcement stays enabled. The Settings picker accepts another driver ISO without duplicating it per VM; legacy `Drivers.iso` files remain supported.

For an existing guest, choose **Devices → Install / Repair Windows Drivers…**, approve Windows UAC, and restart Windows if requested. The helper installs ARM64 display, network, input, random, serial, balloon and storage drivers, plus the publisher-signed graphics resize service and its user-session helper. New Windows installations run the same installer automatically during Setup. A startup display repair applies the firmware-adapter workaround only for VirtIO, performs a normal restart when required, then clears the temporary boot flag so the compatibility framebuffer remains available. This workaround can add one restart to a Windows boot; no guest applications are force-closed. Windows uses its built-in drivers for NVMe, USB keyboard/tablet, audio and TPM; staging additional packages does not prove every exposed platform device has a driver.

Older records default to Compatibility display to keep the screen visible while staging drivers. Choose **View → Enable Retina Display After Installing Drivers…** to shut down normally, switch to VirtIO, and start again. Use Windows Display **Scale 200%** with 2560×1600 pixels for a 1280×800-point Retina window. The installed guest has demonstrated real 2560×1600 VirtIO output with working resolution controls and 200% scaling. Automatic resizing passed at two arbitrary window sizes with actual guest pixels matching the Mac's 2× backing scale; full-screen output reached 3600×2262. Other screens may need another scale. Stretching a framebuffer cannot add detail. The VirtIO display-only driver does not provide Direct3D or host Metal acceleration.

Full-screen uses macOS auto-hide menu behavior. Top-edge pointer movement was verified to reveal the native menu and window controls, and **View → Exit Full Screen** passed. **Control–Command–F** toggles full-screen, and **Control–Option–Escape** exits; these host shortcuts are handled before guest key capture.

Windows uses QEMU user-mode NAT. Optional TCP/UDP forwarding listens only on Mac localhost. Selected Windows folders use Lumen’s private, authenticated and signed SMB2 server, forwarded only into that guest at `10.0.2.4:445`. Multiple folders and per-folder read-only enforcement are supported. macOS File Sharing, LAN publication and Mac account passwords are not used. Homebrew Python 3.14 and the bundled hash-pinned runtime are required. New Setup registers the user-session connection helper; existing guests can run Tools repair once or connect from the Devices menu. Sound and microphone are separate device settings. Installed guest audio and network behavior still need acceptance testing.

## Native integration

macOS and Linux VMs run in separate instances of the signed app, each with an OS Dock icon and guest window. The library uses its own process and Lumen icon. Private inherited pipes carry fixed pause/resume/shutdown/show/tools actions and runtime status. A kernel-held runtime lease prevents concurrent native starts, configuration writes and disk growth/deletion. Closing the guest window leaves it running; its Dock entry reopens the window. Guest shutdown removes that app's Dock entry. If the library crashes, the guest remains accessible from its own Dock entry; automatic reconnection to a relaunched library is not implemented. This process path has live Abyss Linux coverage; macOS IPSW installation in the new process path still needs acceptance testing.

Apple guests use configurable displays, keyboard/absolute pointer or Mac trackpad devices, optional audio input/output, NAT and virtiofs. Automatic resizing is enabled only when the saved setting requests it. Linux X11 text clipboard requires both spice-vdagentd and a per-user spice-vdagent. Lumen Tools installs them, enables D-Bus and the daemon under systemd or Void/runit, and starts the desktop agent immediately. Abyss/dwm receives an idempotent startup hook. Bidirectional text clipboard passed in the user's installed Abyss guest on October 20. Native Wayland clipboard is not supplied by this X11 agent. macOS clipboard requires guest tools that Lumen does not yet implement.

Balanced disk mode uses `fsync`, Maximum safety uses full synchronization, and Fastest disables synchronization. The latter can corrupt a reusable disk if the host fails or runs out of space. Full synchronization is stronger but can be slow during package installation.

Resource limits provide configuration headroom for macOS; they do not reserve dedicated RAM or guarantee smoothness under all host workloads. Sleep/wake handling attempts guest pause/resume rather than providing a host sleep barrier.

## SSD behavior

`ftruncate` creates a sparse raw disk without allocating its full capacity. Actual block use grows as the guest writes data. Firmware, drivers, logs, installers and QEMU runtime dependencies consume additional host space. The library counter currently measures disk-image blocks only.

Grow disks while stopped, then extend guest partitions/filesystems. Shrinking is rejected. Guest deletion does not always immediately return host space; reclamation needs guest discard/TRIM support or future compaction. Snapshots and clones are not implemented.

## Primary references

- [QEMU HVF and emulation](https://www.qemu.org/docs/master/system/introduction.html)
- [QEMU TPM](https://www.qemu.org/docs/master/specs/tpm)
- [VirtIO ARM64 package definitions](https://github.com/virtio-win/kvm-guest-drivers-windows/blob/master/win11_arm64.ddf)
- [UTM guest installer fallback display repair](https://github.com/utmapp/spice-nsis/blob/main/win-guest-tools.nsis)
- [Microsoft PnPUtil return codes](https://learn.microsoft.com/en-us/windows-hardware/drivers/devtest/pnputil-return-values)
- [Microsoft Windows ARM64 ISO guidance](https://learn.microsoft.com/en-us/windows/arm/iso)
- [Apple display reconfiguration](https://developer.apple.com/documentation/virtualization/vzvirtualmachineview/automaticallyreconfiguresdisplay)
