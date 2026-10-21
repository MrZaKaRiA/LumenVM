# Contributing

Build and test on an Apple Silicon Mac using the [README](README.md). Keep changes focused and describe the user-visible problem, resulting behavior and validation in your pull request.

## Checks

```sh
bash scripts/check.sh
bash scripts/build.sh
codesign --verify --deep --strict build/Lumen.app
git diff --check
```

For Windows sharing changes, also run:

```sh
PYTHONPATH=.runtime/WindowsSharing /opt/homebrew/opt/python@3.14/bin/python3.14 -B scripts/sharing/test-server.py
```

Use disposable VM libraries for boot tests. Never run destructive tests against your daily guest. Keep `.build`, `.runtime`, `build`, VM bundles, installer images, credentials and private screenshots out of commits.

## Project layout

| Path | Purpose |
| --- | --- |
| `Sources/Lumen` | SwiftUI/AppKit UI, VM engines, process supervision and macOS integrations |
| `Sources/LumenCore` | VM records, storage, installer detection and generated guest tools |
| `Sources/LumenHelper` | Windows QEMU Cocoa/menu/display helper |
| `Tests/LumenCoreTests` | Core behavior and generated-tool tests |
| `scripts` | Builds, resource preparation and diagnostics |
| `docs` | User guidance, compatibility, validation and engineering status |

Respect guest shutdown, sparse allocation, read-only shares and original driver signatures. Do not replace existing desktop/init configuration while repairing guest tools. Document host/guest versions for live tests and distinguish actual guest results from generated-script or boot-only coverage.

Guest GPU and clipboard support varies by backend and desktop session. Update the compatibility documentation when behavior changes, and avoid advertising untested guest capabilities. Follow the [security guidance](SECURITY.md) for sensitive reports.
