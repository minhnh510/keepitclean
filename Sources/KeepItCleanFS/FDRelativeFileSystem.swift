import Darwin
import Foundation
import KeepItCleanCore

@_silgen_name("flock")
private func keepItCleanFlock(_ descriptor: Int32, _ operation: Int32) -> Int32

/// The result of an fd-relative rename. The returned destination is the exact
/// directory entry that was created, including any collision-avoidance prefix.
public struct FDRelativeRenameResult: Hashable, Sendable {
    public let sourcePath: String
    public let destinationPath: String
    public let identity: FileIdentity

    public init(sourcePath: String, destinationPath: String, identity: FileIdentity) {
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
        self.identity = identity
    }
}

/// An advisory cross-process lock held on a securely opened directory inode.
/// Every KeepItClean filesystem mutation takes this lock in addition to the
/// in-process gateway lock, preventing two `keep` processes from interleaving
/// journal and Trash operations.
public final class FDRelativeDirectoryLock: @unchecked Sendable {
    private let descriptor: Int32

    fileprivate init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        _ = keepItCleanFlock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
    }
}

/// Test/audit checkpoints for deterministic namespace-race regression tests.
/// Raw descriptors are intentionally not exposed outside this implementation.
enum FDRelativeMutationCheckpoint: Sendable {
    case targetInspectedBeforeOpen
    case sourceParentOpened
    case destinationParentOpened
    case sourceVerifiedBeforeRename
    case renameCompletedBeforeDestinationVerification
    case destinationVerifiedAfterRename
    case targetVerifiedBeforeUnlink
}

struct FDRelativeMutationContext: Sendable {
    let sourcePath: String
    let destinationPath: String?
    let expectedIdentity: FileIdentity
}

protocol FDRelativeMutationObserving: Sendable {
    func reached(
        _ checkpoint: FDRelativeMutationCheckpoint,
        context: FDRelativeMutationContext
    ) throws
}

private struct NoopFDRelativeMutationObserver: FDRelativeMutationObserving {
    func reached(
        _: FDRelativeMutationCheckpoint,
        context _: FDRelativeMutationContext
    ) throws {}
}

/// POSIX filesystem operations whose path resolution is anchored to already
/// opened directory descriptors.
///
/// Every ancestor is opened with `O_NOFOLLOW | O_DIRECTORY`; final entries are
/// inspected with `fstatat(..., AT_SYMLINK_NOFOLLOW)` and an opened target is
/// checked with `fstat`. Renames use `renameatx_np(..., RENAME_EXCL)` so a
/// concurrently created destination can never be overwritten.
///
/// This type is deliberately policy-free. Callers must first apply
/// `PathValidator` (allowed roots, protected roots, owner and mount policy),
/// then pass the reviewed `FileIdentity` to the mutation method.
public struct FDRelativeFileSystem: Sendable {
    public let maximumCollisionAttempts: Int
    private let observer: any FDRelativeMutationObserving

    public init(maximumCollisionAttempts: Int = 128) {
        self.maximumCollisionAttempts = max(1, maximumCollisionAttempts)
        observer = NoopFDRelativeMutationObserver()
    }

    init(
        maximumCollisionAttempts: Int = 128,
        observer: any FDRelativeMutationObserving
    ) {
        self.maximumCollisionAttempts = max(1, maximumCollisionAttempts)
        self.observer = observer
    }

    /// Resolves an absolute path without following a symlink in any component
    /// and returns the identity obtained from its opened descriptor.
    public func identity(atAbsolutePath rawPath: String) throws -> FileIdentity {
        let path = try ParsedAbsolutePath(rawPath)
        let parent = try openDirectory(path.parentComponents, displayPath: path.parentPath)
        return try verifiedIdentity(parent: parent.rawValue, name: path.basename, path: path.path)
    }

