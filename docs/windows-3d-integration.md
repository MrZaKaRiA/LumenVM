# Windows graphics integration status — 13 October 2026

Lumen currently uses Homebrew QEMU's Cocoa display and the signed ARM64 `viogpudo` display-only driver. The local QEMU 11.1.2 binary exposes only `none`, `curses`, `cocoa`, and `dbus` display backends and has no `virtio-gpu-gl-pci` or `virtio-ramfb-gl` device. A graphics driver ISO alone cannot add Direct3D acceleration to this host profile. The current build therefore provides a 2D desktop and must not be advertised as having Windows 3D acceleration.

UTM's experimental Triton/Neptune path is the credible integration target. It consists of a matching Windows ARM64 3D kernel/user-mode driver, UTM's QEMU fork with `virtio-ramfb-gl` and Neptune enabled, virglrenderer with Neptune, a Metal-capable host Direct3D backend, and a scanout frontend. UTM documents `hostmem=8G,blob=true,venus=true,neptune=true` and `-display cocoa,gl=es` in its development example. Its September 2026 beta still describes Windows 3D as experimental and recommends a fresh guest installation. This is a separate graphics backend and driver profile, not an in-place upgrade to the current `viogpudo` profile.

Integration gates for Lumen:

The UTM v5.0.6 prebuilt dependency profile explicitly disables Cocoa (`--disable-cocoa`) while enabling its shared QEMU library. It therefore cannot replace Lumen's current executable/Cocoa profile directly. Its runtime requires a compatible frontend or a custom QEMU build with the necessary graphics display backend; see the [versioned dependency build script](https://github.com/utmapp/UTM/blob/v5.0.6/scripts/build_dependencies.sh). No 3D toggle or experimental driver was added to Lumen's current 2D profile.

1. Build or package a versioned, reproducible, signed host runtime with exact hashes and licenses for QEMU, virglrenderer, the render server, Metal backend, firmware and the Windows ARM64 3D driver. Do not fetch large runtime packages during ordinary app builds or VM creation.
2. Add a separate experimental VM graphics profile with a matching recovery path. Never auto-install `viogpu3d` alongside `viogpudo` or run a driver-uninstall script against an existing user's VM. Validate the selected host binary's exact devices and the driver ISO before a VM can start in this mode.
3. Boot a disposable fresh Windows ARM64 guest through installation and first login, verify Direct3D feature levels with `dxdiag`, test resizing and cursor rendering at 100–200% scaling, then test cold starts, normal shutdown, recovery and a small Direct3D workload. Record allocated SSD bytes and rendering failures. Only then consider a user-facing beta option.
4. For production, finish independent packaging, notarization, Windows and Linux guest acceptance, rollback, external display, audio, input and shared-folder tests. `scripts/release-audit.sh` reports the current packaging blockers.

Primary sources: [UTM Triton engineering article](https://blog.getutm.app/2026/introducing-triton-directx-11-driver-for-qemu/), [UTM 5.0.5 beta release notes](https://github.com/utmapp/UTM/discussions/7847), [UTM graphics architecture](https://github.com/utmapp/UTM/blob/main/Documentation/Graphics.md).
