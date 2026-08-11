import Darwin
import Foundation
import KeepItCleanCore
import Testing
@testable import KeepItCleanFS

private struct FDStoreRaceFixture {
    static let markerName = ".keepitclean-fd-store-race-fixture"
    static let markerContents = "KEEPITCLEAN_FD_STORE_RACE_FIXTURE"

    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("keepitclean-fd-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try Data(Self.markerContents.utf8).write(
            to: root.appendingPathComponent(Self.markerName)
        )
    }

    func remove() throws {
        let temporary = FileManager.default.temporaryDirectory.standardizedFileURL.path
        let marker = root.appendingPathComponent(Self.markerName)
        guard root.standardizedFileURL.path.hasPrefix(temporary + "/"),
              root.lastPathComponent.hasPrefix("keepitclean-fd-store-"),
              (try? String(contentsOf: marker, encoding: .utf8)) == Self.markerContents
        else {
            throw KeepItCleanError.protectedPath(root.path)
        }
        try FileManager.default.removeItem(at: root)
    }
}

private final class SecureStateCheckpointAction: SecureStateObserving, @unchecked Sendable {
    private let target: SecureStateCheckpoint
    private let action: @Sendable (SecureStateContext) throws -> Void
    private let lock = NSLock()
    private var fired = false

    init(
        target: SecureStateCheckpoint,
        action: @escaping @Sendable (SecureStateContext) throws -> Void
    ) {
        self.target = target
        self.action = action
    }

    func reached(
        _ checkpoint: SecureStateCheckpoint,
        context: SecureStateContext
    ) throws {
        guard checkpoint == target else { return }
        lock.lock()
        guard !fired else {
            lock.unlock()
            return
        }
        fired = true
        lock.unlock()
        try action(context)
    }
}

@Test func fdRelativeStoreRejectsAncestorSwapBeforeFirstFileOperation() throws {
    let fixture = try FDStoreRaceFixture()
    defer { try? fixture.remove() }
    let state = fixture.root.appendingPathComponent("state", isDirectory: true)
    let displaced = fixture.root.appendingPathComponent("displaced-state", isDirectory: true)
    let external = fixture.root.appendingPathComponent("external", isDirectory: true)
    let externalSentinel = external.appendingPathComponent("must-remain")
    try FileManager.default.createDirectory(at: state, withIntermediateDirectories: false)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: state.path)
    try FileManager.default.createDirectory(at: external, withIntermediateDirectories: false)
    try Data("external".utf8).write(to: externalSentinel)

    let observer = SecureStateCheckpointAction(
        target: .directoryOpenedBeforeBindingVerification
    ) { _ in
        try FileManager.default.moveItem(at: state, to: displaced)
        try FileManager.default.createSymbolicLink(at: state, withDestinationURL: external)
    }

    #expect(throws: KeepItCleanError.self) {
        _ = try SecureStateDirectory.openExisting(state, observer: observer)
    }
    #expect(try String(contentsOf: externalSentinel, encoding: .utf8) == "external")
    #expect((try FileManager.default.contentsOfDirectory(atPath: external.path)) == ["must-remain"])
    #expect((try FileManager.default.contentsOfDirectory(atPath: displaced.path)).isEmpty)
}