    /// Creates (if absent) and opens a private directory without following any
    /// pathname component. Existing directories must already be owned by the
    /// requested uid and must not grant group/world access.
    @discardableResult
    public func ensurePrivateDirectory(
        atAbsolutePath rawPath: String,
        ownerID: UInt32,
        expectedDevice: UInt64? = nil
    ) throws -> FileIdentity {
        let path = try ParsedAbsolutePath(rawPath)
        let parent = try openDirectory(path.parentComponents, displayPath: path.parentPath)
        let parentIdentity = try identity(descriptor: parent.rawValue, path: path.parentPath)
        guard parentIdentity.fileKind == .directory,
              parentIdentity.ownerID == ownerID
        else {
            throw KeepItCleanError.ownerMismatch(path.parentPath)
        }
        if let expectedDevice, parentIdentity.device != expectedDevice {
            throw KeepItCleanError.mountRoot(path.parentPath)
        }

        var created = false
        var metadata = stat()
        let lookup = path.basename.withCString {
            Darwin.fstatat(
                parent.rawValue,
                $0,
                &metadata,
                AT_SYMLINK_NOFOLLOW | AT_REALDEV
            )
        }
        if lookup != 0 {
            guard errno == ENOENT else {
                throw posixError("Unable to inspect private directory \(path.path)")
            }
            let made = path.basename.withCString {
                Darwin.mkdirat(parent.rawValue, $0, mode_t(0o700))
            }
            guard made == 0 else {
                throw posixError("Unable to create private directory \(path.path)")
            }
            created = true
        }

        let opened = try openTarget(
            parent: parent.rawValue,
            name: path.basename,
            path: path.path,
            kind: .directory
        )
        guard Darwin.fstat(opened.rawValue, &metadata) == 0 else {
            throw posixError("Unable to inspect private directory \(path.path)")
        }
        let directoryIdentity = makeIdentity(metadata)
        guard directoryIdentity.fileKind == .directory,
              directoryIdentity.ownerID == ownerID
        else {
            throw KeepItCleanError.ownerMismatch(path.path)
        }
        if let expectedDevice, directoryIdentity.device != expectedDevice {
            throw KeepItCleanError.mountRoot(path.path)
        }
        if created {
            guard Darwin.fchmod(opened.rawValue, mode_t(0o700)) == 0 else {
                throw posixError("Unable to protect private directory \(path.path)")
            }
        } else {
            guard metadata.st_mode & mode_t(0o077) == 0 else {
                throw KeepItCleanError.io(
                    "Private directory grants group/world access: \(path.path)"
                )
            }
        }
        try requireDirectoryBinding(
            descriptor: opened.rawValue,
            components: path.components,
            path: path.path
        )
        return directoryIdentity
    }

    /// Takes an advisory lock on the exact directory inode opened through the
    /// no-symlink fd walk. The returned object owns the duplicated descriptor.
    public func acquireExclusiveLock(
        atDirectoryAbsolutePath rawPath: String,
        ownerID: UInt32
    ) throws -> FDRelativeDirectoryLock {
        let directory = try ParsedAbsoluteDirectory(rawPath)
        let opened = try openDirectory(directory.components, displayPath: directory.path)
        let current = try identity(descriptor: opened.rawValue, path: directory.path)
        guard current.fileKind == .directory, current.ownerID == ownerID else {
            throw KeepItCleanError.ownerMismatch(directory.path)
        }
        guard keepItCleanFlock(opened.rawValue, LOCK_EX) == 0 else {
            throw posixError("Unable to lock \(directory.path)")
        }
        let retained = Darwin.dup(opened.rawValue)
        guard retained >= 0 else {
            _ = keepItCleanFlock(opened.rawValue, LOCK_UN)
            throw posixError("Unable to retain lock for \(directory.path)")
        }
        return FDRelativeDirectoryLock(descriptor: retained)
    }

    /// Recursively removes a captured item only after proving that its parent
    /// is the operation-owned private directory supplied by the caller. All
    /// traversal and deletion syscalls remain relative to retained directory
    /// descriptors and never follow symlinks or cross a device boundary.
    public func removeCapturedItemRecursively(
        atAbsolutePath rawPath: String,
        expectedIdentity: FileIdentity,
        privateParentAbsolutePath rawPrivateParent: String,
        ownerID: UInt32,
        maximumEntries: Int = 1_000_000
    ) throws {
        let path = try ParsedAbsolutePath(rawPath)
        let privateParent = try ParsedAbsoluteDirectory(rawPrivateParent)
        guard path.parentPath == privateParent.path else {
            throw KeepItCleanError.protectedPath(path.path)
        }
        let parent = try openDirectory(privateParent.components, displayPath: privateParent.path)
        let parentIdentity = try identity(descriptor: parent.rawValue, path: privateParent.path)
        guard parentIdentity.fileKind == .directory,
              parentIdentity.ownerID == ownerID,
              parentIdentity.device == expectedIdentity.device
        else {
            throw KeepItCleanError.ownerMismatch(privateParent.path)
        }
        var parentMetadata = stat()
        guard Darwin.fstat(parent.rawValue, &parentMetadata) == 0,
              parentMetadata.st_mode & mode_t(0o077) == 0
        else {
            throw KeepItCleanError.io(
                "Finalize quarantine is not private: \(privateParent.path)"
            )
        }

        var visited = 0
        try removeEntryRecursively(
            parent: parent.rawValue,
            name: path.basename,
            displayPath: path.path,
            expectedIdentity: expectedIdentity,
            rootDevice: expectedIdentity.device,
            ownerID: ownerID,
            maximumEntries: max(1, maximumEntries),
            visited: &visited
        )
    }

