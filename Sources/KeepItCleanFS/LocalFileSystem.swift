import Darwin
import Foundation
import KeepItCleanCore

enum FDRelativeTraversalCheckpoint: Sendable {
    case entryInspectedBeforeOpen
}

struct FDRelativeTraversalContext: Sendable {
    let parentPath: String
    let entryPath: String
    let entryName: String
    let identity: FileIdentity
}

protocol FDRelativeTraversalObserving: Sendable {
    func reached(
        _ checkpoint: FDRelativeTraversalCheckpoint,
        context: FDRelativeTraversalContext
    ) throws
}

private struct NoopFDRelativeTraversalObserver: FDRelativeTraversalObserving {
    func reached(
        _: FDRelativeTraversalCheckpoint,
        context _: FDRelativeTraversalContext
    ) throws {}
}

private final class ReadOnlyFileDescriptor {
    let rawValue: Int32

    init(_ rawValue: Int32) {
        self.rawValue = rawValue
    }

    deinit {
        Darwin.close(rawValue)
    }
}

private struct ParsedReadOnlyPath {
    let path: String
    let components: [String]

    init(_ rawPath: String) throws {
        guard rawPath.hasPrefix("/"), !rawPath.utf8.contains(0) else {
            throw KeepItCleanError.invalidPath(rawPath)
        }
        let rawComponents = rawPath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !rawComponents.contains("."), !rawComponents.contains("..") else {
            throw KeepItCleanError.invalidPath(rawPath)
        }
        // `/var`, `/tmp`, and `/etc` are fixed compatibility symlinks on
        // macOS. Normalize only those OS-owned aliases before the no-follow
        // descriptor walk; all user-controlled symlink components still fail.
        let canonical = PathValidationPolicy.canonicalSystemAlias(rawPath)
        let components = canonical.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        self.components = components
        path = components.isEmpty ? "/" : "/" + components.joined(separator: "/")
    }
}

private enum FDRelativeReadOnly {
    struct OpenedTarget {
        let descriptor: ReadOnlyFileDescriptor
        let identity: FileIdentity
        let canonicalPath: String
    }

    static func identity(atAbsolutePath rawPath: String) throws -> FileIdentity {
        let parsed = try ParsedReadOnlyPath(rawPath)
        guard let basename = parsed.components.last else {
            let root = try openFilesystemRoot()
            return try identity(descriptor: root.rawValue, path: parsed.path)
        }
        let parent = try openDirectory(
            Array(parsed.components.dropLast()),
            displayPath: parentPath(of: parsed)
        )
        return try identityAt(
            parent: parent.rawValue,
            name: basename,
            path: parsed.path
        )
    }

    static func openTraversalRoot(_ rawPath: String) throws -> OpenedTarget {
        let parsed = try ParsedReadOnlyPath(rawPath)
        guard let basename = parsed.components.last else {
            let root = try openFilesystemRoot()
            return OpenedTarget(
                descriptor: root,
                identity: try identity(descriptor: root.rawValue, path: parsed.path),
                canonicalPath: parsed.path
            )
        }

        let parent = try openDirectory(
            Array(parsed.components.dropLast()),
            displayPath: parentPath(of: parsed)
        )
        let entry = try identityAt(parent: parent.rawValue, name: basename, path: parsed.path)
        guard entry.fileKind != .symbolicLink else {
            throw KeepItCleanError.symbolicLink(parsed.path)
        }
        let opened = try openEntry(
            parent: parent.rawValue,
            name: basename,
            path: parsed.path,
            kind: entry.fileKind
        )
        let held = try identity(descriptor: opened.rawValue, path: parsed.path)
        guard sameEntry(entry, held) else {
            throw KeepItCleanError.identityChanged(parsed.path)
        }
        return OpenedTarget(descriptor: opened, identity: held, canonicalPath: parsed.path)
    }

