import Darwin
import Foundation
import KeepItCleanCore

final class FixtureHome {
    let url: URL
    private let markerName = ".keepitclean-test-home"

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("keepitclean-rules-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        try Data("fixture-only".utf8).write(to: url.appendingPathComponent(markerName))
    }

    deinit {
        let marker = url.appendingPathComponent(markerName).path
        guard url.path.hasPrefix(FileManager.default.temporaryDirectory.path),
              FileManager.default.fileExists(atPath: marker)
        else { return }
        try? FileManager.default.removeItem(at: url)
    }

    @discardableResult
    func directory(_ relativePath: String) throws -> String {
        let target = url.appendingPathComponent(relativePath, isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        return target.path
    }

    @discardableResult
    func file(_ relativePath: String, contents: String = "fixture") throws -> String {
        let target = url.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: target)
        return target.path
    }

    @discardableResult
    func symbolicLink(_ relativePath: String, to targetRelativePath: String) throws -> String {
        let link = url.appendingPathComponent(relativePath)
        let target = url.appendingPathComponent(targetRelativePath)
        try FileManager.default.createDirectory(
            at: link.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        return link.path
    }

    func markOld(_ relativePath: String, days: Int = 120) throws {
        let target = url.appendingPathComponent(relativePath)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-Double(days) * 86_400)],
            ofItemAtPath: target.path
        )
    }
}

struct FixtureFileSystem: FileSystemReading, Sendable {
    func fileExists(at path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    func identity(at path: String) throws -> FileIdentity {
        var value = stat()
        guard lstat(path, &value) == 0 else {
            throw KeepItCleanError.io("lstat failed for fixture path \(path)")
        }

        let kind: FileKind
        switch value.st_mode & S_IFMT {
        case S_IFREG: kind = .regularFile
        case S_IFDIR: kind = .directory
        case S_IFLNK: kind = .symbolicLink
        default: kind = .other
        }

        return FileIdentity(
            device: UInt64(UInt32(bitPattern: value.st_dev)),
            inode: UInt64(value.st_ino),
            ownerID: value.st_uid,
            fileKind: kind,
            logicalBytes: UInt64(max(0, value.st_size)),
            allocatedBytes: UInt64(max(0, value.st_blocks)) * 512,
            modifiedAt: Date(
                timeIntervalSince1970: TimeInterval(value.st_mtimespec.tv_sec)
                    + TimeInterval(value.st_mtimespec.tv_nsec) / 1_000_000_000
            )
        )
    }

    func usage(at path: String) throws -> DiskUsage {
        let root = try identity(at: path)
        if root.fileKind != .directory {
            return DiskUsage(
                logicalBytes: root.logicalBytes,
                allocatedBytes: root.allocatedBytes,
                fileCount: 1
            )
        }

        var total = DiskUsage(
            logicalBytes: root.logicalBytes,
            allocatedBytes: root.allocatedBytes,
            fileCount: 1
        )
        for child in try immediateChildren(at: path) {
            let childIdentity = try identity(at: child)
            if childIdentity.fileKind == .directory {
                total = total + (try usage(at: child))
            } else {
                total = total + DiskUsage(
                    logicalBytes: childIdentity.logicalBytes,
                    allocatedBytes: childIdentity.allocatedBytes,
                    fileCount: 1
                )
            }
        }
        return total
    }

    func immediateChildren(at path: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: path)
            .map { URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent($0).path }
            .sorted()
    }

    func readPrefix(at path: String, maxBytes: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        return try handle.read(upToCount: maxBytes) ?? Data()
    }
}

struct FixedProcessProbe: ProcessProbing, Sendable {
    let stateValue: ActiveState

    init(_ state: ActiveState) {
        self.stateValue = state
    }

    func state(matching processNames: [String]) -> ActiveState {
        processNames.isEmpty ? .inactive : stateValue
    }
}

struct SelectiveProcessProbe: ProcessProbing, Sendable {
    let activeTerms: Set<String>
    let otherwise: ActiveState

    init(activeTerms: Set<String>, otherwise: ActiveState = .inactive) {
        self.activeTerms = activeTerms
        self.otherwise = otherwise
    }

    func state(matching processNames: [String]) -> ActiveState {
        activeTerms.isDisjoint(with: processNames) ? otherwise : .active
    }
}

struct SymlinkRejectingUsageFileSystem: FileSystemReading, Sendable {
    private let base = FixtureFileSystem()

    func fileExists(at path: String) -> Bool { base.fileExists(at: path) }
    func identity(at path: String) throws -> FileIdentity { try base.identity(at: path) }

    func usage(at path: String) throws -> DiskUsage {
        guard try base.identity(at: path).fileKind != .symbolicLink else {
            throw KeepItCleanError.symbolicLink(path)
        }
        return try base.usage(at: path)
    }

    func immediateChildren(at path: String) throws -> [String] {
        try base.immediateChildren(at: path)
    }

    func readPrefix(at path: String, maxBytes: Int) throws -> Data {
        try base.readPrefix(at: path, maxBytes: maxBytes)
    }
}