    /// Atomically renames an entry to an exact, currently unoccupied path.
    /// Neither source nor destination ancestors are resolved again by pathname.
    @discardableResult
    public func renameExclusively(
        fromAbsolutePath rawSourcePath: String,
        expectedIdentity: FileIdentity,
        toAbsolutePath rawDestinationPath: String
    ) throws -> FDRelativeRenameResult {
        let source = try ParsedAbsolutePath(rawSourcePath)
        let destination = try ParsedAbsolutePath(rawDestinationPath)
        guard source.path != destination.path else {
            throw KeepItCleanError.invalidPath("Source and destination are identical: \(source.path)")
        }

        let sourceParent = try openDirectory(
            source.parentComponents,
            displayPath: source.parentPath
        )
        let context = FDRelativeMutationContext(
            sourcePath: source.path,
            destinationPath: destination.path,
            expectedIdentity: expectedIdentity
        )
        try observer.reached(.sourceParentOpened, context: context)
        let destinationParent = try openDirectory(
            destination.parentComponents,
            displayPath: destination.parentPath
        )
        try observer.reached(.destinationParentOpened, context: context)
        try requireExpectedIdentity(
            parent: sourceParent.rawValue,
            name: source.basename,
            path: source.path,
            expected: expectedIdentity
        )
        try observer.reached(.sourceVerifiedBeforeRename, context: context)
        try requireDirectoryBinding(
            descriptor: sourceParent.rawValue,
            components: source.parentComponents,
            path: source.parentPath
        )
        try requireDirectoryBinding(
            descriptor: destinationParent.rawValue,
            components: destination.parentComponents,
            path: destination.parentPath
        )

        let result = try exclusiveRename(
            sourceParent: sourceParent.rawValue,
            sourceName: source.basename,
            destinationParent: destinationParent.rawValue,
            destinationName: destination.basename,
            sourcePath: source.path,
            destinationPath: destination.path
        )
        guard result == .renamed else {
            throw KeepItCleanError.io("Destination is occupied: \(destination.path)")
        }
        return try verifyRenameOrRollback(
            source: source,
            sourceParent: sourceParent.rawValue,
            destination: destination,
            destinationParent: destinationParent.rawValue,
            expectedIdentity: expectedIdentity
        )
    }

    /// Renames an entry into a directory without overwriting an existing item.
    /// The preferred basename is tried first, followed by UUID-prefixed names.
    @discardableResult
    public func renameWithUniqueName(
        fromAbsolutePath rawSourcePath: String,
        expectedIdentity: FileIdentity,
        toDirectoryAbsolutePath rawDestinationDirectory: String,
        preferredBasename: String? = nil
    ) throws -> FDRelativeRenameResult {
        let source = try ParsedAbsolutePath(rawSourcePath)
        let destinationDirectory = try ParsedAbsoluteDirectory(rawDestinationDirectory)
        let preferred = try validateBasename(preferredBasename ?? source.basename)

        let sourceParent = try openDirectory(
            source.parentComponents,
            displayPath: source.parentPath
        )
        let context = FDRelativeMutationContext(
            sourcePath: source.path,
            destinationPath: destinationDirectory.appending(preferred),
            expectedIdentity: expectedIdentity
        )
        try observer.reached(.sourceParentOpened, context: context)
        let destinationParent = try openDirectory(
            destinationDirectory.components,
            displayPath: destinationDirectory.path
        )
        try observer.reached(.destinationParentOpened, context: context)
        try requireExpectedIdentity(
            parent: sourceParent.rawValue,
            name: source.basename,
            path: source.path,
            expected: expectedIdentity
        )
        try observer.reached(.sourceVerifiedBeforeRename, context: context)

        for attempt in 0..<maximumCollisionAttempts {
            let destinationName = attempt == 0
                ? preferred
                : "\(UUID().uuidString)-\(preferred)"
            let destinationPath = destinationDirectory.appending(destinationName)
            try requireDirectoryBinding(
                descriptor: sourceParent.rawValue,
                components: source.parentComponents,
                path: source.parentPath
            )
            try requireDirectoryBinding(
                descriptor: destinationParent.rawValue,
                components: destinationDirectory.components,
                path: destinationDirectory.path
            )
            if attempt > 0 {
                try requireExpectedIdentity(
                    parent: sourceParent.rawValue,
                    name: source.basename,
                    path: source.path,
                    expected: expectedIdentity
                )
            }
            let result = try exclusiveRename(
                sourceParent: sourceParent.rawValue,
                sourceName: source.basename,
                destinationParent: destinationParent.rawValue,
                destinationName: destinationName,
                sourcePath: source.path,
                destinationPath: destinationPath
            )
            if result == .collision { continue }
            let destination = try ParsedAbsolutePath(destinationPath)
            return try verifyRenameOrRollback(
                source: source,
                sourceParent: sourceParent.rawValue,
                destination: destination,
                destinationParent: destinationParent.rawValue,
                expectedIdentity: expectedIdentity
            )
        }
        throw KeepItCleanError.io(
            "Unable to allocate a collision-free destination in \(destinationDirectory.path)"
        )
    }