    static func openDirectory(
        _ components: [String],
        displayPath: String
    ) throws -> ReadOnlyFileDescriptor {
        var current = try openFilesystemRoot()
        var walked = ""
        for component in components {
            walked += "/\(component)"
            let descriptor = component.withCString {
                Darwin.openat(
                    current.rawValue,
                    $0,
                    O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_DIRECTORY
                )
            }
            guard descriptor >= 0 else {
                throw openError(path: walked)
            }
            current = ReadOnlyFileDescriptor(descriptor)
        }

        let metadata = try identity(descriptor: current.rawValue, path: displayPath)
        guard metadata.fileKind == .directory else {
            throw KeepItCleanError.invalidPath("Not a directory: \(displayPath)")
        }
        return current
    }

    static func openEntry(
        parent: Int32,
        name: String,
        path: String,
        kind: FileKind
    ) throws -> ReadOnlyFileDescriptor {
        let access = kind == .directory ? O_RDONLY : O_EVTONLY
        let directory = kind == .directory ? O_DIRECTORY : 0
        let descriptor = name.withCString {
            Darwin.openat(parent, $0, access | O_CLOEXEC | O_NOFOLLOW | directory)
        }
        guard descriptor >= 0 else {
            throw openError(path: path)
        }
        return ReadOnlyFileDescriptor(descriptor)
    }

