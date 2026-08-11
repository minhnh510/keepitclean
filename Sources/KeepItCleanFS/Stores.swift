import Darwin
import Foundation
import KeepItCleanCore

public struct DefaultHostIdentifier: HostIdentifying, Sendable {
    public init() {}

    public func currentHostID() -> String {
        ProcessInfo.processInfo.hostName
    }
}

public final class JSONPlanStore: PlanStoring, @unchecked Sendable {
    public let baseDirectory: URL
    private let lock = NSLock()

    public init(baseDirectory: URL) {
        self.baseDirectory = baseDirectory
    }

    public convenience init() {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        self.init(baseDirectory: applicationSupport.appendingPathComponent("KeepItClean/Plans", isDirectory: true))
    }

    public func save(plan: CleanupPlan) throws -> URL {
        try withLock {
            let url = baseDirectory.appendingPathComponent("\(plan.id.uuidString).cleanup.json")
            try write(plan, to: url)
            return url
        }
    }

    public func loadPlan(id: UUID) throws -> CleanupPlan {
        try loadPlan(at: baseDirectory.appendingPathComponent("\(id.uuidString).cleanup.json"))
    }

    public func loadPlan(at url: URL) throws -> CleanupPlan {
        try withLock {
            let checked = try validatedStoredURL(url)
            let plan = try read(CleanupPlan.self, from: checked)
            guard checked.lastPathComponent == "\(plan.id.uuidString).cleanup.json" else {
                throw KeepItCleanError.io("Cleanup plan ID does not match its store key.")
            }
            return plan
        }
    }

    public func save(nativePlan: NativeActionPlan) throws -> URL {
        try withLock {
            let url = baseDirectory.appendingPathComponent("\(nativePlan.id.uuidString).native.json")
            try write(nativePlan, to: url)
            return url
        }
    }

    public func loadNativePlan(id: UUID) throws -> NativeActionPlan {
        try loadNativePlan(at: baseDirectory.appendingPathComponent("\(id.uuidString).native.json"))
    }

    public func loadNativePlan(at url: URL) throws -> NativeActionPlan {
        try withLock {
            let checked = try validatedStoredURL(url)
            let plan = try read(NativeActionPlan.self, from: checked)
            guard checked.lastPathComponent == "\(plan.id.uuidString).native.json" else {
                throw KeepItCleanError.io("Native-action plan ID does not match its store key.")
            }
            return plan
        }
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        do {
            let directory = try SecureStateDirectory.openOrCreate(baseDirectory)
            let operationLock = try directory.acquireExclusiveLock()
            defer { withExtendedLifetime(operationLock) {} }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(value)
            guard data.count <= 64 * 1_024 * 1_024 else {
                throw KeepItCleanError.io("Plan exceeds the 64 MiB store limit.")
            }
            try directory.writeNew(
                data,
                named: url.lastPathComponent
            )
        } catch {
            throw KeepItCleanError.io("Unable to save plan: \(error.localizedDescription)")
        }
    }