    /// Removes one regular file or one empty directory with `unlinkat`. The
    /// target and every ancestor are opened without following symlinks.
    /// Recursive directory deletion is intentionally not part of this API.
    ///
    /// POSIX does not provide an inode-conditional `unlinkat`; callers should
    /// use this only in a namespace they exclusively control (KeepItClean uses
    /// an operation-owned Trash/quarantine entry) and keep the operation lock.
    public func unlinkFileOrEmptyDirectory(
        atAbsolutePath rawPath: String,
        expectedIdentity: FileIdentity
    ) throws {
        let path = try ParsedAbsolutePath(rawPath)
        let parent = try openDirectory(path.parentComponents, displayPath: path.parentPath)
        let opened = try openVerifiedTarget(
            parent: parent.rawValue,
            name: path.basename,
            path: path.path,
            expected: expectedIdentity
        )

        let flags: Int32
        switch expectedIdentity.fileKind {
        case .regularFile:
            flags = 0
        case .directory:
            flags = AT_REMOVEDIR
        case .symbolicLink:
            throw KeepItCleanError.symbolicLink(path.path)
        case .other:
            throw KeepItCleanError.unsupported(
                "Only regular files and empty directories can be removed fd-relatively: \(path.path)"
            )
        }

        // Recheck the directory entry after opening it and immediately before
        // unlinkat. Keeping `opened` alive also lets us verify that the reviewed
        // inode, rather than a replacement name, lost a directory link.
        try requireExpectedIdentity(
            parent: parent.rawValue,
            name: path.basename,
            path: path.path,
            expected: expectedIdentity
        )
        try observer.reached(
            .targetVerifiedBeforeUnlink,
            context: FDRelativeMutationContext(
                sourcePath: path.path,
                destinationPath: nil,
                expectedIdentity: expectedIdentity
            )
        )
        let before = try identity(descriptor: opened.rawValue, path: path.path)
        guard expectedIdentity.matchesForMutation(before) else {
            throw KeepItCleanError.identityChanged(path.path)
        }

        let result = path.basename.withCString {
            Darwin.unlinkat(parent.rawValue, $0, flags)
        }
        guard result == 0 else {
            throw posixError("Unable to remove \(path.path)")
        }

        let after = try identity(descriptor: opened.rawValue, path: path.path)
        guard after.device == expectedIdentity.device,
              after.inode == expectedIdentity.inode,
              after.ownerID == expectedIdentity.ownerID,
              after.fileKind == expectedIdentity.fileKind
        else {
            throw KeepItCleanError.identityChanged(path.path)
        }
        if expectedIdentity.fileKind == .regularFile {
            guard after.linkCount < before.linkCount else {
                throw KeepItCleanError.identityChanged(path.path)
            }
        } else {
            var replacement = stat()
            let lookup = path.basename.withCString {
                Darwin.fstatat(parent.rawValue, $0, &replacement, AT_SYMLINK_NOFOLLOW)
            }
            guard lookup != 0, errno == ENOENT else {
                throw KeepItCleanError.identityChanged(path.path)
            }
        }
    }

    // MARK: - Descriptor-relative resolution

