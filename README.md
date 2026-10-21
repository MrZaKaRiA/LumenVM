# LumensVM

**Lumen — native virtual machines for Apple Silicon.**

[![Downloads](https://img.shields.io/github/downloads/MrZaKaRiA/LumensVM/total)](https://github.com/MrZaKaRiA/LumensVM/releases) [![Latest release](https://img.shields.io/github/v/release/MrZaKaRiA/LumensVM)](https://github.com/MrZaKaRiA/LumensVM/releases/latest)

A SwiftUI app for running macOS, ARM64 Linux and experimental Windows 11 ARM64 guests. A translucent machine library, separate VM windows and disks that grow as you use them make virtual machines feel at home on your Mac.

[Release v27.1.0](https://github.com/MrZaKaRiA/LumensVM/releases/tag/v27.1.0) · [User guide](docs/user-guide.md) · [Compatibility](docs/compatibility.md) · [Changelog](CHANGELOG.md) · [MIT license](LICENSE)

<p align="center"><img src="assets/lumen_ui.png" alt="Lumen's native macOS virtual machine library, shown with demo machines" width="920"></p>

## Features

- **Native macOS interface:** SwiftUI library, per-machine settings, guest windows and OS icons. macOS and Linux guests run in separate app processes with their own Dock tiles.
- **Sparse storage:** the virtual disk's capacity is a limit, not SSD space reserved upfront. Lumen displays allocated disk blocks and supports growing stopped disks.
- **Apple Silicon virtualization:** macOS and compatible ARM64 Linux through Apple's Virtualization framework; Windows 11 ARM64 through QEMU with HVF.
- **Rosetta and nested virtualization:** opt-in Rosetta for running x86-64 Linux binaries in Linux guests, nested virtualization on supported hosts (macOS 15+, M3 or later) and one-click download of the latest supported macOS restore image.
- **Display and input:** configurable resolution, automatic resizing where the guest supports it, Retina display controls and native full-screen windows.
- **Linux guest tools:** package-manager setup for SPICE text clipboard, VirtioFS shared folders, X11 desktop startup and Void/runit services. Command-C/V supports desktop and terminal shortcut modes.
- **Windows integration:** ARM64 VirtIO driver media and repair tools, experimental automatic setup, 2D display resizing, private shared folders and optional localhost port forwarding.
- **Selected-folder sharing:** multiple folders with individual read-only settings. Send files through configured writable shares.
- **Resource and lifecycle controls:** CPU/RAM budgets, start/pause/resume/shutdown, independent sound and microphone settings, and optional Keychain/Touch ID login helpers.

## Guest support

| Guest | Engine | Current status |
| --- | --- | --- |
| macOS ARM64 | Apple Virtualization | IPSW installation path; guest acceptance varies by host and macOS release. |
| Ubuntu, Debian and other ARM64 Linux | Apple Virtualization | Requires compatible ARM64 UEFI media. X11 clipboard needs guest tools. |
| Void / Abyss Linux ARM64 | Apple Virtualization | Installed Abyss tested with clipboard, shared Desktop, runit tools and a separate Dock app. |
| Windows 11 ARM64 | QEMU + HVF | Experimental. VirtIO 2D display and driver tools; external runtimes required. |
| Android / ChromeOS | — | No backend implemented. |

This release does **not** provide Windows Direct3D/Metal acceleration, snapshots/clones, Parallels import, native Wayland clipboard, macOS clipboard, file clipboard, arbitrary guest-desktop drag-and-drop or printer sharing. The [feature audit](docs/feature-audit.md) separates implemented features from remaining work.

## Get v27.1.0

v27.1.0 is a **source release**. Download the [release](https://github.com/MrZaKaRiA/LumensVM/releases/tag/v27.1.0), or clone the repository, then build on an Apple Silicon Mac. A notarized standalone installer is not included.

### Requirements

- Apple Silicon Mac with macOS 14 or later; Intel Macs are not a supported host target.
- Current Xcode or Command Line Tools with Swift 5.9 or newer and a macOS SDK supporting the APIs used by your host.
- [Homebrew](https://brew.sh/) for build/runtime dependencies.
- Your own compatible ARM64 ISO or Apple Silicon IPSW. OS images and licenses are not included.

```sh
git clone https://github.com/MrZaKaRiA/LumensVM.git
cd LumensVM
git checkout v27.1.0
brew install qemu swtpm python@3.14 sevenzip
bash scripts/build.sh
open build/Lumen.app
```

The build prepares pinned third-party driver and guest-tool resources over HTTPS and signs the app locally with virtualization entitlements. The result is **ad-hoc signed, not Developer ID signed or notarized**. Windows requires Homebrew QEMU and ARM64 firmware; TPM support uses `swtpm`, and private Windows folder sharing uses Python 3.14. These runtimes consume additional space and are not bundled as a standalone Windows engine. See [third-party notices](THIRD_PARTY_NOTICES.md).

## First VM

1. Choose **New machine** or press Command-N. Select an OS and a compatible installer, or drop an ISO/IPSW onto the library.
2. Set CPU, RAM and maximum disk capacity. Add only the Mac folders you want the guest to access.
3. Create the machine and complete its OS installer. Guest disks live in `~/Library/Application Support/Lumen/Machines/`.
4. For Linux clipboard and folder integration, open a guest terminal and choose **Install / Repair Linux Guest Tools… → Type in Guest Terminal**. Authenticate inside Linux when sudo asks.
5. For Windows, use the automatic setup tools or **Devices → Install / Repair Windows Drivers…**, approve UAC and restart if requested. See the [Windows driver and Retina guide](docs/user-guide.md#windows-arm64-drivers-and-retina).

For sharp text, the guest must render enough pixels and use suitable guest DPI scaling. Enlarging a low-resolution framebuffer cannot add detail. With Linux terminals, use **Edit → Use Terminal Copy/Paste Shortcuts**; Abyss enables this by default.

Closing a native VM window leaves it running. Click its separate OS Dock icon to reopen it. Shut down the guest before changing hardware or deleting its disk. Deleting files inside a guest may need TRIM/compaction before macOS reclaims space; moving a VM to Trash retains its storage until Trash is emptied.

## Development and validation

```sh
bash scripts/check.sh
PYTHONPATH=.runtime/WindowsSharing /opt/homebrew/opt/python@3.14/bin/python3.14 -B scripts/sharing/test-server.py
codesign --verify --deep --strict build/Lumen.app
bash scripts/release-audit.sh
```

The latest local validation passed 42 core tests and the display-redraw regression; earlier releases also passed live Abyss lifecycle/Dock checks. The v27.1.0 security, performance and Rosetta/nested-virtualization changes have not yet been exercised against live guests. Windows private-sharing transport has separate tests. These checks do not certify every guest or a production-ready Windows installation. The release audit deliberately reports missing notarization and standalone runtime packaging. Detailed results are in [validation](docs/validation.md).

## Documentation and contributing

- [User guide](docs/user-guide.md): settings, clipboard, sharing, drivers, storage and diagnostics.
- [Compatibility](docs/compatibility.md): supported paths and practical limitations.
- [Feature audit](docs/feature-audit.md) and [Windows 3D status](docs/windows-3d-integration.md): remaining engineering work.
- [Contributing](CONTRIBUTING.md), [security reporting](SECURITY.md) and [release process](docs/releasing.md).

Report reproducible bugs through [GitHub Issues](https://github.com/MrZaKaRiA/LumensVM/issues). Include host/guest versions and the relevant redacted logs; never upload VM disks, guest passwords or private shared-folder contents.

## License

Lumen's original code is [MIT licensed](LICENSE). Third-party components and guest OS trademarks retain their own licenses and ownership; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