@Test func fdRelativeStorePublishRejectsParentSwapAndLeavesExternalUntouched() throws {
    let fixture = try FDStoreRaceFixture()
    defer { try? fixture.remove() }
    let state = fixture.root.appendingPathComponent("state", isDirectory: true)
    let displaced = fixture.root.appendingPathComponent("displaced-state", isDirectory: true)
    let external = fixture.root.appendingPathComponent("external", isDirectory: true)
    let externalSentinel = external.appendingPathComponent("operations.jsonl")
    try FileManager.default.createDirectory(at: state, withIntermediateDirectories: false)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: state.path)
    try FileManager.default.createDirectory(at: external, withIntermediateDirectories: false)
    try Data("external-must-survive".utf8).write(to: externalSentinel)

    let observer = SecureStateCheckpointAction(
        target: .destinationInspectedBeforePublish
    ) { _ in
        try FileManager.default.moveItem(at: state, to: displaced)
        try FileManager.default.createSymbolicLink(at: state, withDestinationURL: external)
    }
    let directory = try SecureStateDirectory.openExisting(state, observer: observer)
    let operationLock = try directory.acquireExclusiveLock()
    defer { withExtendedLifetime(operationLock) {} }

    #expect(throws: KeepItCleanError.self) {
        try directory.replaceAtomically(
            Data("new-operation-log".utf8),
            named: "operations.jsonl"
        )
    }
    #expect(try String(contentsOf: externalSentinel, encoding: .utf8) == "external-must-survive")
    #expect((try FileManager.default.contentsOfDirectory(atPath: external.path)) == ["operations.jsonl"])
    #expect((try FileManager.default.contentsOfDirectory(atPath: displaced.path)).isEmpty)
}

@Test func fdRelativeStorePublishRejectsDestinationSymlinkSwap() throws {
    let fixture = try FDStoreRaceFixture()
    defer { try? fixture.remove() }
    let state = fixture.root.appendingPathComponent("state", isDirectory: true)
    let log = state.appendingPathComponent("operations.jsonl")
    let external = fixture.root.appendingPathComponent("external-log")
    try FileManager.default.createDirectory(at: state, withIntermediateDirectories: false)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: state.path)
    try Data("old-log".utf8).write(to: log)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: log.path)
    try Data("external-must-survive".utf8).write(to: external)

    let observer = SecureStateCheckpointAction(
        target: .destinationInspectedBeforePublish
    ) { _ in
        try FileManager.default.removeItem(at: log)
        try FileManager.default.createSymbolicLink(at: log, withDestinationURL: external)
    }
    let directory = try SecureStateDirectory.openExisting(state, observer: observer)
    let operationLock = try directory.acquireExclusiveLock()
    defer { withExtendedLifetime(operationLock) {} }

    #expect(throws: KeepItCleanError.self) {
        try directory.replaceAtomically(Data("new-log".utf8), named: log.lastPathComponent)
    }
    #expect(try String(contentsOf: external, encoding: .utf8) == "external-must-survive")
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: log.path) == external.path)
}

@Test func fdRelativeStoreReadRejectsLeafSwapAfterOpen() throws {
    let fixture = try FDStoreRaceFixture()
    defer { try? fixture.remove() }
    let state = fixture.root.appendingPathComponent("state", isDirectory: true)
    let log = state.appendingPathComponent("operations.jsonl")
    let displaced = state.appendingPathComponent("reviewed-log")
    try FileManager.default.createDirectory(at: state, withIntermediateDirectories: false)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: state.path)
    try Data("reviewed-log".utf8).write(to: log)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: log.path)

    let observer = SecureStateCheckpointAction(
        target: .fileOpenedBeforeRead
    ) { _ in
        try FileManager.default.moveItem(at: log, to: displaced)
        try Data("replacement-must-survive".utf8).write(to: log)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: log.path)
    }
    let directory = try SecureStateDirectory.openExisting(state, observer: observer)

    #expect(throws: KeepItCleanError.self) {
        _ = try directory.read(named: log.lastPathComponent, maximumBytes: 1_024)
    }
    let survivingLog = try String(contentsOf: log, encoding: .utf8)
    #expect(survivingLog == "replacement-must-survive")
    #expect(try String(contentsOf: displaced, encoding: .utf8) == "reviewed-log")
}

