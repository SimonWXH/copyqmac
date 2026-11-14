// SPDX-License-Identifier: GPL-3.0-or-later
//
// Standalone probe for the CopyQSync module.
//
// Built by tools/copyq-sync-probe.sh with only the Command Line Tools.  It
// never writes to the folders it is pointed at: `sweep` and `cpq` are
// strictly read-only, and `roundtrip` works from copies.
//
// Usage:
//   copyq-sync-probe sweep <sync-folder> [<sync-folder> ...]
//   copyq-sync-probe roundtrip <file-or-directory> [...]
//   copyq-sync-probe cpq <archive.cpq>

import Foundation

let usage = """
usage: copyq-sync-probe <command> [arguments]

commands:
  sweep <folder> [...]      read-only report of a CopyQ sync folder
  roundtrip <path> [...]  byte-level _copyq.dat parse/write round trip
  cpq <archive.cpq>         summarise a CopyQ .cpq archive
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func describe(_ item: CopyQSyncItem) -> String {
    var parts: [String] = []
    parts.append("formats=[\(item.data.formats.joined(separator: ", "))]")
    if let notes = item.notes {
        parts.append("note=\(notes.utf8.count)B")
    }
    if item.isPinned {
        parts.append("pinned=yes")
    }
    if !item.tags.isEmpty {
        parts.append("tags=\(item.tags.count)")
    }
    if !item.images.isEmpty {
        parts.append("images=[\(item.images.keys.sorted().joined(separator: ", "))]")
    }
    return parts.joined(separator: " ")
}

// MARK: - sweep

func sweep(_ folders: [String]) {
    var totalItems = 0
    var totalFlavours = 0
    var totalNotes = 0
    var totalImages = 0
    var totalFailures = 0
    var totalSkipped = 0
    var formats: [String: Int] = [:]

    for folder in folders {
        print("folder: \(folder)")
        let contents: CopyQSyncFolder.Contents
        do {
            contents = try CopyQSyncFolder.read(atPath: folder)
        } catch {
            print("  error: \(error)")
            totalFailures += 1
            continue
        }

        let flavourCounts = contents.flavourCounts()
        let flavourTotal = flavourCounts.values.reduce(0, +)
        let notes = contents.items.filter { $0.notes != nil }.count
        let images = contents.items.filter { !$0.images.isEmpty }.count

        print("  files considered: \(contents.fileCount) (ignored \(contents.ignoredFiles.count) non-flavour file(s), skipped \(contents.skippedCount) unsafe or unresolved path(s))")
        print("  items: \(contents.items.count)")
        print("  flavours: \(flavourTotal) across \(flavourCounts.count) distinct format(s)")
        for format in flavourCounts.keys.sorted() {
            print("    \(format): \(flavourCounts[format]!)")
            formats[format, default: 0] += flavourCounts[format]!
        }
        print("  items with notes: \(notes)")
        print("  items with images: \(images)")
        print("  parse failures: \(contents.failures.count)")
        for failure in contents.failures {
            print("    FAIL \(failure.fileName): \(failure.reason)")
        }
        for skipped in contents.skippedFiles {
            print("    SKIP \(skipped.fileName): \(skipped.reason)")
        }

        totalItems += contents.items.count
        totalFlavours += flavourTotal
        totalNotes += notes
        totalImages += images
        totalFailures += contents.failures.count
        totalSkipped += contents.skippedCount
    }

    print("total: \(totalItems) item(s), \(totalFlavours) flavour(s), \(totalNotes) with notes, \(totalImages) with images, \(totalFailures) failure(s), \(totalSkipped) skipped path(s)")

    if !formats.isEmpty {
        print("formats overall:")
        for format in formats.keys.sorted() {
            print("  \(format): \(formats[format]!)")
        }
    }

    if totalFailures > 0 {
        exit(2)
    }
}

// MARK: - roundtrip

func collectDataFiles(_ path: String) -> [String] {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
        fail("no such path: \(path)")
    }
    if !isDirectory.boolValue {
        return [path]
    }
    let root = URL(fileURLWithPath: path)
    var files: [String] = []
    let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
    while let url = enumerator?.nextObject() as? URL {
        guard url.lastPathComponent.hasSuffix(CopyQFormat.dataFileSuffix) else { continue }
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
        if values?.isRegularFile == true {
            files.append(url.path)
        }
    }
    return files.sorted()
}

func roundtrip(_ paths: [String]) {
    var files: [String] = []
    for path in paths {
        files.append(contentsOf: collectDataFiles(path))
    }
    guard !files.isEmpty else {
        fail("no \(CopyQFormat.dataFileSuffix) files found")
    }

    var passed = 0
    var failed = 0
    for file in files {
        do {
            let original = try Data(contentsOf: URL(fileURLWithPath: file))
            let map = try CopyQItemData.decode(original)
            let rewritten = CopyQItemData.encode(map)
            if rewritten == original {
                passed += 1
                print("PASS \(file) (\(original.count) bytes, \(map.count) flavour(s))")
            } else {
                failed += 1
                print("FAIL \(file): re-encoded bytes differ from the original (\(original.count) vs \(rewritten.count) bytes)")
            }
        } catch {
            failed += 1
            print("FAIL \(file): \(error)")
        }
    }

    print("round-tripped \(passed)/\(passed + failed) \(CopyQFormat.dataFileSuffix) file(s) byte-identically")
    if failed > 0 {
        exit(2)
    }
}

// MARK: - cpq

func cpq(_ path: String) {
    let archive: CopyQArchive
    do {
        archive = try CopyQArchive.read(atPath: path)
    } catch {
        fail("failed to read \(path): \(error)")
    }

    print("archive: \(path)")
    print("  format: \(archive.format.rawValue)")
    print("  top level keys: \(archive.settings.keys.sorted().joined(separator: ", "))")
    print("  tabs: \(archive.tabNames.count)")
    for tab in archive.tabNames {
        let items = archive.tabItems[tab] ?? []
        print("    tab \(tab): \(items.count) item(s)")
        for (index, item) in items.enumerated() {
            print("      item \(index + 1): \(describe(item))")
        }
    }
    print("  items total: \(archive.items.count)")
    print("  flavour failures: \(archive.failures.count)")
    for failure in archive.failures {
        print("    FAIL \(failure.location) [\(failure.format)]: \(failure.reason)")
    }
    if !archive.failures.isEmpty {
        exit(2)
    }
}

// MARK: - entry point

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else {
    print(usage)
    exit(0)
}

switch command {
case "sweep":
    let folders = Array(arguments.dropFirst())
    guard !folders.isEmpty else { fail(usage) }
    sweep(folders)
case "roundtrip":
    let paths = Array(arguments.dropFirst())
    guard !paths.isEmpty else { fail(usage) }
    roundtrip(paths)
case "cpq":
    guard arguments.count == 2 else { fail(usage) }
    cpq(arguments[1])
case "-h", "--help", "help":
    print(usage)
default:
    fail("unknown command: \(command)\n\(usage)")
}