    static func openRegularFileForReading(
        atAbsolutePath rawPath: String
    ) throws -> OpenedTarget {
        let parsed = try ParsedReadOnlyPath(rawPath)
        guard let basename = parsed.components.last else {
            throw KeepItCleanError.io("Prefix reads require a regular file: \(parsed.path)")
        }
        let parent = try openDirectory(
            Array(parsed.components.dropLast()),
            displayPath: parentPath(of: parsed)
        )
        let entry = try identityAt(parent: parent.rawValue, name: basename, path: parsed.path)
        guard entry.fileKind == .regularFile else {
            if entry.fileKind == .symbolicLink {
                throw KeepItCleanError.symbolicLink(parsed.path)
            }
            throw KeepItCleanError.io("Prefix reads require a regular file: \(parsed.path)")
        }
        let descriptor = basename.withCString {
            Darwin.openat(parent.rawValue, $0, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            throw openError(path: parsed.path)
        }
        let opened = ReadOnlyFileDescriptor(descriptor)
        let held = try identity(descriptor: descriptor, path: parsed.path)
        guard sameEntry(entry, held) else {
            throw KeepItCleanError.identityChanged(parsed.path)
        }
        return OpenedTarget(descriptor: opened, identity: held, canonicalPath: parsed.path)
    }

    static func identityAt(parent: Int32, name: String, path: String) throws -> FileIdentity {
        var metadata = stat()
        let result = name.withCString {
            Darwin.fstatat(parent, $0, &metadata, AT_SYMLINK_NOFOLLOW)
        }
        guard result == 0 else {
            throw posixError("Unable to inspect \(path)")
        }
        return makeIdentity(metadata)
    }

    static func identity(descriptor: Int32, path: String) throws -> FileIdentity {
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0 else {
            throw posixError("Unable to inspect opened target \(path)")
        }
        return makeIdentity(metadata)
    }

    static func directoryEntryNames(descriptor: Int32, path: String) throws -> [String] {
        let duplicate = Darwin.dup(descriptor)
        guard duplicate >= 0 else {
            throw posixError("Unable to duplicate directory descriptor for \(path)")
        }
        guard Darwin.fcntl(duplicate, F_SETFD, FD_CLOEXEC) == 0 else {
            let savedError = errno
            Darwin.close(duplicate)
            throw posixError(
                "Unable to protect directory descriptor for \(path)",
                code: savedError
            )
        }
        guard let stream = Darwin.fdopendir(duplicate) else {
            let savedError = errno
            Darwin.close(duplicate)
            throw posixError("Unable to traverse \(path)", code: savedError)
        }
        defer { Darwin.closedir(stream) }

        var names: [String] = []
        while true {
            errno = 0
            guard let entry = Darwin.readdir(stream) else {
                if errno != 0 {
                    throw posixError("Unable to traverse \(path)")
                }
                break
            }
            let name = withUnsafeBytes(of: entry.pointee.d_name) { bytes -> String in
                String(cString: bytes.baseAddress!.assumingMemoryBound(to: CChar.self))
            }
            guard name != ".", name != ".." else { continue }
            names.append(name)
        }
        return names.sorted()
    }

    static func childPath(parent: String, name: String) -> String {
        parent == "/" ? "/\(name)" : "\(parent)/\(name)"
    }

    static func sameEntry(_ lhs: FileIdentity, _ rhs: FileIdentity) -> Bool {
        lhs.device == rhs.device
            && lhs.inode == rhs.inode
            && lhs.ownerID == rhs.ownerID
            && lhs.fileKind == rhs.fileKind
    }

    private static func openFilesystemRoot() throws -> ReadOnlyFileDescriptor {
        let descriptor = Darwin.open("/", O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_DIRECTORY)
        guard descriptor >= 0 else {
            throw posixError("Unable to open filesystem root")
        }
        return ReadOnlyFileDescriptor(descriptor)
    }

    private static func parentPath(of parsed: ParsedReadOnlyPath) -> String {
        let parent = parsed.components.dropLast()
        return parent.isEmpty ? "/" : "/" + parent.joined(separator: "/")
    }

    private static func openError(path: String) -> KeepItCleanError {
        let code = errno
        if code == ELOOP {
            return .symbolicLink(path)
        }
        return posixError("Unable to securely open \(path)", code: code)
    }

    private static func posixError(_ message: String, code: Int32 = errno) -> KeepItCleanError {
        .io("\(message): \(String(cString: strerror(code)))")
    }

    private static func makeIdentity(_ value: stat) -> FileIdentity {
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
            device: LocalFileSystemReader.normalizedDeviceID(value.st_dev),
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
}

public final class LocalFileSystemReader: FileSystemReading, @unchecked Sendable {
    private let measurer: DiskUsageMeasurer

    public init(measurer: DiskUsageMeasurer = DiskUsageMeasurer()) {
        self.measurer = measurer
    }

    public func fileExists(at path: String) -> Bool {
        (try? Self.readIdentity(at: path)) != nil
    }

    public func identity(at path: String) throws -> FileIdentity {
        try Self.readIdentity(at: path)
    }

    public func usage(at path: String) throws -> DiskUsage {
        try measurer.measure(at: path)
    }

    public func immediateChildren(at path: String) throws -> [String] {
        let root = try FDRelativeReadOnly.openTraversalRoot(path)
        guard root.identity.fileKind == .directory else {
            throw KeepItCleanError.invalidPath("Not a directory: \(root.canonicalPath)")
        }
        let names = try FDRelativeReadOnly.directoryEntryNames(
            descriptor: root.descriptor.rawValue,
            path: root.canonicalPath
        )
        return try names.map { name in
            let child = FDRelativeReadOnly.childPath(parent: root.canonicalPath, name: name)
            let identity = try FDRelativeReadOnly.identityAt(
                parent: root.descriptor.rawValue,
                name: name,
                path: child
            )
            guard identity.device == root.identity.device else {
                throw KeepItCleanError.mountRoot(child)
            }
            return child
        }
    }

    public func readPrefix(at path: String, maxBytes: Int) throws -> Data {
        guard maxBytes >= 0 else {
            throw KeepItCleanError.io("Invalid read limit for \(path)")
        }
        let opened = try FDRelativeReadOnly.openRegularFileForReading(atAbsolutePath: path)
        let handle = FileHandle(
            fileDescriptor: opened.descriptor.rawValue,
            closeOnDealloc: false
        )
        do {
            return try handle.read(upToCount: maxBytes) ?? Data()
        } catch {
            throw KeepItCleanError.io("Unable to read \(path): \(error.localizedDescription)")
        }
    }

    static func readIdentity(at path: String) throws -> FileIdentity {
        try FDRelativeReadOnly.identity(atAbsolutePath: path)
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
    private let observer: any FDRelativeTraversalObserving

    public init(maximumEntries: Int = 1_000_000) {
        self.maximumEntries = max(1, maximumEntries)
        observer = NoopFDRelativeTraversalObserver()
    }

    init(
        maximumEntries: Int = 1_000_000,
        observer: any FDRelativeTraversalObserving
    ) {
        self.maximumEntries = max(1, maximumEntries)
        self.observer = observer
    }

    public func measure(at rootPath: String) throws -> DiskUsage {
        let root = try FDRelativeReadOnly.openTraversalRoot(rootPath)
        guard root.identity.fileKind != .symbolicLink else {
            throw KeepItCleanError.symbolicLink(root.canonicalPath)
        }

        struct InodeKey: Hashable {
            let device: UInt64
            let inode: UInt64
        }

        var visited = Set<InodeKey>()
        var hardlinks: [InodeKey: (expected: UInt64, seen: UInt64, allocated: UInt64)] = [:]
        var usage = DiskUsage.zero
        var entries = 0

        func account(_ identity: FileIdentity, path: String) throws -> Bool {
            entries += 1
            guard entries <= maximumEntries else {
                throw KeepItCleanError.io("Scan entry budget exceeded at \(root.canonicalPath)")
            }
            guard identity.device == root.identity.device else {
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
            return isUnique
        }

        func traverseDirectory(
            descriptor: Int32,
            path: String
        ) throws {
            let names = try FDRelativeReadOnly.directoryEntryNames(
                descriptor: descriptor,
                path: path
            )
            for name in names {
                let childPath = FDRelativeReadOnly.childPath(parent: path, name: name)
                let observed = try FDRelativeReadOnly.identityAt(
                    parent: descriptor,
                    name: name,
                    path: childPath
                )
                guard observed.device == root.identity.device else {
                    throw KeepItCleanError.mountRoot(childPath)
                }
                try observer.reached(
                    .entryInspectedBeforeOpen,
                    context: FDRelativeTraversalContext(
                        parentPath: path,
                        entryPath: childPath,
                        entryName: name,
                        identity: observed
                    )
                )

                switch observed.fileKind {
                case .directory, .regularFile:
                    let opened = try FDRelativeReadOnly.openEntry(
                        parent: descriptor,
                        name: name,
                        path: childPath,
                        kind: observed.fileKind
                    )
                    let held = try FDRelativeReadOnly.identity(
                        descriptor: opened.rawValue,
                        path: childPath
                    )
                    guard FDRelativeReadOnly.sameEntry(observed, held) else {
                        throw KeepItCleanError.identityChanged(childPath)
                    }
                    let isUnique = try account(held, path: childPath)
                    if held.fileKind == .directory, isUnique {
                        try traverseDirectory(descriptor: opened.rawValue, path: childPath)
                    }

                case .symbolicLink, .other:
                    // These entries are never opened as traversal roots. A
                    // second no-follow lookup detects a swap without ever
                    // following a replacement symlink.
                    let confirmed = try FDRelativeReadOnly.identityAt(
                        parent: descriptor,
                        name: name,
                        path: childPath
                    )
                    guard FDRelativeReadOnly.sameEntry(observed, confirmed) else {
                        throw KeepItCleanError.identityChanged(childPath)
                    }
                    _ = try account(confirmed, path: childPath)
                }
            }
        }

        let rootIsUnique = try account(root.identity, path: root.canonicalPath)
        if root.identity.fileKind == .directory, rootIsUnique {
            try traverseDirectory(
                descriptor: root.descriptor.rawValue,
                path: root.canonicalPath
            )
        }
        for links in hardlinks.values where links.seen < links.expected {
            usage.reclaimableBytes = usage.reclaimableBytes >= links.allocated
                ? usage.reclaimableBytes - links.allocated
                : 0
        }
        return usage
    }
}
