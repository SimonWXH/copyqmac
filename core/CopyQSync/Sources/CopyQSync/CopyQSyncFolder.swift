// SPDX-License-Identifier: GPL-3.0-or-later
//
// Reads and writes a CopyQ sync folder.
//
// Everything here is read-only unless `write(_:into:)` is called explicitly.
// Tests and probes are expected to copy real folders into a scratch
// directory before writing anything; the module itself never touches the
// live folders.

import Darwin
import Foundation

public struct CopyQSyncFolder {
    /// A file that matched a known flavour but could not be decoded.
    public struct Failure: Equatable {
        /// Why the file could not be read, structured so the prose around any
        /// system error can be written in the reader's language.
        public enum Reason: Equatable, CustomStringConvertible {
            case cannotResolvePath
            case pathEscapesSyncRoot
            case cannotReadFile(String)
            case flavour(format: String, detail: String)
            case systemError(String)

            public var description: String {
                switch self {
                case .cannotResolvePath:
                    return "cannot resolve path"
                case .pathEscapesSyncRoot:
                    return "resolved path escapes sync root"
                case .cannotReadFile(let detail):
                    return "cannot read file: \(detail)"
                case .flavour(let fileFormat, let detail):
                    return "flavour \(fileFormat): \(detail)"
                case .systemError(let detail):
                    return detail
                }
            }
        }

        public var fileName: String
        public var reason: Reason

        public init(fileName: String, reason: Reason) {
            self.fileName = fileName
            self.reason = reason
        }
    }

    /// The result of reading a sync folder.
    public struct Contents {
        public var items: [CopyQSyncItem]
        public var failures: [Failure]
        /// Entries skipped because they could not safely be read.
        public var skippedFiles: [Failure]
        /// Non-hidden files whose extension is not a CopyQ flavour.
        public var ignoredFiles: [String]
        /// Total number of regular files considered.
        public var fileCount: Int

        public var skippedCount: Int { skippedFiles.count }

        public init(
            items: [CopyQSyncItem] = [],
            failures: [Failure] = [],
            skippedFiles: [Failure] = [],
            ignoredFiles: [String] = [],
            fileCount: Int = 0
        ) {
            self.items = items
            self.failures = failures
            self.skippedFiles = skippedFiles
            self.ignoredFiles = ignoredFiles
            self.fileCount = fileCount
        }

        /// Aggregate flavour counts across every item.
        public func flavourCounts() -> [String: Int] {
            var counts: [String: Int] = [:]
            for item in items {
                for format in item.data.formats {
                    counts[format, default: 0] += 1
                }
            }
            return counts
        }
    }

    private struct Candidate {
        var relativePath: String
        var resolvedPath: String
    }

    /// True when `name` matches a Syncthing sync-conflict file pattern.
    public static func isSyncConflictFileName(_ name: String) -> Bool {
        name.contains(".sync-conflict-")
    }

