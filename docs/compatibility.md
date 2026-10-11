# Guest compatibility and storage

Lumen is an initial native macOS VM manager. Its Apple Virtualization backend targets macOS and ARM64 Linux. Windows uses an optional QEMU backend and is experimental. A successful build is not a completed guest compatibility test: actual installers, guest networking, graphics and storage reclamation need testing on the target Mac.

## Apple silicon and operating systems

An M4 Pro can hardware-virtualize compatible ARM64 guests. Running an x86 operating system requires CPU emulation, which is a separate, slower path; Lumen does not implement it. QEMU documents both hardware virtualization through HVF and software CPU emulation through TCG. [QEMU accelerators](https://www.qemu.org/docs/master/system/introduction.html)

| Guest | Lumen path | Image and practical limits |
| --- | --- | --- |
| macOS | Apple Virtualization | A compatible Apple silicon IPSW restore image. The framework checks whether its hardware model is supported by this host. Intel macOS installers do not apply. |
| Ubuntu & Linux (20+ distros) | Apple Virtualization | Choose from the built-in catalog or provide a generic ARM64 UEFI installer ISO. Lumen inspects ISO9660 volume labels and EFI bootloaders (`BOOTAA64.EFI`) to detect distributions and reject x86_64 ISOs. Disk sync mode `.balanced` prevents `F_FULLFSYNC` installer freezes. [Canonical ARM downloads](https://ubuntu.com/download/server/arm) |
| Debian | Apple Virtualization | Use an ARM64 installer, with the desired desktop selected during installation. Debian publishes ARM64 installation images and documents UEFI support. [Debian installers](https://www.debian.org/releases/stable/debian-installer/index.html) |
| Arch Linux ARM | Advanced, Apple Virtualization | Arch Linux ARM generic AArch64 download is a root filesystem tarball. Prepare an ARM64 UEFI bootable image with VirtIO drivers first. [Generic AArch64 instructions](https://archlinuxarm.org/platforms/armv8/generic) |
| Void Linux | Advanced, Apple Virtualization | Generic ARM64 UEFI images are supported. Platform-specific SBC images (Raspberry Pi, Asahi) are not drop-in VM installers. [Void downloads](https://voidlinux.org/download/) |
| Other Linux | Apple Virtualization | Requires ARM64 UEFI boot and VirtIO storage, network and graphics drivers. |
| Windows 11 ARM64 | QEMU + HVF with Setup Bypass | Microsoft publishes ARM64 ISO media. Lumen automatically provides `LumenSetup.iso` with unattended `LabConfig` registry bypasses to skip TPM 2.0 and Secure Boot checks, enabling normal installation on Apple silicon. [Microsoft ARM64 ISO guidance](https://learn.microsoft.com/en-us/windows/arm/iso) |
| Android | Not implemented | Android can run on Apple silicon through Google's Android Emulator with ARM64 system images. [Android acceleration requirements](https://developer.android.com/studio/run/emulator-acceleration) |
| ChromeOS | Not implemented | ChromeOS Flex does not support ARM. [Google's ChromeOS Flex comparison](https://support.google.com/chrome/a/answer/11542901?hl=en) |

## Windows backend

QEMU is optional and is not downloaded or bundled. The backend looks for `qemu-system-aarch64` in `/opt/homebrew/bin`, `/usr/local/bin` and the application's `PATH`. The installation must include Cocoa display support, HVF, and `edk2-aarch64-code.fd` plus `edk2-arm-vars.fd` under its `share/qemu` directory. Advanced overrides are the application defaults `qemuExecutablePath` and `qemuFirmwareDirectory`.

The implementation starts a real QEMU process with hardware acceleration, a separate Cocoa window, USB keyboard and absolute pointer, an NVMe disk and outbound user-mode networking. Persistent EFI variables and a pinned copy of its firmware are stored alongside the VM. QMP provides pause, resume, shutdown requests and force stop. Each VM folder contains `qemu.log` and, after another launch, `qemu-previous.log`.

### Windows 11 Setup bypass and enhancements:

- **TPM 2.0 & Secure Boot Bypass**: Apple's Hypervisor framework (`HVF`) does not currently support mapping the MMIO region required by QEMU's `tpm-tis-device` (`HV_BAD_ARGUMENT 0xfae94003`). Lumen overcomes this by automatically generating a virtual helper media `LumenSetup.iso` mounted as a secondary USB CD drive. It includes `autounattend.xml` setting `LabConfig` registry bypasses (`BypassTPMCheck`, `BypassSecureBootCheck`, `BypassCPUCheck`, `BypassStorageCheck`, `BypassRAMCheck`, and `BypassNRO` for offline setup), allowing standard Windows 11 ARM ISOs to install without hardware blocks.
- **Display Resizing**: Launched with `-display cocoa,zoom-to-fit=on`, allowing free window resizing and scaling to eliminate tiny, unreadable installer text on high-DPI Retina screens.
- **Audio Output & Microphone**: CoreAudio duplex is attached via `intel-hda` and `hda-duplex`, allowing guest audio playback.
- **Memory Ballooning**: Attached via `virtio-balloon-pci` to optimize host and guest memory coordination.
- **Internet & Drivers**: NAT virtual Ethernet is configured. For network connectivity, place an ARM64 VirtIO driver ISO named `Drivers.iso` in the VM folder while stopped. The helper media includes `install-drivers.cmd` to assist driver installation.
- **Shared Folder Script**: The helper media provides `Connect Mac Shared Folder.cmd` to assist connecting to host file shares.
- **Licensing**: Windows licensing remains separate.

## Smooth input, display, networking, and host stability

For Linux and macOS, the native backend uses Apple's Virtualization framework:
- **Input & Display**: USB tablet device provides smooth absolute pointer tracking. Configurable display resolutions (1080p, 1200p, Retina 1600p, 4K) or dynamic auto-resize for supported environments.
- **Disk I/O Stability**: On APFS host storage, `synchronizationMode: .full` forces `F_FULLFSYNC` barriers on every guest write. During Linux package installation, `dpkg` calls `fsync()` repeatedly, causing extreme latency and triggering "Install RELEASE Is Not Responding" watchdog alerts. Lumen's `.balanced` and `.fastest` modes use `VZDiskImageSynchronizationMode.none`, which keeps host SSD writes fast and prevents installer freezes.
- **Folder Sharing**: Host folders can be shared with read/write or read-only permissions via VirtioFS. A one-click copy button in the guest window toolbar copies the mount command (`sudo mkdir -p /mnt/lumen && sudo mount -t virtiofs lumen /mnt/lumen`).
- **Host Resource Safeguards**: Lumen reserves 25% of system RAM (between 4 and 16 GiB) and 1–2 CPU cores for host macOS. This guarantees that host macOS responsiveness, apps, and window server remain smooth even under heavy virtual machine workloads.
- **Simultaneous VMs**: Users can launch multiple virtual machines simultaneously using the **Start All** action, bounded by the host memory safety budget.

## SSD usage

The disk capacity selected in Lumen is a maximum logical capacity. `ftruncate` creates a sparse RAW image without preallocating that capacity. The library measures the file's physically allocated blocks separately, so a newly created 64 GiB virtual disk does not reserve 64 GiB of SSD space. An OS installation, updates and guest files allocate real blocks as they are written.

Disks can be grown at any time through the VM Settings sheet, but destructive shrinking is rejected to protect guest file systems. Deleting files inside a guest may not immediately reclaim host blocks without TRIM/discard. Keep adequate free space on the host SSD.
