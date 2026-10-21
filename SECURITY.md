# Security

Lumen is under active development. The Windows backend and guest tools are experimental; there is no audited security or guest-isolation guarantee beyond the underlying platform/runtime behavior.

## Reporting a vulnerability

Use GitHub private vulnerability reporting if it is enabled for this repository. Otherwise, open a minimal [issue](https://github.com/MrZaKaRiA/LumensVM/issues) requesting a private reporting channel without posting exploit details, credentials or private data. Include affected versions and a minimal reproduction in the private report.

Do not attach guest disks, Keychain data, shared-folder credentials, access tokens, personal files or unredacted VM logs. Lumen's random Windows share credentials are stored in the VM bundle and must remain private.

## Sharing and credentials

Only share folders that a guest should access. Set read-only access where appropriate. Windows sharing binds to Mac loopback and forwards into the guest; it does not enable macOS LAN File Sharing. Linux/macOS use selected VirtioFS shares. Guest access still exposes the selected files to programs running inside that guest.

Touch ID login helpers type a stored guest password into the focused guest field. Verify focus before using them. Local ad-hoc signing can change macOS Keychain access prompts after rebuilding.

## Releases

v27.1.0 is a source release. Build scripts download pinned third-party dependencies; review [third-party notices](THIRD_PARTY_NOTICES.md). Locally built apps use ad-hoc signing and are not notarized. Do not treat a passing build or signature verification as a production security assessment.
