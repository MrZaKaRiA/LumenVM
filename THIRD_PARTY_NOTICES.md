# Third-party notices

Lumen's original code is MIT licensed. That license does not replace the licenses of separately downloaded components or guest operating systems. Source archives exclude generated runtimes, driver ISOs, guest-agent executables and OS installers.

## Host frameworks and runtimes

- **Apple Virtualization, Hypervisor, AppKit and SwiftUI:** supplied by macOS and the Apple developer tools, under Apple's terms. They are not copied into this repository.
- **QEMU and firmware:** installed separately, usually through Homebrew. QEMU is GPL-2.0 licensed with component-specific exceptions/licenses; its firmware has additional licenses. Lumen uses the existing executable and does not re-sign it. See [QEMU licensing](https://www.qemu.org/docs/master/about/license.html).
- **swtpm:** installed separately for Windows TPM emulation. See [upstream licensing](https://github.com/stefanberger/swtpm/blob/master/LICENSE).
- **Python 3.14 and sevenzip:** installed separately through Homebrew. Consult their upstream distributions for their licenses and source.

## Windows build resources

`scripts/prepare-windows-drivers.py` extracts an ARM64 subset of the official **VirtIO Windows 0.1.302** ISO. It preserves the publisher's catalogs, `virtio-win_license.txt` and a per-file SHA-256 provenance manifest. The included license is BSD-style. Driver source, component licenses and build history are available in [virtio-win](https://github.com/virtio-win/kvm-guest-drivers-windows); [build/tag mappings](https://github.com/virtio-win/kvm-guest-drivers-windows/wiki/Builds-and-tags-mapping) identify the corresponding release. Original driver signatures remain enforced.

`scripts/prepare-windows-clipboard.py` extracts unmodified ARM64 **SPICE Windows agent** executables from UTM's pinned guest-tools 0.1.273 installer. The archive, extracted binaries and GPL-2.0-or-later `COPYING` file are hash-verified. The generated `provenance.json` records the exact download and hashes. See [UTM's distribution](https://github.com/utmapp/qemu/releases/tag/v10.0.12-utm) and [SPICE agent source](https://gitlab.freedesktop.org/spice/win32/vd_agent). These agent binaries are not part of this repository or its source release. A future binary release must provide the appropriate corresponding source and dependency notices before redistributing them.

## Windows private-sharing dependencies

`scripts/sharing/requirements-macos-arm64-py314.txt` pins exact wheel hashes for Impacket and its dependencies. `scripts/prepare-windows-sharing.py` preserves each distribution's metadata and license files in the generated runtime. Licenses include BSD/MIT, Apache-family and LGPL terms; inspect the individual package license files for the authoritative conditions. Impacket's license includes its own additional terms, and ldap3 is LGPLv3. Generated dependency packages are excluded from the source release.

Anyone redistributing a built app must retain every applicable notice and satisfy any source-distribution obligations for the bundled versions. Lumen's MIT license alone is not sufficient for redistribution of those third-party binaries.

## Guest tools and artwork

Linux guest tools install packages from the guest distribution's own repositories. Those packages remain subject to their upstream licenses and are not included in this source archive.

Operating-system names, logos and related artwork remain the property of their respective owners. Their use identifies guest systems and does not imply endorsement. Guest OS images, Windows activation keys and licenses are not distributed by this project.
