# Validation

The release build produces `build/Lumen.app`, locally signed with Apple's virtualization and hypervisor entitlements. `codesign --verify --strict` passes.

## Storage and configuration

`bash scripts/check.sh` passes all five XCTest cases:

- A 64 GiB sparse disk starts with less than 1 MiB allocated, grows only around written blocks, and cannot overwrite an existing disk.
- Configuration, network identity and installer ejection survive a library reload.
- Unsupported guests, obviously Intel installer filenames and invalid capacities are rejected before disk creation.
- A machine identifier cannot redirect a record to another machine folder.
- Disk usage measurement rejects symbolic links.

## Actual Ubuntu boot

The user-provided `ubuntu-26.04.1-desktop-arm64.iso` was booted read-only with the release app on this ARM64 Mac. A temporary 64 GiB sparse disk, four CPUs and 8 GiB RAM were used. The native guest screenshot shows the Ubuntu live desktop with its welcome installer and language picker. No guest installation was automated.

The first 4 GiB / 60-second run reached Ubuntu's boot splash and passed start, pause, resume and stop. The longer 8 GiB / 180-second run reached the graphical installer and also passed start, pause, resume and stop. Both disks allocated zero host SSD blocks during their live boots, and both temporary machines were removed. The final lifecycle report is saved in `build/ubuntu-desktop-report.json` and screenshot in `build/ubuntu-desktop.png`.

The diagnostic report deliberately does not infer guest boot success from a running VM. Desktop confirmation comes from inspecting the actual screenshot. The report's `guestOSBootTested: false` is the harness's conservative default, not a statement that the screenshot was unreviewed afterward.

## Remaining checks

Ubuntu has not been installed to its virtual disk. Guest internet access, clipboard transfer, folder mounting, keyboard gestures, display changes and disk reclamation need end-to-end testing in an installed guest. The native devices and display integration are implemented, but that is separate from verifying every guest's behavior.

macOS IPSW installation and Windows guest boot have not been tested. QEMU control handling was tested with a simulated QMP subprocess, not an actual Windows VM. Arch Linux ARM, Void, other Linux distributions, Android and ChromeOS were not boot tested. Android and ChromeOS have no implemented backend.
