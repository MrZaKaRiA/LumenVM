# Release process

## Source release

1. Update both version strings in `Resources/Info.plist` and add the changelog entry.
2. Review the README, compatibility matrix and validation notes. Keep observed guest behavior distinct from untested features.
3. Run `bash scripts/check.sh`, `bash scripts/build.sh`, `codesign --verify --deep --strict build/Lumen.app` and `git diff --check`.
4. Check the staged source for credentials, VM bundles, OS installers, generated runtime dependencies and personal screenshots. These do not belong in Git.
5. Commit the source and create an annotated `vMAJOR.MINOR.PATCH` tag matching the app version.
6. Run `bash scripts/package-source-release.sh v27.1.0`. It requires a clean checkout with the tag at HEAD and creates a source ZIP and `SHA256SUMS` under `build/releases/v27.1.0/`.
7. Push the reviewed commit/tag, then create the GitHub release with its notes, source ZIP and checksums. Verify the published tag and assets.

v27.1.0 is a source release. The GitHub source downloads and explicitly packaged source ZIP contain the same tagged tree; build outputs and runtime downloads remain excluded.

## Future standalone app release

The current build is ad-hoc signed. Before offering a production standalone app, complete Developer ID signing/notarization, the appropriate third-party source/license distribution, reproducible runtime packaging and installed-guest acceptance. `bash scripts/release-audit.sh` reports the current distribution blockers; it is expected to fail those gates for a source release.

Do not publish a local app bundle as a notarized installer or claim Windows Direct3D acceleration. macOS/Linux host processes share the signed executable/resources, while Windows still needs external QEMU and Python runtimes. Packaging must preserve those distinctions and must never include the maintainer's VM library, guest credentials or installer images.