    private func openDirectory(
        _ components: [String],
        displayPath: String
    ) throws -> OwnedFileDescriptor {
        let root = Darwin.open("/", O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_DIRECTORY)
        guard root >= 0 else {
            throw posixError("Unable to open filesystem root")
        }
        var current = OwnedFileDescriptor(root)
        var walked = ""

        for component in components {
            walked += "/\(component)"
            let next = component.withCString {
                Darwin.openat(
                    current.rawValue,
                    $0,
                    O_SEARCH | O_CLOEXEC | O_NOFOLLOW | O_DIRECTORY
                )
            }
            guard next >= 0 else {
                if errno == ELOOP {
                    throw KeepItCleanError.symbolicLink(walked)
                }
                throw posixError("Unable to securely open directory \(walked)")
            }
            current = OwnedFileDescriptor(next)
        }

        var metadata = stat()
        guard Darwin.fstat(current.rawValue, &metadata) == 0 else {
            throw posixError("Unable to inspect directory \(displayPath)")
        }
        guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
            throw KeepItCleanError.invalidPath("Not a directory: \(displayPath)")
        }
        return current
    }

    private func verifiedIdentity(parent: Int32, name: String, path: String) throws -> FileIdentity {
        let entry = try identityAt(parent: parent, name: name, path: path)
        guard entry.fileKind != .symbolicLink else {
            throw KeepItCleanError.symbolicLink(path)
        }
        try observer.reached(
            .targetInspectedBeforeOpen,
            context: FDRelativeMutationContext(
                sourcePath: path,
                destinationPath: nil,
                expectedIdentity: entry
            )
        )
        let opened = try openTarget(parent: parent, name: name, path: path, kind: entry.fileKind)
        let descriptorIdentity = try identity(descriptor: opened.rawValue, path: path)
        guard entry.matchesForMutation(descriptorIdentity) else {
            throw KeepItCleanError.identityChanged(path)
        }
        return descriptorIdentity
    }

    private func requireExpectedIdentity(
        parent: Int32,
        name: String,
        path: String,
        expected: FileIdentity
    ) throws {
        let current = try verifiedIdentity(parent: parent, name: name, path: path)
        guard expected.matchesForMutation(current) else {
            throw KeepItCleanError.identityChanged(path)
        }
    }

    private func openVerifiedTarget(
        parent: Int32,
        name: String,
        path: String,
        expected: FileIdentity
    ) throws -> OwnedFileDescriptor {
        let entry = try identityAt(parent: parent, name: name, path: path)
        guard entry.fileKind != .symbolicLink else {
            throw KeepItCleanError.symbolicLink(path)
        }
        guard expected.matchesForMutation(entry) else {
            throw KeepItCleanError.identityChanged(path)
        }
        try observer.reached(
            .targetInspectedBeforeOpen,
            context: FDRelativeMutationContext(
                sourcePath: path,
                destinationPath: nil,
                expectedIdentity: expected
            )
        )
        let opened = try openTarget(parent: parent, name: name, path: path, kind: entry.fileKind)
        let descriptorIdentity = try identity(descriptor: opened.rawValue, path: path)
        guard expected.matchesForMutation(descriptorIdentity) else {
            throw KeepItCleanError.identityChanged(path)
        }
        return opened
    }

    private func openTarget(
        parent: Int32,
        name: String,
        path: String,
        kind: FileKind
    ) throws -> OwnedFileDescriptor {
        let typeFlag = kind == .directory ? O_DIRECTORY : 0
        let nonblockingFlag = kind == .directory ? 0 : O_NONBLOCK
        let descriptor = name.withCString {
            Darwin.openat(
                parent,
                $0,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW | typeFlag | nonblockingFlag
            )
        }
        guard descriptor >= 0 else {
            if errno == ELOOP { throw KeepItCleanError.symbolicLink(path) }
            throw posixError("Unable to securely open \(path)")
        }
        return OwnedFileDescriptor(descriptor)
    }

    private func identityAt(parent: Int32, name: String, path: String) throws -> FileIdentity {
        var metadata = stat()
        let result = name.withCString {
            Darwin.fstatat(
                parent,
                $0,
                &metadata,
                AT_SYMLINK_NOFOLLOW | AT_REALDEV
            )
        }
        guard result == 0 else {
            throw posixError("Unable to inspect \(path)")
        }
        return makeIdentity(metadata)
    }

    private func identity(descriptor: Int32, path: String) throws -> FileIdentity {
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0 else {
            throw posixError("Unable to inspect opened target \(path)")
        }
        return makeIdentity(metadata)
    }

    /// Ensures the lexical directory path still names the directory represented
    /// by the descriptor. An fd stays valid after its directory is renamed, so
    /// this binding check prevents returning a stale path after a parent swap.
    private func requireDirectoryBinding(
        descriptor: Int32,
        components: [String],
        path: String
    ) throws {
        let reopened = try openDirectory(components, displayPath: path)
        var heldMetadata = stat()
        var reopenedMetadata = stat()
        guard Darwin.fstat(descriptor, &heldMetadata) == 0,
              Darwin.fstat(reopened.rawValue, &reopenedMetadata) == 0
        else {
            throw posixError("Unable to verify directory binding for \(path)")
        }
        guard heldMetadata.st_dev == reopenedMetadata.st_dev,
              heldMetadata.st_ino == reopenedMetadata.st_ino
        else {
            throw KeepItCleanError.identityChanged(path)
        }
    }

    private func makeIdentity(_ metadata: stat) -> FileIdentity {
        let type = metadata.st_mode & mode_t(S_IFMT)
        let kind: FileKind
        switch type {
        case mode_t(S_IFREG): kind = .regularFile
        case mode_t(S_IFDIR): kind = .directory
        case mode_t(S_IFLNK): kind = .symbolicLink
        default: kind = .other
        }

        let seconds = TimeInterval(metadata.st_mtimespec.tv_sec)
        let nanoseconds = TimeInterval(metadata.st_mtimespec.tv_nsec) / 1_000_000_000
        let allocatedBytes = UInt64(max(0, metadata.st_blocks)) &* 512
        let linkCount = UInt64(metadata.st_nlink)
        return FileIdentity(
            device: LocalFileSystemReader.normalizedDeviceID(metadata.st_dev),
            inode: UInt64(metadata.st_ino),
            ownerID: metadata.st_uid,
            fileKind: kind,
            logicalBytes: UInt64(max(0, metadata.st_size)),
            allocatedBytes: allocatedBytes,
            modifiedAt: Date(timeIntervalSince1970: seconds + nanoseconds),
            linkCount: linkCount,
            reclaimableBytes: kind == .regularFile && linkCount > 1 ? 0 : allocatedBytes
        )
    }

    private func removeEntryRecursively(
        parent: Int32,
        name: String,
        displayPath: String,
        expectedIdentity: FileIdentity,
        rootDevice: UInt64,
        ownerID: UInt32,
        maximumEntries: Int,
        visited: inout Int
    ) throws {
        visited += 1
        guard visited <= maximumEntries else {
            throw KeepItCleanError.io(
                "Finalize entry budget exceeded at \(displayPath)"
            )
        }
        let current = try identityAt(parent: parent, name: name, path: displayPath)
        guard expectedIdentity.matchesForMutation(current) else {
            throw KeepItCleanError.identityChanged(displayPath)
        }
        guard current.ownerID == ownerID else {
            throw KeepItCleanError.ownerMismatch(displayPath)
        }
        guard current.device == rootDevice else {
            throw KeepItCleanError.mountRoot(displayPath)
        }

        switch current.fileKind {
        case .symbolicLink:
            try unlinkCapturedEntry(
                parent: parent,
                name: name,
                displayPath: displayPath,
                expectedIdentity: current,
                flags: AT_SYMLINK_NOFOLLOW_ANY
            )

        case .regularFile:
            let opened = try openVerifiedTarget(
                parent: parent,
                name: name,
                path: displayPath,
                expected: current
            )
            try unlinkCapturedEntry(
                parent: parent,
                name: name,
                displayPath: displayPath,
                expectedIdentity: current,
                flags: AT_SYMLINK_NOFOLLOW_ANY
            )
            let after = try identity(descriptor: opened.rawValue, path: displayPath)
            guard after.device == current.device,
                  after.inode == current.inode,
                  after.linkCount < current.linkCount
            else {
                throw KeepItCleanError.identityChanged(displayPath)
            }

        case .directory:
            let opened = try openVerifiedTarget(
                parent: parent,
                name: name,
                path: displayPath,
                expected: current
            )
            let duplicate = Darwin.dup(opened.rawValue)
            guard duplicate >= 0 else {
                throw posixError("Unable to enumerate \(displayPath)")
            }
            guard let stream = Darwin.fdopendir(duplicate) else {
                Darwin.close(duplicate)
                throw posixError("Unable to enumerate \(displayPath)")
            }
            defer { Darwin.closedir(stream) }

            while true {
                errno = 0
                guard let entry = Darwin.readdir(stream) else {
                    guard errno == 0 else {
                        throw posixError("Unable to enumerate \(displayPath)")
                    }
                    break
                }
                let childName = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                    pointer.withMemoryRebound(
                        to: CChar.self,
                        capacity: Int(MAXNAMLEN) + 1
                    ) { String(cString: $0) }
                }
                guard childName != ".", childName != ".." else { continue }
                let checkedName = try validateBasename(childName)
                let childPath = displayPath + "/" + checkedName
                let childIdentity = try identityAt(
                    parent: opened.rawValue,
                    name: checkedName,
                    path: childPath
                )
                try removeEntryRecursively(
                    parent: opened.rawValue,
                    name: checkedName,
                    displayPath: childPath,
                    expectedIdentity: childIdentity,
                    rootDevice: rootDevice,
                    ownerID: ownerID,
                    maximumEntries: maximumEntries,
                    visited: &visited
                )
            }

            let rebound = try identityAt(parent: parent, name: name, path: displayPath)
            guard sameStableObject(current, rebound) else {
                throw KeepItCleanError.identityChanged(displayPath)
            }
            try unlinkCapturedEntry(
                parent: parent,
                name: name,
                displayPath: displayPath,
                expectedIdentity: rebound,
                flags: AT_REMOVEDIR | AT_SYMLINK_NOFOLLOW_ANY,
                compareStableOnly: true
            )

        case .other:
            throw KeepItCleanError.unsupported(
                "Unsupported file kind in finalize quarantine: \(displayPath)"
            )
        }
    }

    private func unlinkCapturedEntry(
        parent: Int32,
        name: String,
        displayPath: String,
        expectedIdentity: FileIdentity,
        flags: Int32,
        compareStableOnly: Bool = false
    ) throws {
        let rebound = try identityAt(parent: parent, name: name, path: displayPath)
        let matches = compareStableOnly
            ? sameStableObject(expectedIdentity, rebound)
            : expectedIdentity.matchesForMutation(rebound)
        guard matches else {
            throw KeepItCleanError.identityChanged(displayPath)
        }
        let result = name.withCString { Darwin.unlinkat(parent, $0, flags) }
        guard result == 0 else {
            throw posixError("Unable to remove captured item \(displayPath)")
        }
    }

    private func sameStableObject(_ lhs: FileIdentity, _ rhs: FileIdentity) -> Bool {
        lhs.device == rhs.device
            && lhs.inode == rhs.inode
            && lhs.ownerID == rhs.ownerID
            && lhs.fileKind == rhs.fileKind
    }

    // MARK: - Mutations

    private enum RenameAttempt {
        case renamed
        case collision
    }

    private func exclusiveRename(
        sourceParent: Int32,
        sourceName: String,
        destinationParent: Int32,
        destinationName: String,
        sourcePath: String,
        destinationPath: String
    ) throws -> RenameAttempt {
        let result = sourceName.withCString { sourcePointer in
            destinationName.withCString { destinationPointer in
                Darwin.renameatx_np(
                    sourceParent,
                    sourcePointer,
                    destinationParent,
                    destinationPointer,
                    UInt32(RENAME_EXCL | RENAME_NOFOLLOW_ANY)
                )
            }
        }
        if result == 0 { return .renamed }
        if errno == EEXIST { return .collision }
        throw posixError("Unable to rename \(sourcePath) to \(destinationPath)")
    }

    private func verifyRenameOrRollback(
        source: ParsedAbsolutePath,
        sourceParent: Int32,
        destination: ParsedAbsolutePath,
        destinationParent: Int32,
        expectedIdentity: FileIdentity
    ) throws -> FDRelativeRenameResult {
        var observedDestination: FileIdentity?
        do {
            try observer.reached(
                .renameCompletedBeforeDestinationVerification,
                context: FDRelativeMutationContext(
                    sourcePath: source.path,
                    destinationPath: destination.path,
                    expectedIdentity: expectedIdentity
                )
            )
            let moved = try verifiedIdentity(
                parent: destinationParent,
                name: destination.basename,
                path: destination.path
            )
            observedDestination = moved
            try requireDirectoryBinding(
                descriptor: sourceParent,
                components: source.parentComponents,
                path: source.parentPath
            )
            try requireDirectoryBinding(
                descriptor: destinationParent,
                components: destination.parentComponents,
                path: destination.parentPath
            )
            guard expectedIdentity.matchesForMutation(moved) else {
                throw KeepItCleanError.identityChanged(destination.path)
            }
            try observer.reached(
                .destinationVerifiedAfterRename,
                context: FDRelativeMutationContext(
                    sourcePath: source.path,
                    destinationPath: destination.path,
                    expectedIdentity: expectedIdentity
                )
            )
            try requireDirectoryBinding(
                descriptor: sourceParent,
                components: source.parentComponents,
                path: source.parentPath
            )
            try requireDirectoryBinding(
                descriptor: destinationParent,
                components: destination.parentComponents,
                path: destination.parentPath
            )
            return FDRelativeRenameResult(
                sourcePath: source.path,
                destinationPath: destination.path,
                identity: moved
            )
        } catch {
            do {
                guard let observedDestination else {
                    throw KeepItCleanError.io(
                        "Destination identity could not be captured safely."
                    )
                }
                let stillCaptured = try verifiedIdentity(
                    parent: destinationParent,
                    name: destination.basename,
                    path: destination.path
                )
                guard observedDestination.matchesForMutation(stillCaptured) else {
                    throw KeepItCleanError.identityChanged(destination.path)
                }
                let rollback = try exclusiveRename(
                    sourceParent: destinationParent,
                    sourceName: destination.basename,
                    destinationParent: sourceParent,
                    destinationName: source.basename,
                    sourcePath: destination.path,
                    destinationPath: source.path
                )
                guard rollback == .renamed else {
                    throw KeepItCleanError.io("Original path is occupied.")
                }
                let restored = try verifiedIdentity(
                    parent: sourceParent,
                    name: source.basename,
                    path: source.path
                )
                guard observedDestination.matchesForMutation(restored) else {
                    throw KeepItCleanError.identityChanged(source.path)
                }
            } catch let rollbackError {
                throw KeepItCleanError.io(
                    "Rename verification failed and automatic rollback could not restore "
                        + "\(source.path). Recover the captured item from \(destination.path). "
                        + "Cause: \(error.localizedDescription). "
                        + "Rollback: \(rollbackError.localizedDescription)"
                )
            }
            throw error
        }
    }

    private func validateBasename(_ name: String) throws -> String {
        guard !name.isEmpty,
              name != ".",
              name != "..",
              !name.contains("/"),
              !name.unicodeScalars.contains(where: { $0.value == 0 || $0.value < 0x20 || $0.value == 0x7F })
        else {
            throw KeepItCleanError.invalidPath("Invalid basename: \(name)")
        }
        return name
    }

    private func posixError(_ context: String) -> KeepItCleanError {
        KeepItCleanError.io("\(context): \(String(cString: strerror(errno)))")
    }
}