    /// Reads every item in a sync folder without modifying anything.
    public static func read(
        atPath path: String,
        maximumDecompressedSize: Int = QtCompression.defaultMaximumUncompressedSize
    ) throws -> Contents {
        let fileManager = FileManager.default
        guard let rootPath = resolvedPath(path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
        var candidates: [Candidate] = []
        var skipped: [Failure] = []
        var visitedDirectories: Set<String> = [rootPath]

        func enumerate(_ directory: URL, relativeTo relativeDirectory: String) throws {
            for name in try fileManager.contentsOfDirectory(atPath: directory.path).sorted() {
                guard !name.hasPrefix(".") else { continue }
                guard !isSyncConflictFileName(name) else { continue }
                let relativePath = relativeDirectory.isEmpty ? name : relativeDirectory + "/" + name
                let child = directory.appendingPathComponent(name)
                guard let resolved = resolvedPath(child.path) else {
                    skipped.append(Failure(fileName: relativePath, reason: .cannotResolvePath))
                    continue
                }
                guard isContained(resolved, in: rootPath) else {
                    skipped.append(Failure(fileName: relativePath, reason: .pathEscapesSyncRoot))
                    continue
                }

                let resolvedURL = URL(fileURLWithPath: resolved)
                let values = try? resolvedURL.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
                if values?.isDirectory == true {
                    if visitedDirectories.insert(resolved).inserted {
                        try enumerate(resolvedURL, relativeTo: relativePath)
                    }
                } else if values?.isRegularFile == true {
                    candidates.append(Candidate(relativePath: relativePath, resolvedPath: resolved))
                }
            }
        }

        try enumerate(rootURL, relativeTo: "")
        candidates.sort { $0.relativePath < $1.relativePath }

        // Group files by the name stem that is left once the flavour
        // extension is stripped.
        var groups: [String: [(file: String, resolvedPath: String, ext: String, format: String)]] = [:]
        var ignored: [String] = []

        for candidate in candidates {
            let file = candidate.relativePath
            guard !isSyncConflictFileName(file) else { continue }
            guard let ext = CopyQFormat.matchedExtension(forFileName: file),
                  let format = CopyQFormat.format(forExtension: ext)
            else {
                ignored.append(file)
                continue
            }
            groups[String(file.dropLast(ext.count)), default: []].append(
                (file, candidate.resolvedPath, ext, format)
            )
        }

        var items: [CopyQSyncItem] = []
        var failures: [Failure] = []

        for base in groups.keys.sorted(by: isBaseNameLessThan) {
            let (item, itemFailures) = decodeItemGroup(
                baseName: base,
                entries: groups[base]!,
                maximumDecompressedSize: maximumDecompressedSize
            )
            failures.append(contentsOf: itemFailures)
            items.append(item)
        }

        return Contents(
            items: items,
            failures: failures,
            skippedFiles: skipped,
            ignoredFiles: ignored,
            fileCount: candidates.count
        )
    }

    /// Decodes a single item group from candidate file entries sharing a base stem.
    public static func decodeItemGroup(
        baseName: String,
        entries: [(file: String, resolvedPath: String, ext: String, format: String)],
        maximumDecompressedSize: Int = QtCompression.defaultMaximumUncompressedSize
    ) -> (item: CopyQSyncItem, failures: [Failure]) {
        var item = CopyQSyncItem(baseName: baseName)
        var newest: Date?
        var failures: [Failure] = []

        for entry in entries {
            let url = URL(fileURLWithPath: entry.resolvedPath)
            let fileData: Data
            do {
                fileData = try Data(contentsOf: url)
            } catch {
                failures.append(Failure(
                    fileName: entry.file,
                    reason: .cannotReadFile(error.localizedDescription)
                ))
                continue
            }

            if let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
               let date = values.contentModificationDate {
                newest = max(newest ?? date, date)
            }

            if entry.ext == CopyQFormat.dataFileSuffix {
                do {
                    let decoded = try CopyQItemData.decodeReportingFailures(
                        fileData,
                        maximumDecompressedSize: maximumDecompressedSize
                    )
                    for format in decoded.map.formats {
                        item.data.set(format, decoded.map.value(format) ?? nil)
                    }
                    for failure in decoded.failures {
                        failures.append(Failure(
                            fileName: entry.file,
                            reason: .flavour(format: failure.format, detail: failure.reason)
                        ))
                    }
                } catch {
                    failures.append(Failure(
                        fileName: entry.file,
                        reason: .systemError("\(error)")
                    ))
                    continue
                }
            } else {
                item.data.set(entry.format, fileData)
            }
            item.fileNames[entry.format] = entry.file
        }

        item.fileModificationDate = newest
        // The name stamp and the file modification time back each other up:
        // the later of the two is the item's date, so a stale base stamp never
        // hides a recent arrival and an old item keeps its preserved mtime.
        item.timestamp = CopyQSyncItem.effectiveTimestamp(
            nameTimestamp: CopyQSyncItem.parseTimestamp(baseName: baseName),
            fileModificationDate: newest
        )
        return (item, failures)
    }

    /// Reads an individual item group by its stem in a folder without scanning unrelated stems.
    public static func readItem(
        baseName: String,
        atPath folderPath: String,
        candidateFiles: [String]? = nil,
        maximumDecompressedSize: Int = QtCompression.defaultMaximumUncompressedSize
    ) throws -> (item: CopyQSyncItem, failures: [Failure])? {
        guard !isSyncConflictFileName(baseName) else { return nil }
        let fm = FileManager.default
        guard let root = resolvedPath(folderPath) else { return nil }
        var groupEntries: [(file: String, resolvedPath: String, ext: String, format: String)] = []

        let filenames: [String]
        if let candidateFiles {
            filenames = candidateFiles
        } else {
            var candidateExtensions = CopyQFormat.defaultExtensions.map { (ext: $0.ext, format: $0.format) }
            candidateExtensions.append((ext: CopyQFormat.dataFileSuffix, format: CopyQFormat.unknownFormats))
            filenames = candidateExtensions.compactMap { candidate in
                let name = baseName + candidate.ext
                let fullPath = (root as NSString).appendingPathComponent(name)
                return fm.fileExists(atPath: fullPath) ? name : nil
            }
        }

        for filename in filenames {
            guard !filename.hasPrefix("."), filename.hasPrefix(baseName) else { continue }
            guard !isSyncConflictFileName(filename) else { continue }
            guard let ext = CopyQFormat.matchedExtension(forFileName: filename),
                  let format = CopyQFormat.format(forExtension: ext)
            else { continue }
            let stem = String(filename.dropLast(ext.count))
            guard stem == baseName else { continue }
            let fullPath = (root as NSString).appendingPathComponent(filename)
            guard let resolved = resolvedPath(fullPath), isContained(resolved, in: root) else { continue }
            groupEntries.append((file: filename, resolvedPath: resolved, ext: ext, format: format))
        }

        guard !groupEntries.isEmpty else { return nil }
        return decodeItemGroup(
            baseName: baseName,
            entries: groupEntries,
            maximumDecompressedSize: maximumDecompressedSize
        )
    }

    /// Writes an item into a sync folder using CopyQ's on-disk shape.  Callers
    /// must pass a scratch directory, never a live sync folder.
    @discardableResult
    public static func write(_ item: CopyQSyncItem, into path: String) throws -> [String] {
        guard let baseName = item.baseName, !baseName.isEmpty else {
            throw QDataStreamError.corrupt("cannot write an item without a base name")
        }
        let baseComponents = baseName.split(separator: "/", omittingEmptySubsequences: false)
        guard !baseName.hasPrefix("/"),
              !baseName.utf8.contains(0),
              !baseComponents.isEmpty,
              baseComponents.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else {
            throw QDataStreamError.corrupt("item base name must be a safe relative path")
        }

        let fileManager = FileManager.default
        let requestedRoot = URL(fileURLWithPath: path, isDirectory: true)
        try fileManager.createDirectory(at: requestedRoot, withIntermediateDirectories: true)
        guard let rootPath = resolvedPath(requestedRoot.path) else {
            throw QDataStreamError.corrupt("cannot resolve sync root")
        }

        var written: [String] = []
        for (suffix, bytes) in item.onDiskFiles() {
            let relativeName = baseName + suffix
            let components = relativeName.split(separator: "/", omittingEmptySubsequences: false)
            guard components.count == baseComponents.count,
                  components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
            else {
                throw QDataStreamError.corrupt("item output path is not a safe relative path")
            }

            var parentPath = rootPath
            for component in components.dropLast() {
                let parentURL = URL(fileURLWithPath: parentPath, isDirectory: true)
                let childURL = parentURL.appendingPathComponent(String(component), isDirectory: true)
                if let childPath = resolvedPath(childURL.path) {
                    guard isContained(childPath, in: rootPath),
                          (try? URL(fileURLWithPath: childPath).resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                    else {
                        throw QDataStreamError.corrupt("target directory escapes sync root or is not a directory")
                    }
                    parentPath = childPath
                } else {
                    try fileManager.createDirectory(at: childURL, withIntermediateDirectories: false)
                    guard let childPath = resolvedPath(childURL.path),
                          isContained(childPath, in: rootPath),
                          (try? URL(fileURLWithPath: childPath).resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                    else {
                        throw QDataStreamError.corrupt("target directory escapes sync root or is not a directory")
                    }
                    parentPath = childPath
                }
            }

            guard isContained(parentPath, in: rootPath) else {
                throw QDataStreamError.corrupt("target directory escapes sync root")
            }
            let target = URL(fileURLWithPath: parentPath, isDirectory: true)
                .appendingPathComponent(String(components.last!))
            let existingPath = resolvedPath(target.path)
            if let existingPath, !isContained(existingPath, in: rootPath) {
                throw QDataStreamError.corrupt("target file escapes sync root")
            }
            if (try? fileManager.destinationOfSymbolicLink(atPath: target.path)) != nil,
               existingPath == nil {
                throw QDataStreamError.corrupt("cannot resolve target symlink")
            }
            try bytes.write(to: target, options: .atomic)
            written.append(relativeName)
        }
        return written.sorted()
    }

    private static func resolvedPath(_ path: String) -> String? {
        guard let pointer = path.withCString({ realpath($0, nil) }) else { return nil }
        defer { free(pointer) }
        return String(cString: pointer)
    }

    private static func isContained(_ path: String, in root: String) -> Bool {
        if path == root { return true }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(prefix)
    }

    /// CopyQ's item ordering: items it created first, newest stamp first,
    /// then foreign names alphabetically.  Nested paths sort after flat ones.
    static func isBaseNameLessThan(_ lhs: String, _ rhs: String) -> Bool {
        let lhsNesting = lhs.filter { $0 == "/" }.count
        let rhsNesting = rhs.filter { $0 == "/" }.count
        if lhsNesting != rhsNesting { return lhsNesting < rhsNesting }

        let lhsOwn = lhs.hasPrefix("copyq_")
        let rhsOwn = rhs.hasPrefix("copyq_")
        if lhsOwn && rhsOwn { return lhs > rhs }
        if lhsOwn { return true }
        if rhsOwn { return false }
        return lhs < rhs
    }
}
