import Darwin
import Foundation
import KeepItCleanCore

public final class LocalFileSystemReader: FileSystemReading, @unchecked Sendable {
    private let measurer: DiskUsageMeasurer

    public init(measurer: DiskUsageMeasurer = DiskUsageMeasurer()) {
        self.measurer = measurer
    }

    public func fileExists(at path: String) -> Bool {
        var value = stat()
        return path.withCString { Darwin.lstat($0, &value) } == 0
    }

    public func identity(at path: String) throws -> FileIdentity {
        try Self.readIdentity(at: path)
    }

    public func usage(at path: String) throws -> DiskUsage {
        try measurer.measure(at: path)
    }

    public func immediateChildren(at path: String) throws -> [String] {
        do {
            return try FileManager.default.contentsOfDirectory(atPath: path)
                .map { URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent($0).path }
                .sorted()
        } catch {
            throw KeepItCleanError.io("Unable to list \(path): \(error.localizedDescription)")
        }
    }

    public func readPrefix(at path: String, maxBytes: Int) throws -> Data {
        guard maxBytes >= 0 else {
            throw KeepItCleanError.io("Invalid read limit for \(path)")
        }
        let descriptor = path.withCString { Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW) }
        guard descriptor >= 0 else {
            throw KeepItCleanError.io("Unable to securely open \(path): \(String(cString: strerror(errno)))")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var value = stat()
        guard Darwin.fstat(descriptor, &value) == 0,
              value.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
        else {
            throw KeepItCleanError.io("Prefix reads require a regular file: \(path)")
        }
        do {
            return try handle.read(upToCount: maxBytes) ?? Data()
        } catch {
            throw KeepItCleanError.io("Unable to read \(path): \(error.localizedDescription)")
        }
    }

    static func readIdentity(at path: String) throws -> FileIdentity {
        var value = stat()
        let result = path.withCString { Darwin.lstat($0, &value) }
        guard result == 0 else {
            throw KeepItCleanError.io("Unable to inspect \(path): \(String(cString: strerror(errno)))")
        }

        let type = value.st_mode & mode_t(S_IFMT)
        let kind: FileKind
        switch type {
        case mode_t(S_IFREG): kind = .regularFile
        case mode_t(S_IFDIR): kind = .directory
        case mode_t(S_IFLNK): kind = .symbolicLink
        default: kind = .other
        }

        let seconds = TimeInterval(value.st_mtimespec.tv_sec)
        let nanoseconds = TimeInterval(value.st_mtimespec.tv_nsec) / 1_000_000_000
        let allocatedBytes = UInt64(max(0, value.st_blocks)) &* 512
        let linkCount = UInt64(value.st_nlink)
        return FileIdentity(
            device: normalizedDeviceID(value.st_dev),
            inode: UInt64(value.st_ino),
            ownerID: value.st_uid,
            fileKind: kind,
            logicalBytes: UInt64(max(0, value.st_size)),
            allocatedBytes: allocatedBytes,
            modifiedAt: Date(timeIntervalSince1970: seconds + nanoseconds),
            linkCount: linkCount,
            reclaimableBytes: kind == .regularFile && linkCount > 1 ? 0 : allocatedBytes
        )
    }

    /// Darwin exposes `dev_t` as a signed 32-bit integer even though device
    /// identifiers are opaque bit patterns. Preserve those bits when widening
    /// so device IDs with the high bit set do not trap during UInt conversion.
    static func normalizedDeviceID(_ device: dev_t) -> UInt64 {
        UInt64(UInt32(bitPattern: device))
    }
}

public struct DiskUsageMeasurer: Sendable {
    public let maximumEntries: Int

    public init(maximumEntries: Int = 1_000_000) {
        self.maximumEntries = max(1, maximumEntries)
    }

    public func measure(at rootPath: String) throws -> DiskUsage {
        let root = try LocalFileSystemReader.readIdentity(at: rootPath)
        guard root.fileKind != .symbolicLink else {
            throw KeepItCleanError.symbolicLink(rootPath)
        }

        struct InodeKey: Hashable {
            let device: UInt64
            let inode: UInt64
        }

        var stack = [rootPath]
        var visited = Set<InodeKey>()
        var hardlinks: [InodeKey: (expected: UInt64, seen: UInt64, allocated: UInt64)] = [:]
        var usage = DiskUsage.zero
        var entries = 0

        while let path = stack.popLast() {
            entries += 1
            guard entries <= maximumEntries else {
                throw KeepItCleanError.io("Scan entry budget exceeded at \(rootPath)")
            }

            let identity = try LocalFileSystemReader.readIdentity(at: path)
            guard identity.device == root.device else {
                throw KeepItCleanError.mountRoot(path)
            }
            let key = InodeKey(device: identity.device, inode: identity.inode)
            let isUnique = visited.insert(key).inserted

            // Apparent/logical size counts every directory entry. Allocated
            // bytes and unique inode count are deduplicated, which is the
            // amount actually reclaimable from a hardlinked tree.
            usage.logicalBytes = usage.logicalBytes &+ identity.logicalBytes
            usage.fileCount = usage.fileCount &+ 1
            if isUnique {
                usage.allocatedBytes = usage.allocatedBytes &+ identity.allocatedBytes
                usage.reclaimableBytes = usage.reclaimableBytes &+ identity.allocatedBytes
                usage.uniqueFileCount = usage.uniqueFileCount &+ 1
            }
            if identity.fileKind == .regularFile, identity.linkCount > 1 {
                var links = hardlinks[key] ?? (
                    expected: identity.linkCount,
                    seen: 0,
                    allocated: identity.allocatedBytes
                )
                links.expected = max(links.expected, identity.linkCount)
                links.seen = links.seen &+ 1
                hardlinks[key] = links
            }

            guard identity.fileKind == .directory else { continue }
            guard isUnique else { continue }
            do {
                let names = try FileManager.default.contentsOfDirectory(atPath: path)
                let base = URL(fileURLWithPath: path, isDirectory: true)
                for name in names {
                    let child = base.appendingPathComponent(name).path
                    stack.append(child)
                }
            } catch let error as KeepItCleanError {
                throw error
            } catch {
                throw KeepItCleanError.io("Unable to traverse \(path): \(error.localizedDescription)")
            }
        }
        for links in hardlinks.values where links.seen < links.expected {
            usage.reclaimableBytes = usage.reclaimableBytes >= links.allocated
                ? usage.reclaimableBytes - links.allocated
                : 0
        }
        return usage
    }
}
