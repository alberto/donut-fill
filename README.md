# Donut Fill

A DaisyDisk-style disk usage analyzer for macOS 14+. Distributed outside the Mac App Store, unsandboxed.

## Layout

| Path | What |
| --- | --- |
| `Sources/ScanKit` | Scanner (`getattrlistbulk` on a pool of worker threads; see `bench/RESULTS.md`) and the `FileNode` tree |
| `Sources/scankit-cli` | CLI for benchmarking / checking the scanner |
| `Sources/DonutFill` | SwiftUI app |
| `Tests/ScanKitTests` | Swift Testing suite for ScanKit |
| `scripts/` | Build and test helpers |

## Commands

```sh
scripts/create-signing-cert.sh # once: local signing identity so permissions survive rebuilds
scripts/build-app.sh           # builds build/Donut Fill.app, signed with "Donut Fill Dev"
open "build/Donut Fill.app"
scripts/test.sh                # runs tests (works with Command Line Tools only)
python3 scripts/make_icon.py && scripts/make_icns.sh   # regenerate the app icon (needs librsvg)
swift run -c release scankit-cli ~/Library --top 10
swift run DonutFill --snapshot ~/dev /tmp/b.png --hover 1   # render the browser offscreen (also --expand)
swift run DonutFill --snapshot start /tmp/start.png   # render the start screen
```

Xcode is not required. To open in Xcode later: `open Package.swift`.

## Notes

- Sizes are allocated bytes on disk. Hard links and full APFS clones are counted once (later clones show as 0 bytes), so totals can be below `du`'s, which counts each clone in full. Partly shared clones (copies edited afterwards) count in full, as macOS doesn't report how much they share.
- The scan stays on the root's volume. To scan the whole disk, use `/System/Volumes/Data` (the "Macintosh HD" button does this).
- Without Full Disk Access the app doesn't open other apps' containers (`~/Library/Containers`, `~/Library/Group Containers`), since macOS would ask "would like to access data from other apps" and hold up the scan; they're listed as unreadable.
- Folders the app can't read are counted. For complete results, grant the app (or your terminal, for the CLI) Full Disk Access in System Settings → Privacy & Security.
- macOS ties Full Disk Access to the code signature. Builds signed with the stable "Donut Fill Dev" identity keep it; ad-hoc builds (the fallback) lose it on every rebuild.
