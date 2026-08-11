import Darwin
import Foundation
import KeepItCleanCore
import Testing
@testable import KeepItCleanFS

private struct FDRelativeFixture {
    static let markerName = ".keepitclean-fd-relative-test-fixture"
    static let markerContents = "KEEPITCLEAN_FD_RELATIVE_TEST_FIXTURE"

    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("keepitclean-fd-relative-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try Data(Self.markerContents.utf8).write(
            to: root.appendingPathComponent(Self.markerName)
        )
    }

    func remove() throws {
        let temporary = FileManager.default.temporaryDirectory.standardizedFileURL.path
        let marker = root.appendingPathComponent(Self.markerName)
        guard root.standardizedFileURL.path.hasPrefix(temporary + "/"),
              root.lastPathComponent.hasPrefix("keepitclean-fd-relative-"),
              (try? String(contentsOf: marker, encoding: .utf8)) == Self.markerContents
        else {
            throw KeepItCleanError.protectedPath(root.path)
        }
        try FileManager.default.removeItem(at: root)
    }
}

private final class FDRelativeCheckpointAction: FDRelativeMutationObserving, @unchecked Sendable {
    private let target: FDRelativeMutationCheckpoint
    private let action: @Sendable () throws -> Void
    private let lock = NSLock()
    private var fired = false

    init(
        target: FDRelativeMutationCheckpoint,
        action: @escaping @Sendable () throws -> Void
    ) {
        self.target = target
        self.action = action
    }

    func reached(
        _ checkpoint: FDRelativeMutationCheckpoint,
        context _: FDRelativeMutationContext
    ) throws {
        guard checkpoint == target else { return }
        lock.lock()
        guard !fired else {
            lock.unlock()
            return
        }
        fired = true
        lock.unlock()
        try action()
    }
}

@Test func fdRelativeIdentityRejectsSymlinkComponents() throws {
    let fixture = try FDRelativeFixture()
    defer { try? fixture.remove() }
    let real = fixture.root.appendingPathComponent("real", isDirectory: true)
    let payload = real.appendingPathComponent("payload")
    let alias = fixture.root.appendingPathComponent("alias", isDirectory: true)
    try FileManager.default.createDirectory(at: real, withIntermediateDirectories: false)
    try Data("preserve".utf8).write(to: payload)
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)

    let filesystem = FDRelativeFileSystem()
    let direct = try filesystem.identity(atAbsolutePath: payload.path)

    #expect(direct.fileKind == .regularFile)
    #expect(throws: (any Error).self) {
        _ = try filesystem.identity(
            atAbsolutePath: alias.appendingPathComponent("payload").path
        )
    }
    #expect(try String(contentsOf: payload, encoding: .utf8) == "preserve")
}

@Test func fdRelativeOpenDoesNotBlockWhenRegularLeafBecomesFIFO() throws {
    let fixture = try FDRelativeFixture()
    defer { try? fixture.remove() }
    let source = fixture.root.appendingPathComponent("reviewed-source")
    let displaced = fixture.root.appendingPathComponent("reviewed-source-displaced")
    try Data("reviewed".utf8).write(to: source)

    let observer = FDRelativeCheckpointAction(target: .targetInspectedBeforeOpen) {
        try FileManager.default.moveItem(at: source, to: displaced)
        guard source.path.withCString({ Darwin.mkfifo($0, mode_t(0o600)) }) == 0 else {
            throw KeepItCleanError.io("Unable to create FIFO race fixture")
        }
    }
    let filesystem = FDRelativeFileSystem(observer: observer)

    #expect(throws: KeepItCleanError.self) {
        _ = try filesystem.identity(atAbsolutePath: source.path)
    }
    var metadata = stat()
    #expect(source.path.withCString { Darwin.lstat($0, &metadata) } == 0)
    #expect(metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFIFO))
    #expect(try String(contentsOf: displaced, encoding: .utf8) == "reviewed")
}