private final class OwnedFileDescriptor {
    let rawValue: Int32

    init(_ rawValue: Int32) {
        self.rawValue = rawValue
    }

    deinit {
        Darwin.close(rawValue)
    }
}

private struct ParsedAbsolutePath {
    let path: String
    let components: [String]

    init(_ rawPath: String) throws {
        let parsed = try ParsedAbsoluteDirectory.parse(rawPath, allowRoot: false)
        path = parsed.path
        components = parsed.components
    }

    var basename: String { components.last! }
    var parentComponents: [String] { Array(components.dropLast()) }
    var parentPath: String {
        parentComponents.isEmpty ? "/" : "/" + parentComponents.joined(separator: "/")
    }
}

private struct ParsedAbsoluteDirectory {
    let path: String
    let components: [String]

    init(_ rawPath: String) throws {
        let parsed = try Self.parse(rawPath, allowRoot: true)
        path = parsed.path
        components = parsed.components
    }

    fileprivate init(path: String, components: [String]) {
        self.path = path
        self.components = components
    }

    func appending(_ basename: String) -> String {
        path == "/" ? "/\(basename)" : "\(path)/\(basename)"
    }

    static func parse(
        _ rawPath: String,
        allowRoot: Bool
    ) throws -> ParsedAbsoluteDirectory {
        guard !rawPath.isEmpty,
              rawPath.hasPrefix("/"),
              !rawPath.hasSuffix("/") || rawPath == "/",
              !rawPath.contains("//"),
              !rawPath.unicodeScalars.contains(where: { $0.value == 0 || $0.value < 0x20 || $0.value == 0x7F })
        else {
            throw KeepItCleanError.invalidPath(rawPath)
        }

        let rawComponents = rawPath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !rawComponents.contains("."), !rawComponents.contains("..") else {
            throw KeepItCleanError.invalidPath(rawPath)
        }

        let aliased = PathValidationPolicy.canonicalSystemAlias(rawPath)
        let components = aliased.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard allowRoot || !components.isEmpty else {
            throw KeepItCleanError.protectedPath(aliased)
        }
        return ParsedAbsoluteDirectory(path: components.isEmpty ? "/" : "/" + components.joined(separator: "/"), components: components)
    }
}
