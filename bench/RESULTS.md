# Scanner engine benchmarks

M2 Pro (10 cores), internal SSD, FileVault, macOS 26.6, October 2026.
Raw output: `sweep-library.txt`, `sweep-data.txt` (from `scripts/bench.sh`).

Each engine ran in its own process, twice: run 1 is "cold-ish", run 2 "warm".
There was no `purge` (it needs sudo), so the kernel caches were warm from the
earlier engines. A posix control run at the end of each sweep matched the first
posix run, so caches didn't drift during a sweep. `du -skx` matches the scanner's
default of not crossing volumes.

## ~/Library: 1.61M files, 70.7k folders, 72.46 GB

| engine | wall run 1 / 2 | sys run 1 / 2 | KB (run 1) | unreadable |
|---|---|---|---|---|
| du -skx | 41.8 / 42.9 s | 10.9 / 11.2 s | 72,457,652 | — |
| posix (original) | 17.1 / 16.6 s | 39.7 / 36.9 s | 72,458,076 | 133 |
| posix, control run at the end | 17.4 / 18.4 s | 38.5 / 37.9 s | 72,458,248 | 134 |
| posix-tasks, 8 workers | 16.6 / 17.3 s | 29.3 / 28.8 s | 72,458,124 | 134 |
| posix-threads, 8 workers | 17.1 / 16.9 s | 34.9 / 36.5 s | 72,458,100 | 134 |
| posix-threads, 16 workers | 17.1 / 17.3 s | 46.5 / 46.5 s | 72,458,104 | 140 |
| bulk | 11.6 / 10.2 s | 25.1 / 23.4 s | 72,458,072 | 133 |
| bulk-tasks, 4 workers | 15.9 / 16.4 s | 12.8 / 12.6 s | 72,458,124 | 133 |
| bulk-tasks, 8 workers | 16.2 / 15.2 s | 16.1 / 16.6 s | 72,458,184 | 133 |
| bulk-tasks, 16 workers | 14.3 / 35.1* s | 21.5 / 35.7 s | 72,458,116 | 134 |
| bulk-tasks, 32 workers | 28.0* / 15.8 s | 29.3 / 24.8 s | 72,458,116 | 140 |
| bulk-threads, 4 workers | 12.8 / 13.7 s | 13.7 / 12.7 s | 72,458,248 | 133 |
| **bulk-threads, 8 workers** | **11.1 / 11.4 s** | **20.3 / 20.9 s** | 72,458,252 | 134 |
| bulk-threads, 16 workers | 10.9 / 10.4 s | 36.5 / 37.3 s | 72,458,296 | 136 |
| bulk-threads, 32 workers | 11.8 / 12.7 s | 40.5 / 43.3 s | 72,458,244 | 141 |
| bulk-threads, 64 workers | 12.0 / 11.7 s | 39.9 / 41.4 s | 72,457,652 | 141 |

\* Outlier runs, with fewer folders and more unreadable ones than the other
runs: ~/Library was changing underneath, or the machine was busy. User time
was 0.6–1.5 s everywhere.

## /System/Volumes/Data: 4.74M files, 614k folders, 289.7 GB

| engine | wall run 1 / 2 | sys run 1 / 2 | KB (run 1) | unreadable | peak RSS |
|---|---|---|---|---|---|
| du -skx | 122.3 / 118.1 s | 41.0 / 39.3 s | 289,729,345 | — | — |
| posix (original) | 47.0 / 65.4 s | 114.0 / 123.2 s | 289,727,528 | 348 | 752 MB |
| posix, control run at the end | 48.6 / 41.9 s | 108.9 / 115.2 s | 289,729,972 | 345 | 752 MB |
| bulk | 41.4 / 35.0 s | 84.6 / 72.1 s | 289,726,400 | 377 | 752 MB |
| **bulk-threads, 8 workers** | **26.8 / 27.6 s** | **91.9 / 92.6 s** | 289,732,324 | 376 | 749 MB |
| bulk-threads, 12 workers | 28.5 / 28.6 s | 158.1 / 142.1 s | 289,719,564 | 376 | 751 MB |
| bulk-threads, 16 workers | 28.4 / 29.5 s | 168.0 / 184.9 s | 289,726,188 | 380 | 751 MB |

## Findings

- Most of the gain comes from `getattrlistbulk`. With the same TaskGroup scheme,
  it cuts system time by about 35% and wall time by 30–40% on ~/Library.
- Concurrency alone doesn't help the posix reader: every variant stays at about
  17 s on ~/Library, and extra threads only add system time (kernel contention).
- With the bulk reader, dedicated threads beat the cooperative pool on the whole
  volume (27 s against 35–41 s). Bounded Swift tasks were the worst bulk
  variant: the cooperative pool has 10 threads, and a task that can't spawn walks
  its subtree serially.
- The best worker count is 8–16. Past 8, system time roughly doubles for at most
  0.5 s of wall time on ~/Library, and nothing at all on the whole volume.
- Totals agree within 0.01% across all engines and du. Each run differs by a
  few MB because files change while the scan runs (caches, logs).
- The bulk engines count about 30 more unreadable folders on the whole volume.
  These folders can't even be `stat`ed (EPERM, e.g.
  `/Library/Caches/com.apple.aned`). The posix engine's `fstatat` fails on them,
  so it skips them without counting them. getattrlistbulk lists them from the
  parent, then fails to open them, so they're counted. Their own size is 0 on
  APFS either way, so totals are unaffected.
- Peak RSS is the same for every engine (about 750 MB for 4.7M nodes): it's the
  FileNode tree, not the walk.

Default: `bulk-threads` with 8 workers. It's about 1.5x faster than the original
on ~/Library and 1.6–1.8x on the whole volume (2.4x faster than du on ~/Library,
4.4x on the whole volume), with the least system time of the fast options.

## APFS clone detection (October 2026)

The bulk reader also requests `ATTR_CMNEXT_CLONEID` and `ATTR_CMNEXT_CLONE_REFCNT`,
so full clones are counted once. Same machine, idle, `bulk-threads` with 8
workers, three alternating runs each; medians:

| path | without | with clones | change |
|---|---|---|---|
| ~/Library wall / sys | 13.1 / 21.5 s | 13.7 / 24.6 s | +4% / +14% |
| /System/Volumes/Data wall / sys | 30.1 / 100.2 s | 31.0 / 111.8 s | +3% / +12% |
| ~/Library total | 72.75 GB | 72.10 GB | −0.64 GB |
| /System/Volumes/Data total | 274.76 GB | 270.32 GB | −4.44 GB |

Totals are now below `du`'s, which counts every clone in full. Peak RSS is
unchanged. The POSIX engines can't see clones and still count them in full.
