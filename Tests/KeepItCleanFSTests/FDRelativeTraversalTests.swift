import Foundation
import KeepItCleanCore
import Testing
@testable import KeepItCleanFS

private struct FDTraversalFixture {
    static let markerName = ".keepitclean-fd-traversal-test-fixture"
    static let markerContents = "KEEPITCLEAN_FD_TRAVERSAL_TEST_FIXTURE"

    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("keepitclean-fd-traversal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try Data(Self.markerContents.utf8).write(
            to: root.appendingPathComponent(Self.markerName)
        )
    }

    func remove() throws {
        let temporary = FileManager.default.temporaryDirectory.standardizedFileURL.path
        let marker = root.appendingPathComponent(Self.markerName)
        guard root.standardizedFileURL.path.hasPrefix(temporary + "/"),
              root.lastPathComponent.hasPrefix("keepitclean-fd-traversal-"),
              (try? String(contentsOf: marker, encoding: .utf8)) == Self.markerContents
        else {
            throw KeepItCleanError.protectedPath(root.path)
        }
        try FileManager.default.removeItem(at: root)
    }
}

private final class TraversalSwapObserver: FDRelativeTraversalObserving, @unchecked Sendable {
    private let targetPath: String
    private let action: @Sendable () throws -> Void
    private let lock = NSLock()
    private var fired = false
    private var observedNames: Set<String> = []

    init(targetPath: String, action: @escaping @Sendable () throws -> Void) {
        self.targetPath = targetPath
        self.action = action
    }

    func reached(
        _ checkpoint: FDRelativeTraversalCheckpoint,
        context: FDRelativeTraversalContext
    ) throws {
        guard checkpoint == .entryInspectedBeforeOpen else { return }
        lock.lock()
        observedNames.insert(context.entryName)
        let shouldFire = !fired && context.entryPath == targetPath
        if shouldFire { fired = true }
        lock.unlock()
        if shouldFire { try action() }
    }

    func didObserve(name: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return observedNames.contains(name)
    }
}

@Test func fdRelativeImmediateChildrenRejectsSymlinkRoot() throws {
    let fixture = try FDTraversalFixture()
    defer { try? fixture.remove() }
    let real = fixture.root.appendingPathComponent("real", isDirectory: true)
    let alias = fixture.root.appendingPathComponent("alias", isDirectory: true)
    try FileManager.default.createDirectory(at: real, withIntermediateDirectories: false)
    try Data("inside".utf8).write(to: real.appendingPathComponent("payload"))
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)

    let reader = LocalFileSystemReader()
    #expect(throws: KeepItCleanError.self) {
        _ = try reader.immediateChildren(at: alias.path)
    }
    #expect(try reader.immediateChildren(at: real.path) == [
        PathValidationPolicy.canonicalSystemAlias(real.appendingPathComponent("payload").path),
    ])
}

@Test func fdRelativeTraversalRejectsDirectoryToSymlinkSwapWithoutEnteringExternalTree() throws {
    let fixture = try FDTraversalFixture()
    defer { try? fixture.remove() }
    let scanRoot = fixture.root.appendingPathComponent("scan", isDirectory: true)
    let target = scanRoot.appendingPathComponent("target", isDirectory: true)
    let displacedTarget = fixture.root.appendingPathComponent("displaced-target", isDirectory: true)
    let external = fixture.root.appendingPathComponent("external", isDirectory: true)
    let externalSentinelName = "external-sentinel-\(UUID().uuidString)"
    let externalSentinel = external.appendingPathComponent(externalSentinelName)
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: external, withIntermediateDirectories: false)
    try Data("reviewed".utf8).write(to: target.appendingPathComponent("reviewed-payload"))
    try Data("must-not-be-traversed".utf8).write(to: externalSentinel)

    let observer = TraversalSwapObserver(
        targetPath: PathValidationPolicy.canonicalSystemAlias(target.path)
    ) {
        try FileManager.default.moveItem(at: target, to: displacedTarget)
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: external)
    }
    let reader = LocalFileSystemReader(measurer: DiskUsageMeasurer(observer: observer))

    #expect(throws: KeepItCleanError.self) {
        _ = try reader.usage(at: scanRoot.path)
    }
    #expect(!observer.didObserve(name: externalSentinelName))
    #expect(try String(contentsOf: externalSentinel, encoding: .utf8) == "must-not-be-traversed")
    #expect(try String(
        contentsOf: displacedTarget.appendingPathComponent("reviewed-payload"),
        encoding: .utf8
    ) == "reviewed")
}

@Test func fdRelativeTraversalDetectsSameDeviceDirectoryReplacementBeforeRecursing() throws {
    let fixture = try FDTraversalFixture()
    defer { try? fixture.remove() }
    let scanRoot = fixture.root.appendingPathComponent("scan", isDirectory: true)
    let target = scanRoot.appendingPathComponent("target", isDirectory: true)
    let displacedTarget = fixture.root.appendingPathComponent("displaced-target", isDirectory: true)
    let replacement = fixture.root.appendingPathComponent("replacement", isDirectory: true)
    let replacementSentinelName = "replacement-sentinel-\(UUID().uuidString)"
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: false)
    try Data("replacement-must-not-be-scanned".utf8).write(
        to: replacement.appendingPathComponent(replacementSentinelName)
    )

    let canonicalTarget = PathValidationPolicy.canonicalSystemAlias(target.path)
    let observer = TraversalSwapObserver(targetPath: canonicalTarget) {
        try FileManager.default.moveItem(at: target, to: displacedTarget)
        try FileManager.default.moveItem(at: replacement, to: target)
    }
    let reader = LocalFileSystemReader(measurer: DiskUsageMeasurer(observer: observer))

    #expect(throws: KeepItCleanError.identityChanged(canonicalTarget)) {
        _ = try reader.usage(at: scanRoot.path)
    }
    #expect(!observer.didObserve(name: replacementSentinelName))
    #expect(try String(
        contentsOf: target.appendingPathComponent(replacementSentinelName),
        encoding: .utf8
    ) == "replacement-must-not-be-scanned")
}