@Test func fdRelativeUniqueRenameNeverOverwritesCollisionAndRestoresExactly() throws {
    let fixture = try FDRelativeFixture()
    defer { try? fixture.remove() }
    let sourceParent = fixture.root.appendingPathComponent("source", isDirectory: true)
    let source = sourceParent.appendingPathComponent("cache", isDirectory: true)
    let trash = fixture.root.appendingPathComponent("trash", isDirectory: true)
    let collision = trash.appendingPathComponent("cache", isDirectory: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: collision, withIntermediateDirectories: true)
    try Data("reviewed".utf8).write(to: source.appendingPathComponent("payload"))
    try Data("existing".utf8).write(to: collision.appendingPathComponent("payload"))

    let reader = LocalFileSystemReader()
    let reviewed = try reader.identity(at: source.path)
    let filesystem = FDRelativeFileSystem()
    let moved = try filesystem.renameWithUniqueName(
        fromAbsolutePath: source.path,
        expectedIdentity: reviewed,
        toDirectoryAbsolutePath: trash.path
    )

    #expect(moved.destinationPath != collision.path)
    #expect(URL(fileURLWithPath: moved.destinationPath).lastPathComponent.hasSuffix("-cache"))
    #expect(!reader.fileExists(at: source.path))
    #expect(try String(contentsOf: collision.appendingPathComponent("payload"), encoding: .utf8) == "existing")
    #expect(reviewed.matchesForMutation(try filesystem.identity(atAbsolutePath: moved.destinationPath)))

    let restored = try filesystem.renameExclusively(
        fromAbsolutePath: moved.destinationPath,
        expectedIdentity: reviewed,
        toAbsolutePath: source.path
    )
    #expect(restored.destinationPath == PathValidationPolicy.canonicalSystemAlias(source.path))
    #expect(reviewed.matchesForMutation(try reader.identity(at: source.path)))
    #expect(try String(contentsOf: source.appendingPathComponent("payload"), encoding: .utf8) == "reviewed")
}

@Test func fdRelativeRenameDetectsDeterministicLeafSwapAndRollsBackReplacement() throws {
    let fixture = try FDRelativeFixture()
    defer { try? fixture.remove() }
    let source = fixture.root.appendingPathComponent("reviewed-source")
    let capturedReviewedItem = fixture.root.appendingPathComponent("attacker-captured-reviewed-item")
    let destination = fixture.root.appendingPathComponent("trash-destination")
    try Data("reviewed-inode".utf8).write(to: source)

    let reader = LocalFileSystemReader()
    let reviewed = try reader.identity(at: source.path)
    let observer = FDRelativeCheckpointAction(target: .sourceVerifiedBeforeRename) {
        try FileManager.default.moveItem(at: source, to: capturedReviewedItem)
        try Data("replacement-inode".utf8).write(to: source)
    }
    let filesystem = FDRelativeFileSystem(observer: observer)

    #expect(throws: KeepItCleanError.self) {
        _ = try filesystem.renameExclusively(
            fromAbsolutePath: source.path,
            expectedIdentity: reviewed,
            toAbsolutePath: destination.path
        )
    }

    // If the swap lands after the final identity check, destination verification
    // detects the inode mismatch and the exclusive rollback restores replacement.
    #expect(try String(contentsOf: source, encoding: .utf8) == "replacement-inode")
    #expect(try String(contentsOf: capturedReviewedItem, encoding: .utf8) == "reviewed-inode")
    #expect(!reader.fileExists(at: destination.path))
    #expect(!reviewed.matchesForMutation(try reader.identity(at: source.path)))
    #expect(reviewed.matchesForMutation(try reader.identity(at: capturedReviewedItem.path)))
}

@Test func fdRelativeRenameRejectsDestinationParentSwapWithoutTouchingExternalTree() throws {
    let fixture = try FDRelativeFixture()
    defer { try? fixture.remove() }
    let trash = fixture.root.appendingPathComponent("trash", isDirectory: true)
    let source = trash.appendingPathComponent("reviewed-item")
    let destinationParent = fixture.root.appendingPathComponent("original-parent", isDirectory: true)
    let displacedParent = fixture.root.appendingPathComponent("displaced-original-parent", isDirectory: true)
    let external = fixture.root.appendingPathComponent("external", isDirectory: true)
    let externalSentinel = external.appendingPathComponent("sentinel")
    let destination = destinationParent.appendingPathComponent("reviewed-item")
    try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: false)
    try FileManager.default.createDirectory(at: destinationParent, withIntermediateDirectories: false)
    try FileManager.default.createDirectory(at: external, withIntermediateDirectories: false)
    try Data("trash-payload".utf8).write(to: source)
    try Data("external-must-remain".utf8).write(to: externalSentinel)

    let reader = LocalFileSystemReader()
    let reviewed = try reader.identity(at: source.path)
    let observer = FDRelativeCheckpointAction(target: .destinationParentOpened) {
        try FileManager.default.moveItem(at: destinationParent, to: displacedParent)
        try FileManager.default.createSymbolicLink(at: destinationParent, withDestinationURL: external)
    }
    let filesystem = FDRelativeFileSystem(observer: observer)

    #expect(throws: KeepItCleanError.self) {
        _ = try filesystem.renameExclusively(
            fromAbsolutePath: source.path,
            expectedIdentity: reviewed,
            toAbsolutePath: destination.path
        )
    }

    #expect(reviewed.matchesForMutation(try reader.identity(at: source.path)))
    #expect(try String(contentsOf: source, encoding: .utf8) == "trash-payload")
    #expect(try String(contentsOf: externalSentinel, encoding: .utf8) == "external-must-remain")
    #expect(!reader.fileExists(at: external.appendingPathComponent("reviewed-item").path))
    #expect((try FileManager.default.contentsOfDirectory(atPath: displacedParent.path)).isEmpty)
}