@Test func fdRelativeStoreReadDoesNotBlockWhenLeafBecomesFIFO() throws {
    let fixture = try FDStoreRaceFixture()
    defer { try? fixture.remove() }
    let state = fixture.root.appendingPathComponent("state", isDirectory: true)
    let log = state.appendingPathComponent("operations.jsonl")
    let displaced = state.appendingPathComponent("reviewed-log")
    try FileManager.default.createDirectory(at: state, withIntermediateDirectories: false)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: state.path)
    try Data("reviewed-log".utf8).write(to: log)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: log.path)

    let observer = SecureStateCheckpointAction(
        target: .fileAboutToOpenForRead
    ) { _ in
        try FileManager.default.moveItem(at: log, to: displaced)
        guard log.path.withCString({ Darwin.mkfifo($0, mode_t(0o600)) }) == 0 else {
            throw KeepItCleanError.io("Unable to create FIFO race fixture")
        }
    }
    let directory = try SecureStateDirectory.openExisting(state, observer: observer)

    #expect(throws: KeepItCleanError.self) {
        _ = try directory.read(named: log.lastPathComponent, maximumBytes: 1_024)
    }
    var metadata = stat()
    #expect(log.path.withCString { Darwin.lstat($0, &metadata) } == 0)
    #expect(metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFIFO))
    #expect(try String(contentsOf: displaced, encoding: .utf8) == "reviewed-log")
}

@Test func fdRelativeStorePublishDetectsRegularLeafSwapAfterInspection() throws {
    let fixture = try FDStoreRaceFixture()
    defer { try? fixture.remove() }
    let state = fixture.root.appendingPathComponent("state", isDirectory: true)
    let log = state.appendingPathComponent("operations.jsonl")
    let displaced = state.appendingPathComponent("reviewed-log")
    try FileManager.default.createDirectory(at: state, withIntermediateDirectories: false)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: state.path)
    try Data("reviewed-log".utf8).write(to: log)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: log.path)

    let observer = SecureStateCheckpointAction(
        target: .destinationInspectedBeforePublish
    ) { _ in
        try FileManager.default.moveItem(at: log, to: displaced)
        try Data("replacement-must-survive".utf8).write(to: log)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: log.path)
    }
    let directory = try SecureStateDirectory.openExisting(state, observer: observer)
    let operationLock = try directory.acquireExclusiveLock()
    defer { withExtendedLifetime(operationLock) {} }

    #expect(throws: KeepItCleanError.self) {
        try directory.replaceAtomically(Data("new-log".utf8), named: log.lastPathComponent)
    }
    let survivingPublishedLog = try String(contentsOf: log, encoding: .utf8)
    #expect(survivingPublishedLog == "replacement-must-survive")
    #expect(try String(contentsOf: displaced, encoding: .utf8) == "reviewed-log")
}

@Test func fdRelativeStorePublishRollsBackDirectoryLeafSwapAfterInspection() throws {
    let fixture = try FDStoreRaceFixture()
    defer { try? fixture.remove() }
    let state = fixture.root.appendingPathComponent("state", isDirectory: true)
    let log = state.appendingPathComponent("operations.jsonl")
    let displaced = state.appendingPathComponent("reviewed-log")
    try FileManager.default.createDirectory(at: state, withIntermediateDirectories: false)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: state.path)
    try Data("reviewed-log".utf8).write(to: log)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: log.path)

    let observer = SecureStateCheckpointAction(
        target: .destinationInspectedBeforePublish
    ) { _ in
        try FileManager.default.moveItem(at: log, to: displaced)
        try FileManager.default.createDirectory(at: log, withIntermediateDirectories: false)
    }
    let directory = try SecureStateDirectory.openExisting(state, observer: observer)
    let operationLock = try directory.acquireExclusiveLock()
    defer { withExtendedLifetime(operationLock) {} }

    #expect(throws: KeepItCleanError.self) {
        try directory.replaceAtomically(Data("new-log".utf8), named: log.lastPathComponent)
    }
    var isDirectory: ObjCBool = false
    #expect(FileManager.default.fileExists(atPath: log.path, isDirectory: &isDirectory))
    #expect(isDirectory.boolValue)
    #expect(try String(contentsOf: displaced, encoding: .utf8) == "reviewed-log")
}

