import Darwin
import Foundation
import ScanKit

// Usage: scankit-cli [path] [--top N] [--engine NAME] [--workers N] [--repeat N]
var arguments = Array(CommandLine.arguments.dropFirst())

@MainActor func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    let value = arguments[index + 1]
    arguments.removeSubrange(index...index + 1)
    return value
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

let top = option("--top").flatMap(Int.init) ?? 15
let repeats = option("--repeat").flatMap(Int.init) ?? 1
var options = ScanOptions()
if let name = option("--engine") {
    guard let engine = ScanEngine(rawValue: name) else {
        fail("unknown engine \(name); expected one of \(ScanEngine.allCases.map(\.rawValue).joined(separator: ", "))")
    }
    options.engine = engine
}
if let workers = option("--workers").flatMap(Int.init) { options.workers = workers }
if let depth = option("--parallel-depth").flatMap(Int.init) { options.parallelDepth = depth }
let path = arguments.first.map { ($0 as NSString).expandingTildeInPath } ?? FileManager.default.currentDirectoryPath

func format(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

func cpuTimes() -> (user: Double, system: Double, maxRSS: Int) {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000 }
    // ru_maxrss is in bytes on macOS.
    return (seconds(usage.ru_utime), seconds(usage.ru_stime), usage.ru_maxrss)
}

var root: FileNode?
for run in 1...max(repeats, 1) {
    root = nil
    let progress = ScanProgress()
    let before = cpuTimes()
    let start = ContinuousClock.now
    do {
        root = try await Scanner(options: options).scan(path: path, progress: progress)
    } catch {
        fail(error.localizedDescription)
    }
    let wall = ContinuousClock.now - start
    let after = cpuTimes()
    let stats = progress.snapshot
    let wallSeconds = Double(wall.components.seconds) + Double(wall.components.attoseconds) / 1e18
    print(String(
        format: "run=%d engine=%@ workers=%d wall=%.2fs user=%.2fs sys=%.2fs files=%d folders=%d bytes=%lld kb=%lld unreadable=%d peakRSS=%dMB",
        run, options.engine.rawValue, options.workers, wallSeconds, after.user - before.user, after.system - before.system,
        stats.files, stats.directories, root!.size, root!.size / 1024, stats.unreadable, after.maxRSS / 1_048_576
    ))
}

guard let root, top > 0 else { exit(0) }
print("\n\(root.path): \(format(root.size))")

print("\nLargest items:")
for child in root.children.prefix(top) {
    let share = root.size > 0 ? Double(child.size) / Double(root.size) * 100 : 0
    print(String(format: "  %10@  %5.1f%%  %@%@", format(child.size), share, child.name, child.isDirectory ? "/" : ""))
}

func collectFiles(_ node: FileNode, into files: inout [FileNode]) {
    if node.isDirectory {
        for child in node.children { collectFiles(child, into: &files) }
    } else {
        files.append(node)
    }
}
var largestFiles: [FileNode] = []
collectFiles(root, into: &largestFiles)
largestFiles.sort { $0.size > $1.size }
print("\nLargest files:")
for file in largestFiles.prefix(top) {
    print(String(format: "  %10@  %@", format(file.size), file.path))
}