    private func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        do {
            let directory = try SecureStateDirectory.openExisting(baseDirectory)
            let operationLock = try directory.acquireExclusiveLock()
            defer { withExtendedLifetime(operationLock) {} }
            let decoder = JSONDecoder()
            return try decoder.decode(
                type,
                from: directory.read(named: url.lastPathComponent, maximumBytes: 64 * 1_024 * 1_024)
            )
        } catch {
            throw KeepItCleanError.io("Unable to load plan \(url.path): \(error.localizedDescription)")
        }
    }

    private func validatedStoredURL(_ url: URL) throws -> URL {
        let base = PathValidationPolicy.canonicalSystemAlias(
            baseDirectory.standardizedFileURL.path
        )
        let checkedPath = PathValidationPolicy.canonicalSystemAlias(
            url.standardizedFileURL.path
        )
        let checked = URL(fileURLWithPath: checkedPath)
        guard checked.deletingLastPathComponent().path == base,
              checked.path != base
        else {
            throw KeepItCleanError.protectedPath(checkedPath)
        }
        return checked
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

public final class JSONLOperationStore: OperationStoring, @unchecked Sendable {
    public let logURL: URL
    public let maximumRecords: Int
    public let maximumBytes: Int
    private let lock = NSLock()

    public init(logURL: URL, maximumRecords: Int = 100, maximumBytes: Int = 10 * 1_024 * 1_024) {
        self.logURL = logURL
        self.maximumRecords = max(1, maximumRecords)
        self.maximumBytes = max(1_024, maximumBytes)
    }

    public convenience init() {
        let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Logs/KeepItClean", isDirectory: true)
        self.init(logURL: logs.appendingPathComponent("operations.jsonl"))
    }

    public func append(operation: OperationRecord) throws {
        try withLock {
            let directory = try SecureStateDirectory.openOrCreate(
                logURL.deletingLastPathComponent()
            )
            let operationLock = try directory.acquireExclusiveLock()
            defer { withExtendedLifetime(operationLock) {} }
            var records = try readAllUnlocked(directory: directory)
            records.removeAll { $0.id == operation.id }
            records.append(operation)
            if records.count > maximumRecords {
                records = Array(records.suffix(maximumRecords))
            }

            let encoder = Self.encoder()
            var data = Data()
            for record in records.reversed() {
                let line = try encoder.encode(record) + Data([0x0A])
                guard line.count <= maximumBytes else {
                    throw KeepItCleanError.io("One operation record exceeds the history size limit.")
                }
                if data.count + line.count > maximumBytes { break }
                data.insert(contentsOf: line, at: 0)
            }

            do {
                try directory.replaceAtomically(
                    data,
                    named: logURL.lastPathComponent
                )
            } catch {
                throw KeepItCleanError.io("Unable to write operation history: \(error.localizedDescription)")
            }
        }
    }

    public func operation(id: UUID) throws -> OperationRecord {
        try withLock {
            guard let operation = try readAllUnlocked().last(where: { $0.id == id }) else {
                throw KeepItCleanError.operationNotFound(id.uuidString)
            }
            return operation
        }
    }

    public func operations(limit: Int = 100) throws -> [OperationRecord] {
        try withLock { Array(try readAllUnlocked().suffix(max(0, limit)).reversed()) }
    }

    private func readAllUnlocked() throws -> [OperationRecord] {
        guard let directory = try SecureStateDirectory.openExistingIfPresent(
            logURL.deletingLastPathComponent()
        ) else { return [] }
        let operationLock = try directory.acquireExclusiveLock()
        defer { withExtendedLifetime(operationLock) {} }
        return try readAllUnlocked(directory: directory)
    }

    private func readAllUnlocked(directory: SecureStateDirectory) throws -> [OperationRecord] {
        do {
            guard let data = try directory.readIfPresent(
                named: logURL.lastPathComponent,
                maximumBytes: maximumBytes
            ) else { return [] }
            let decoder = Self.decoder()
            return try data.split(separator: 0x0A).map {
                try decoder.decode(OperationRecord.self, from: Data($0))
            }
        } catch {
            throw KeepItCleanError.io("Unable to read operation history: \(error.localizedDescription)")
        }
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        JSONDecoder()
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

@_silgen_name("flock")
private func keepItCleanStoreFlock(_ descriptor: Int32, _ operation: Int32) -> Int32

final class SecureStateDirectoryLock {
    private let descriptor: Int32

    init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        _ = keepItCleanStoreFlock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
    }
}

private final class SecureStateDescriptor {
    let rawValue: Int32

    init(_ rawValue: Int32) {
        self.rawValue = rawValue
    }

    deinit {
        Darwin.close(rawValue)
    }
}

enum SecureStateCheckpoint: Sendable {
    case directoryOpenedBeforeBindingVerification
    case fileAboutToOpenForRead
    case fileOpenedBeforeRead
    case temporaryWrittenBeforePublish
    case destinationInspectedBeforePublish
    case newFilePublishedBeforeVerification
}

struct SecureStateContext: Sendable {
    let directoryPath: String
    let fileName: String?
}

protocol SecureStateObserving: Sendable {
    func reached(
        _ checkpoint: SecureStateCheckpoint,
        context: SecureStateContext
    ) throws
}

struct NoopSecureStateObserver: SecureStateObserving {
    func reached(
        _: SecureStateCheckpoint,
        context _: SecureStateContext
    ) throws {}
}

/// A private state directory whose pathname is used only to acquire an initial
/// descriptor. Every file read/write/rename is relative to that held fd.
final class SecureStateDirectory {
    let canonicalPath: String
    private let descriptor: SecureStateDescriptor
    private let components: [String]
    private let observer: any SecureStateObserving

    private init(
        canonicalPath: String,
        components: [String],
        descriptor: SecureStateDescriptor,
        observer: any SecureStateObserving
    ) {
        self.canonicalPath = canonicalPath
        self.components = components
        self.descriptor = descriptor
        self.observer = observer
    }

    static func openOrCreate(
        _ url: URL,
        observer: any SecureStateObserving = NoopSecureStateObserver()
    ) throws -> SecureStateDirectory {
        guard let directory = try open(
            url,
            createMissing: true,
            observer: observer
        ) else {
            throw KeepItCleanError.io("Unable to create local state directory: \(url.path)")
        }
        return directory
    }

    static func openExisting(
        _ url: URL,
        observer: any SecureStateObserving = NoopSecureStateObserver()
    ) throws -> SecureStateDirectory {
        guard let directory = try open(
            url,
            createMissing: false,
            observer: observer
        ) else {
            throw KeepItCleanError.io("Local state directory does not exist: \(url.path)")
        }
        return directory
    }

    static func openExistingIfPresent(_ url: URL) throws -> SecureStateDirectory? {
        try open(
            url,
            createMissing: false,
            observer: NoopSecureStateObserver()
        )
    }

    func acquireExclusiveLock() throws -> SecureStateDirectoryLock {
        try verifyPathBinding()
        let retained = Darwin.dup(descriptor.rawValue)
        guard retained >= 0 else {
            throw posixError("Unable to retain local-state lock for \(canonicalPath)")
        }
        guard keepItCleanStoreFlock(retained, LOCK_EX) == 0 else {
            let savedError = errno
            Darwin.close(retained)
            throw posixError(
                "Unable to lock local state directory \(canonicalPath)",
                code: savedError
            )
        }
        do {
            try verifyPathBinding()
        } catch {
            _ = keepItCleanStoreFlock(retained, LOCK_UN)
            Darwin.close(retained)
            throw error
        }
        return SecureStateDirectoryLock(descriptor: retained)
    }

    func read(named rawName: String, maximumBytes: Int) throws -> Data {
        guard let data = try readIfPresent(named: rawName, maximumBytes: maximumBytes) else {
            throw KeepItCleanError.io("Local state file does not exist: \(rawName)")
        }
        return data
    }

    func readIfPresent(named rawName: String, maximumBytes: Int) throws -> Data? {
        let name = try validateBasename(rawName)
        try verifyPathBinding()
        try observer.reached(
            .fileAboutToOpenForRead,
            context: SecureStateContext(
                directoryPath: canonicalPath,
                fileName: name
            )
        )
        let file = name.withCString {
            Darwin.openat(
                descriptor.rawValue,
                $0,
                O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW
            )
        }
        if file < 0, errno == ENOENT {
            try verifyPathBinding()
            return nil
        }
        guard file >= 0 else {
            throw posixError("Unable to open local state file \(canonicalPath)/\(name)")
        }
        let opened = SecureStateDescriptor(file)
        try requirePrivateRegularFile(opened.rawValue, displayName: name)
        try observer.reached(
            .fileOpenedBeforeRead,
            context: SecureStateContext(
                directoryPath: canonicalPath,
                fileName: name
            )
        )
        let data = try readAll(
            descriptor: opened.rawValue,
            maximumBytes: max(1, maximumBytes),
            displayName: name
        )
        let openedIdentity = try entryIdentity(
            descriptor: opened.rawValue,
            displayName: name
        )
        guard let currentIdentity = try entryIdentityIfPresent(named: name),
              currentIdentity == openedIdentity
        else {
            throw KeepItCleanError.identityChanged("\(canonicalPath)/\(name)")
        }
        try verifyPathBinding()
        return data
    }

    func writeNew(_ data: Data, named rawName: String) throws {
        let name = try validateBasename(rawName)
        let temporary = try validateBasename(".\(name).\(UUID().uuidString).new")
        let temporaryIdentity = try writeDirectNew(data, named: temporary)
        defer { removeEntryIfMatches(named: temporary, identity: temporaryIdentity) }
        try observer.reached(
            .temporaryWrittenBeforePublish,
            context: SecureStateContext(
                directoryPath: canonicalPath,
                fileName: name
            )
        )
        try verifyPathBinding()
        let renamed = temporary.withCString { temporaryPointer in
            name.withCString { namePointer in
                Darwin.renameatx_np(
                    descriptor.rawValue,
                    temporaryPointer,
                    descriptor.rawValue,
                    namePointer,
                    UInt32(RENAME_EXCL | RENAME_NOFOLLOW_ANY | RENAME_RESOLVE_BENEATH)
                )
            }
        }
        guard renamed == 0 else {
            throw posixError("Refusing to replace local state file \(canonicalPath)/\(name)")
        }
        try observer.reached(
            .newFilePublishedBeforeVerification,
            context: SecureStateContext(
                directoryPath: canonicalPath,
                fileName: name
            )
        )
        guard try rawEntryIdentityIfPresent(named: name) == temporaryIdentity else {
            throw KeepItCleanError.identityChanged("\(canonicalPath)/\(name)")
        }
        guard Darwin.fsync(descriptor.rawValue) == 0 else {
            throw posixError("Unable to persist local state directory \(canonicalPath)")
        }
        try verifyPathBinding()
    }

    func replaceAtomically(_ data: Data, named rawName: String) throws {
        let name = try validateBasename(rawName)
        let temporary = try validateBasename(".\(name).\(UUID().uuidString).tmp")
        let temporaryIdentity = try writeDirectNew(data, named: temporary)
        defer { removeEntryIfMatches(named: temporary, identity: temporaryIdentity) }
        try observer.reached(
            .temporaryWrittenBeforePublish,
            context: SecureStateContext(
                directoryPath: canonicalPath,
                fileName: name
            )
        )

        let existingIdentity = try entryIdentityIfPresent(named: name)
        try observer.reached(
            .destinationInspectedBeforePublish,
            context: SecureStateContext(
                directoryPath: canonicalPath,
                fileName: name
            )
        )

        try verifyPathBinding()
        let renameFlags = UInt32(
            (existingIdentity == nil ? RENAME_EXCL : RENAME_SWAP)
                | RENAME_NOFOLLOW_ANY
                | RENAME_RESOLVE_BENEATH
        )
        let renamed = temporary.withCString { temporaryPointer in
            name.withCString { namePointer in
                Darwin.renameatx_np(
                    descriptor.rawValue,
                    temporaryPointer,
                    descriptor.rawValue,
                    namePointer,
                    renameFlags
                )
            }
        }
        guard renamed == 0 else {
            throw posixError("Unable to publish local state file \(canonicalPath)/\(name)")
        }

        let publishedIdentity = try rawEntryIdentityIfPresent(named: name)
        let displacedIdentity = try rawEntryIdentityIfPresent(named: temporary)
        let publicationMatches = publishedIdentity == temporaryIdentity
            && (existingIdentity == nil || displacedIdentity == existingIdentity)
        guard publicationMatches else {
            guard let displacedIdentity else {
                throw KeepItCleanError.io(
                    "Local state publication changed concurrently; recovery entry is missing in \(canonicalPath)."
                )
            }
            try rollbackStoreSwapIfPossible(
                temporary: temporary,
                destination: name,
                publishedIdentity: temporaryIdentity,
                displacedIdentity: displacedIdentity
            )
            throw KeepItCleanError.identityChanged("\(canonicalPath)/\(name)")
        }

        if existingIdentity != nil {
            guard temporary.withCString({
                Darwin.unlinkat(descriptor.rawValue, $0, 0)
            }) == 0 else {
                throw posixError("Unable to retire prior local state file \(canonicalPath)/\(temporary)")
            }
        }
        guard Darwin.fsync(descriptor.rawValue) == 0 else {
            throw posixError("Unable to persist local state directory \(canonicalPath)")
        }
        try verifyPathBinding()
    }

    private func verifyPathBinding() throws {
        guard let reopened = try Self.openComponents(components) else {
            throw KeepItCleanError.io("Local state path disappeared: \(canonicalPath)")
        }
        var held = stat()
        var current = stat()
        guard Darwin.fstat(descriptor.rawValue, &held) == 0,
              Darwin.fstat(reopened.rawValue, &current) == 0
        else {
            throw posixError("Unable to verify local state directory \(canonicalPath)")
        }
        guard held.st_dev == current.st_dev, held.st_ino == current.st_ino else {
            throw KeepItCleanError.identityChanged(canonicalPath)
        }
    }

    private func writeDirectNew(
        _ data: Data,
        named name: String
    ) throws -> SecureStateEntryIdentity {
        try verifyPathBinding()
        let file = name.withCString {
            Darwin.openat(
                descriptor.rawValue,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                mode_t(0o600)
            )
        }
        guard file >= 0 else {
            throw posixError("Refusing to replace local state file \(canonicalPath)/\(name)")
        }
        let opened = SecureStateDescriptor(file)
        do {
            try requirePrivateRegularFile(opened.rawValue, displayName: name)
            try writeAll(data, descriptor: opened.rawValue, displayName: name)
            guard Darwin.fsync(opened.rawValue) == 0 else {
                throw posixError("Unable to persist local state file \(canonicalPath)/\(name)")
            }
            let identity = try entryIdentity(
                descriptor: opened.rawValue,
                displayName: name
            )
            guard try rawEntryIdentityIfPresent(named: name) == identity else {
                throw KeepItCleanError.identityChanged("\(canonicalPath)/\(name)")
            }
            return identity
        } catch {
            if let identity = try? entryIdentity(
                descriptor: opened.rawValue,
                displayName: name
            ) {
                removeEntryIfMatches(named: name, identity: identity)
            }
            throw error
        }
    }

    private func removeEntryIfMatches(
        named name: String,
        identity: SecureStateEntryIdentity
    ) {
        guard (try? rawEntryIdentityIfPresent(named: name)) == identity else { return }
        _ = name.withCString { Darwin.unlinkat(descriptor.rawValue, $0, 0) }
    }

    private static func open(
        _ url: URL,
        createMissing: Bool,
        observer: any SecureStateObserving
    ) throws -> SecureStateDirectory? {
        let rawPath = url.path
        guard rawPath.hasPrefix("/"),
              !rawPath.unicodeScalars.contains(where: {
                  $0.value == 0 || $0.value < 0x20 || $0.value == 0x7F
              })
        else {
            throw KeepItCleanError.invalidPath(rawPath)
        }
        let rawComponents = rawPath.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard !rawComponents.contains("."), !rawComponents.contains("..") else {
            throw KeepItCleanError.invalidPath(rawPath)
        }

        let canonicalPath = PathValidationPolicy.canonicalSystemAlias(
            url.standardizedFileURL.path
        )
        let components = canonicalPath.split(
            separator: "/",
            omittingEmptySubsequences: true
        ).map(String.init)
        guard !components.isEmpty else {
            throw KeepItCleanError.protectedPath(canonicalPath)
        }

        let root = Darwin.open("/", O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_DIRECTORY)
        guard root >= 0 else {
            throw posixError("Unable to open filesystem root")
        }
        var current = SecureStateDescriptor(root)
        var walked = ""

        for component in components {
            walked += "/\(component)"
            var metadata = stat()
            var lookup = component.withCString {
                Darwin.fstatat(
                    current.rawValue,
                    $0,
                    &metadata,
                    AT_SYMLINK_NOFOLLOW | AT_RESOLVE_BENEATH | AT_REALDEV
                )
            }
            if lookup != 0 {
                guard errno == ENOENT else {
                    throw posixError("Unable to inspect local-state directory \(walked)")
                }
                guard createMissing else { return nil }
                var parent = stat()
                guard Darwin.fstat(current.rawValue, &parent) == 0 else {
                    throw posixError("Unable to inspect local-state parent for \(walked)")
                }
                guard parent.st_uid == getuid() else {
                    throw KeepItCleanError.ownerMismatch(walked)
                }
                let made = component.withCString {
                    Darwin.mkdirat(current.rawValue, $0, mode_t(0o700))
                }
                if made != 0, errno != EEXIST {
                    throw posixError("Unable to create local-state directory \(walked)")
                }
                lookup = component.withCString {
                    Darwin.fstatat(
                        current.rawValue,
                        $0,
                        &metadata,
                        AT_SYMLINK_NOFOLLOW | AT_RESOLVE_BENEATH | AT_REALDEV
                    )
                }
                guard lookup == 0 else {
                    throw posixError("Unable to inspect created local-state directory \(walked)")
                }
            }

            guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
                if metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK) {
                    throw KeepItCleanError.symbolicLink(walked)
                }
                throw KeepItCleanError.invalidPath("Not a directory: \(walked)")
            }
            let next = component.withCString {
                Darwin.openat(
                    current.rawValue,
                    $0,
                    O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_DIRECTORY
                )
            }
            guard next >= 0 else {
                throw posixError("Unable to securely open local-state directory \(walked)")
            }
            current = SecureStateDescriptor(next)
        }

        var final = stat()
        guard Darwin.fstat(current.rawValue, &final) == 0,
              final.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              final.st_uid == getuid(),
              final.st_mode & mode_t(0o022) == 0
        else {
            throw KeepItCleanError.io(
                "Local state directory is not private and user-owned: \(canonicalPath)"
            )
        }
        let directory = SecureStateDirectory(
            canonicalPath: canonicalPath,
            components: components,
            descriptor: current,
            observer: observer
        )
        try observer.reached(
            .directoryOpenedBeforeBindingVerification,
            context: SecureStateContext(
                directoryPath: canonicalPath,
                fileName: nil
            )
        )
        try directory.verifyPathBinding()
        return directory
    }

    private static func openComponents(
        _ components: [String]
    ) throws -> SecureStateDescriptor? {
        let root = Darwin.open("/", O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_DIRECTORY)
        guard root >= 0 else {
            throw posixError("Unable to open filesystem root")
        }
        var current = SecureStateDescriptor(root)
        for component in components {
            let next = component.withCString {
                Darwin.openat(
                    current.rawValue,
                    $0,
                    O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_DIRECTORY
                )
            }
            if next < 0, errno == ENOENT { return nil }
            guard next >= 0 else {
                throw posixError("Unable to reopen local-state directory component \(component)")
            }
            current = SecureStateDescriptor(next)
        }
        return current
    }

    private func requirePrivateRegularFile(
        _ fileDescriptor: Int32,
        displayName: String
    ) throws {
        var metadata = stat()
        guard Darwin.fstat(fileDescriptor, &metadata) == 0,
              metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              metadata.st_uid == getuid(),
              metadata.st_mode & mode_t(0o022) == 0
        else {
            throw KeepItCleanError.io(
                "Local state file is not private and user-owned: \(canonicalPath)/\(displayName)"
            )
        }
    }

    private func entryIdentity(
        descriptor fileDescriptor: Int32,
        displayName: String
    ) throws -> SecureStateEntryIdentity {
        var metadata = stat()
        guard Darwin.fstat(fileDescriptor, &metadata) == 0 else {
            throw posixError("Unable to inspect local state file \(displayName)")
        }
        return try validatedEntryIdentity(metadata, displayName: displayName)
    }

    private func entryIdentityIfPresent(
        named name: String
    ) throws -> SecureStateEntryIdentity? {
        guard let identity = try rawEntryIdentityIfPresent(named: name) else {
            return nil
        }
        guard identity.kind == UInt16(S_IFREG),
              identity.owner == getuid(),
              identity.mode & UInt16(0o022) == 0
        else {
            throw KeepItCleanError.io(
                "Local state file is not private and user-owned: \(canonicalPath)/\(name)"
            )
        }
        return identity
    }

    private func rawEntryIdentityIfPresent(
        named name: String
    ) throws -> SecureStateEntryIdentity? {
        var metadata = stat()
        let result = name.withCString {
            Darwin.fstatat(
                descriptor.rawValue,
                $0,
                &metadata,
                AT_SYMLINK_NOFOLLOW | AT_RESOLVE_BENEATH | AT_REALDEV
            )
        }
        if result != 0, errno == ENOENT { return nil }
        guard result == 0 else {
            throw posixError("Unable to inspect local state file \(canonicalPath)/\(name)")
        }
        return SecureStateEntryIdentity(metadata)
    }

    private func validatedEntryIdentity(
        _ metadata: stat,
        displayName: String
    ) throws -> SecureStateEntryIdentity {
        guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              metadata.st_uid == getuid(),
              metadata.st_mode & mode_t(0o022) == 0
        else {
            throw KeepItCleanError.io(
                "Local state file is not private and user-owned: \(canonicalPath)/\(displayName)"
            )
        }
        return SecureStateEntryIdentity(metadata)
    }

    private func rollbackStoreSwapIfPossible(
        temporary: String,
        destination: String,
        publishedIdentity: SecureStateEntryIdentity,
        displacedIdentity: SecureStateEntryIdentity
    ) throws {
        guard try rawEntryIdentityIfPresent(named: destination) == publishedIdentity,
              try rawEntryIdentityIfPresent(named: temporary) == displacedIdentity
        else {
            throw KeepItCleanError.io(
                "Local state publication changed concurrently; recovery entries remain in \(canonicalPath)."
            )
        }
        let result = temporary.withCString { temporaryPointer in
            destination.withCString { destinationPointer in
                Darwin.renameatx_np(
                    descriptor.rawValue,
                    temporaryPointer,
                    descriptor.rawValue,
                    destinationPointer,
                    UInt32(RENAME_SWAP | RENAME_NOFOLLOW_ANY | RENAME_RESOLVE_BENEATH)
                )
            }
        }
        guard result == 0 else {
            throw posixError(
                "Unable to roll back concurrent local state publication in \(canonicalPath)"
            )
        }
        guard try rawEntryIdentityIfPresent(named: destination) == displacedIdentity,
              try rawEntryIdentityIfPresent(named: temporary) == publishedIdentity
        else {
            throw KeepItCleanError.io(
                "Local state rollback completed with unexpected identities in \(canonicalPath)."
            )
        }
        guard Darwin.fsync(descriptor.rawValue) == 0 else {
            throw posixError("Unable to persist local state rollback in \(canonicalPath)")
        }
    }

    private func readAll(
        descriptor fileDescriptor: Int32,
        maximumBytes: Int,
        displayName: String
    ) throws -> Data {
        var metadata = stat()
        guard Darwin.fstat(fileDescriptor, &metadata) == 0 else {
            throw posixError("Unable to inspect local state file \(displayName)")
        }
        guard metadata.st_size >= 0, metadata.st_size <= maximumBytes else {
            throw KeepItCleanError.io("Local state file exceeds its size limit: \(displayName)")
        }

        var result = Data()
        result.reserveCapacity(Int(metadata.st_size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(fileDescriptor, $0.baseAddress, $0.count)
            }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else {
                throw posixError("Unable to read local state file \(displayName)")
            }
            if count == 0 { break }
            guard result.count + count <= maximumBytes else {
                throw KeepItCleanError.io("Local state file exceeds its size limit: \(displayName)")
            }
            result.append(contentsOf: buffer.prefix(count))
        }
        return result
    }

    private func writeAll(
        _ data: Data,
        descriptor fileDescriptor: Int32,
        displayName: String
    ) throws {
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(
                    fileDescriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                if written < 0, errno == EINTR { continue }
                guard written > 0 else {
                    throw posixError("Unable to write local state file \(displayName)")
                }
                offset += written
            }
        }
    }

    private func validateBasename(_ name: String) throws -> String {
        guard !name.isEmpty,
              name != ".",
              name != "..",
              !name.contains("/"),
              !name.unicodeScalars.contains(where: {
                  $0.value == 0 || $0.value < 0x20 || $0.value == 0x7F
              })
        else {
            throw KeepItCleanError.invalidPath(name)
        }
        return name
    }

    private static func posixError(
        _ message: String,
        code: Int32 = errno
    ) -> KeepItCleanError {
        .io("\(message): \(String(cString: strerror(code)))")
    }

    private func posixError(
        _ message: String,
        code: Int32 = errno
    ) -> KeepItCleanError {
        Self.posixError(message, code: code)
    }
}

private struct SecureStateEntryIdentity: Equatable {
    let device: UInt64
    let inode: UInt64
    let owner: UInt32
    let kind: UInt16
    let mode: UInt16
    let size: Int64
    let linkCount: UInt64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64

    init(_ metadata: stat) {
        device = UInt64(UInt32(bitPattern: metadata.st_dev))
        inode = UInt64(metadata.st_ino)
        owner = metadata.st_uid
        kind = UInt16(metadata.st_mode & mode_t(S_IFMT))
        mode = UInt16(metadata.st_mode & mode_t(0o7777))
        size = metadata.st_size
        linkCount = UInt64(metadata.st_nlink)
        modifiedSeconds = Int64(metadata.st_mtimespec.tv_sec)
        modifiedNanoseconds = Int64(metadata.st_mtimespec.tv_nsec)
    }
}