@Test func fdRelativeStorePublishRollsBackFIFOLeafSwapAfterInspection() throws {
    let fixture = try FDStoreRaceFixture()
    defer { try? fixture.remove() }
    let state = fixture.root.appendingPathComponent("state", isDirectory: true)
    let log = state.appendingPathComponent("operations.jsonl")
    let displaced = state.appendingPathComponent("reviewed-log")
    try FileManager.default.createDirectory(at: state, withIntermediateDirectories: false)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: state.path)
    try Data("reviewed-log".utf8).write(to: log)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: log.path)

    let observer = SecureStateCheckpointAction(
        target: .destinationInspectedBeforePublish
    ) { _ in
        try FileManager.default.moveItem(at: log, to: displaced)
        guard log.path.withCString({ Darwin.mkfifo($0, mode_t(0o600)) }) == 0 else {
            throw KeepItCleanError.io("Unable to create FIFO race fixture")
        }
    }
    let directory = try SecureStateDirectory.openExisting(state, observer: observer)
    let operationLock = try directory.acquireExclusiveLock()
    defer { withExtendedLifetime(operationLock) {} }

    #expect(throws: KeepItCleanError.self) {
        try directory.replaceAtomically(Data("new-log".utf8), named: log.lastPathComponent)
    }
    var metadata = stat()
    #expect(log.path.withCString { Darwin.lstat($0, &metadata) } == 0)
    #expect(metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFIFO))
    #expect(try String(contentsOf: displaced, encoding: .utf8) == "reviewed-log")
}

@Test func fdRelativeStoreCreateOnlyPublishRejectsLeafSwapAfterRename() throws {
    let fixture = try FDStoreRaceFixture()
    defer { try? fixture.remove() }
    let state = fixture.root.appendingPathComponent("state", isDirectory: true)
    let plan = state.appendingPathComponent("plan.cleanup.json")
    let displaced = state.appendingPathComponent("reviewed-plan")
    try FileManager.default.createDirectory(at: state, withIntermediateDirectories: false)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: state.path)

    let observer = SecureStateCheckpointAction(
        target: .newFilePublishedBeforeVerification
    ) { _ in
        try FileManager.default.moveItem(at: plan, to: displaced)
        try Data("replacement-must-survive".utf8).write(to: plan)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: plan.path)
    }
    let directory = try SecureStateDirectory.openExisting(state, observer: observer)
    let operationLock = try directory.acquireExclusiveLock()
    defer { withExtendedLifetime(operationLock) {} }

    #expect(throws: KeepItCleanError.self) {
        try directory.writeNew(Data("reviewed-plan".utf8), named: plan.lastPathComponent)
    }
    #expect(try String(contentsOf: plan, encoding: .utf8) == "replacement-must-survive")
    #expect(try String(contentsOf: displaced, encoding: .utf8) == "reviewed-plan")
}

@Test func fdRelativeStoreMissingReadRechecksParentBinding() throws {
    let fixture = try FDStoreRaceFixture()
    defer { try? fixture.remove() }
    let state = fixture.root.appendingPathComponent("state", isDirectory: true)
    let displaced = fixture.root.appendingPathComponent("displaced-state", isDirectory: true)
    let external = fixture.root.appendingPathComponent("external", isDirectory: true)
    let sentinel = external.appendingPathComponent("must-remain")
    try FileManager.default.createDirectory(at: state, withIntermediateDirectories: false)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: state.path)
    try FileManager.default.createDirectory(at: external, withIntermediateDirectories: false)
    try Data("external".utf8).write(to: sentinel)

    let observer = SecureStateCheckpointAction(
        target: .fileAboutToOpenForRead
    ) { _ in
        try FileManager.default.moveItem(at: state, to: displaced)
        try FileManager.default.createSymbolicLink(at: state, withDestinationURL: external)
    }
    let directory = try SecureStateDirectory.openExisting(state, observer: observer)

    #expect(throws: KeepItCleanError.self) {
        _ = try directory.readIfPresent(named: "missing.jsonl", maximumBytes: 1_024)
    }
    #expect((try FileManager.default.contentsOfDirectory(atPath: displaced.path)).isEmpty)
    #expect(try String(contentsOf: sentinel, encoding: .utf8) == "external")
}
