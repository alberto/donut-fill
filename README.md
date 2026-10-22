# Donut Fill

A DaisyDisk-style disk usage analyzer for macOS 14+. Distributed outside the Mac App Store, unsandboxed.

## Layout

| Path | What |
| --- | --- |
| `Sources/ScanKit` | Scanner (POSIX `readdir` + `fstatat`, parallel near the root) and the `FileNode` tree |
| `Sources/scankit-cli` | CLI for benchmarking / checking the scanner |
| `Sources/DonutFill` | SwiftUI app |
| `Tests/ScanKitTests` | Swift Testing suite for ScanKit |
| `scripts/` | Build and test helpers |

## Commands

```sh
scripts/build-app.sh           # builds build/Donut Fill.app (ad-hoc signed)
open "build/Donut Fill.app"
scripts/test.sh                # runs tests (works with Command Line Tools only)
swift run -c release scankit-cli ~/Library --top 10
swift run DonutFill --snapshot ~/dev /tmp/chart.png   # render the chart offscreen to a PNG
```

Xcode is not required. To open in Xcode later: `open Package.swift`.

## Notes

- Sizes are allocated bytes (`st_blocks * 512`), matching `du`. Hard links are counted once.
- The scan stays on the root's volume. To scan the whole disk, use `/System/Volumes/Data` (the "Macintosh HD" button does this).
- Folders the app can't read are counted. For complete results, grant the app (or your terminal, for the CLI) Full Disk Access in System Settings → Privacy & Security.
