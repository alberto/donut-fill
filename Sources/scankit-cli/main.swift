import Foundation
import ScanKit

// Usage: scankit-cli [path] [--top N]
var arguments = Array(CommandLine.arguments.dropFirst())
var top = 15
if let index = arguments.firstIndex(of: "--top"), index + 1 < arguments.count, let value = Int(arguments[index + 1]) {
    top = value
    arguments.removeSubrange(index...index + 1)
}
let path = arguments.first.map { ($0 as NSString).expandingTildeInPath } ?? FileManager.default.currentDirectoryPath

func format(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

let progress = ScanProgress()
let clock = ContinuousClock()
let start = clock.now
let root: FileNode
do {
    root = try await Scanner().scan(path: path, progress: progress)
} catch {
    FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
    exit(1)
}
let elapsed = clock.now - start
let stats = progress.snapshot

print("\(root.path)")
print("  \(format(root.size)) in \(stats.files) files, \(stats.directories) folders — scanned in \(elapsed.formatted(.units(allowed: [.seconds, .milliseconds])))")
if stats.unreadable > 0 {
    print("  \(stats.unreadable) folders could not be read (grant Full Disk Access to your terminal to include them)")
}

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