@Test func fdRelativeRenameFailsClosedOnIdentityDriftAndOccupiedDestination() throws {
    let fixture = try FDRelativeFixture()
    defer { try? fixture.remove() }
    let source = fixture.root.appendingPathComponent("source")
    let destination = fixture.root.appendingPathComponent("destination")
    try Data("before-review".utf8).write(to: source)

    let reader = LocalFileSystemReader()
    let reviewed = try reader.identity(at: source.path)
    try FileManager.default.removeItem(at: source)
    try Data("replacement".utf8).write(to: source)
    let filesystem = FDRelativeFileSystem()

    #expect(throws: KeepItCleanError.self) {
        _ = try filesystem.renameExclusively(
            fromAbsolutePath: source.path,
            expectedIdentity: reviewed,
            toAbsolutePath: destination.path
        )
    }
    #expect(try String(contentsOf: source, encoding: .utf8) == "replacement")
    #expect(!reader.fileExists(at: destination.path))

    let replacementIdentity = try reader.identity(at: source.path)
    try Data("occupied".utf8).write(to: destination)
    #expect(throws: KeepItCleanError.self) {
        _ = try filesystem.renameExclusively(
            fromAbsolutePath: source.path,
            expectedIdentity: replacementIdentity,
            toAbsolutePath: destination.path
        )
    }
    #expect(try String(contentsOf: source, encoding: .utf8) == "replacement")
    #expect(try String(contentsOf: destination, encoding: .utf8) == "occupied")
}

@Test func fdRelativeUnlinkHandlesOnlyRegularFilesAndEmptyDirectories() throws {
    let fixture = try FDRelativeFixture()
    defer { try? fixture.remove() }
    let file = fixture.root.appendingPathComponent("finalize-file")
    let emptyDirectory = fixture.root.appendingPathComponent("finalize-empty", isDirectory: true)
    let nonemptyDirectory = fixture.root.appendingPathComponent("finalize-nonempty", isDirectory: true)
    try Data("finalize".utf8).write(to: file)
    try FileManager.default.createDirectory(at: emptyDirectory, withIntermediateDirectories: false)
    try FileManager.default.createDirectory(at: nonemptyDirectory, withIntermediateDirectories: false)
    try Data("preserve".utf8).write(to: nonemptyDirectory.appendingPathComponent("payload"))

    let reader = LocalFileSystemReader()
    let filesystem = FDRelativeFileSystem()
    try filesystem.unlinkFileOrEmptyDirectory(
        atAbsolutePath: file.path,
        expectedIdentity: try reader.identity(at: file.path)
    )
    try filesystem.unlinkFileOrEmptyDirectory(
        atAbsolutePath: emptyDirectory.path,
        expectedIdentity: try reader.identity(at: emptyDirectory.path)
    )

    #expect(!reader.fileExists(at: file.path))
    #expect(!reader.fileExists(at: emptyDirectory.path))
    #expect(throws: KeepItCleanError.self) {
        try filesystem.unlinkFileOrEmptyDirectory(
            atAbsolutePath: nonemptyDirectory.path,
            expectedIdentity: try reader.identity(at: nonemptyDirectory.path)
        )
    }
    #expect(try String(
        contentsOf: nonemptyDirectory.appendingPathComponent("payload"),
        encoding: .utf8
    ) == "preserve")
}

@Test func fdRelativePrivateDirectoryRejectsSymlinkAndWeakPermissions() throws {
    let fixture = try FDRelativeFixture()
    defer { try? fixture.remove() }
    let ownerID = UInt32(getuid())
    let filesystem = FDRelativeFileSystem()
    let realPrivate = fixture.root.appendingPathComponent("real-private", isDirectory: true)
    let linkedPrivate = fixture.root.appendingPathComponent("linked-private", isDirectory: true)
    let weakPrivate = fixture.root.appendingPathComponent("weak-private", isDirectory: true)
    try FileManager.default.createDirectory(at: realPrivate, withIntermediateDirectories: false)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o700],
        ofItemAtPath: realPrivate.path
    )
    try FileManager.default.createSymbolicLink(at: linkedPrivate, withDestinationURL: realPrivate)
    try FileManager.default.createDirectory(at: weakPrivate, withIntermediateDirectories: false)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: weakPrivate.path
    )

    #expect(throws: KeepItCleanError.self) {
        _ = try filesystem.ensurePrivateDirectory(
            atAbsolutePath: linkedPrivate.path,
            ownerID: ownerID
        )
    }
    #expect(throws: KeepItCleanError.self) {
        _ = try filesystem.ensurePrivateDirectory(
            atAbsolutePath: weakPrivate.path,
            ownerID: ownerID
        )
    }

    let realAttributes = try FileManager.default.attributesOfItem(atPath: realPrivate.path)
    let weakAttributes = try FileManager.default.attributesOfItem(atPath: weakPrivate.path)
    let linkDestination = try FileManager.default.destinationOfSymbolicLink(
        atPath: linkedPrivate.path
    )
    #expect(((realAttributes[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o777 == 0o700)
    #expect(((weakAttributes[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o777 == 0o755)
    #expect(linkDestination == realPrivate.path)
}

@Test func fdRelativeRecursiveRemoveUnlinksSymlinkWithoutFollowingExternalTarget() throws {
    let fixture = try FDRelativeFixture()
    defer { try? fixture.remove() }
    let ownerID = UInt32(getuid())
    let filesystem = FDRelativeFileSystem()
    let quarantine = fixture.root.appendingPathComponent("quarantine", isDirectory: true)
    _ = try filesystem.ensurePrivateDirectory(
        atAbsolutePath: quarantine.path,
        ownerID: ownerID
    )

    let captured = quarantine.appendingPathComponent("captured-tree", isDirectory: true)
    let nested = captured.appendingPathComponent("one/two", isDirectory: true)
    let external = fixture.root.appendingPathComponent("external", isDirectory: true)
    let externalTarget = external.appendingPathComponent("must-survive")
    let capturedLink = nested.appendingPathComponent("external-link")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: external, withIntermediateDirectories: false)
    try Data("nested-payload".utf8).write(to: nested.appendingPathComponent("payload"))
    try Data("external-sentinel".utf8).write(to: externalTarget)
    try FileManager.default.createSymbolicLink(at: capturedLink, withDestinationURL: externalTarget)

    let expected = try filesystem.identity(atAbsolutePath: captured.path)
    try filesystem.removeCapturedItemRecursively(
        atAbsolutePath: captured.path,
        expectedIdentity: expected,
        privateParentAbsolutePath: quarantine.path,
        ownerID: ownerID
    )

    #expect(!FileManager.default.fileExists(atPath: captured.path))
    #expect(FileManager.default.fileExists(atPath: quarantine.path))
    #expect(FileManager.default.fileExists(atPath: externalTarget.path))
    #expect(try String(contentsOf: externalTarget, encoding: .utf8) == "external-sentinel")
}

@Test func fdRelativeUnlinkDetectsLeafReplacementAfterUnlinkWithoutFollowingSymlink() throws {
    let fixture = try FDRelativeFixture()
    defer { try? fixture.remove() }
    let source = fixture.root.appendingPathComponent("reviewed-finalize-item")
    let displacedReviewedItem = fixture.root.appendingPathComponent("displaced-reviewed-item")
    let externalTarget = fixture.root.appendingPathComponent("external-target")
    try Data("reviewed-payload".utf8).write(to: source)
    try Data("external-must-survive".utf8).write(to: externalTarget)

    let baseline = FDRelativeFileSystem()
    let reviewed = try baseline.identity(atAbsolutePath: source.path)
    let observer = FDRelativeCheckpointAction(target: .targetVerifiedBeforeUnlink) {
        try FileManager.default.moveItem(at: source, to: displacedReviewedItem)
        try FileManager.default.createSymbolicLink(at: source, withDestinationURL: externalTarget)
    }
    let filesystem = FDRelativeFileSystem(observer: observer)

    #expect(throws: KeepItCleanError.self) {
        try filesystem.unlinkFileOrEmptyDirectory(
            atAbsolutePath: source.path,
            expectedIdentity: reviewed
        )
    }

    // POSIX has no inode-conditional unlinkat: the post-check detects that the
    // reviewed inode did not lose a link. unlinkat removes only the replacement
    // symlink entry and never follows it into the external target.
    #expect(!FileManager.default.fileExists(atPath: source.path))
    #expect(try String(contentsOf: displacedReviewedItem, encoding: .utf8) == "reviewed-payload")
    #expect(try String(contentsOf: externalTarget, encoding: .utf8) == "external-must-survive")
    #expect(reviewed.matchesForMutation(
        try baseline.identity(atAbsolutePath: displacedReviewedItem.path)
    ))
}
