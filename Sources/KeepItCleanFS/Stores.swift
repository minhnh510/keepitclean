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
            try SecureLocalFile.validateExistingAncestors(baseDirectory)
            try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
            try SecureLocalFile.validateOwnedDirectory(
                baseDirectory,
                requirePrivatePermissions: false
            )
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: baseDirectory.path)
            try SecureLocalFile.validateOwnedDirectory(baseDirectory)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try SecureLocalFile.writeNew(encoder.encode(value), to: url)
        } catch {
            throw KeepItCleanError.io("Unable to save plan: \(error.localizedDescription)")
        }
    }

    private func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        do {
            try SecureLocalFile.validateOwnedDirectory(baseDirectory)
            let decoder = JSONDecoder()
            return try decoder.decode(type, from: SecureLocalFile.read(url))
        } catch {
            throw KeepItCleanError.io("Unable to load plan \(url.path): \(error.localizedDescription)")
        }
    }

    private func validatedStoredURL(_ url: URL) throws -> URL {
        let base = baseDirectory.standardizedFileURL.path
        let checked = url.standardizedFileURL
        guard checked.path != base, checked.path.hasPrefix(base + "/") else {
            throw KeepItCleanError.protectedPath(checked.path)
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
            var records = try readAllUnlocked()
            records.removeAll { $0.id == operation.id }
            records.append(operation)
            if records.count > maximumRecords {
                records = Array(records.suffix(maximumRecords))
            }

            let encoder = Self.encoder()
            var data = Data()
            for record in records.reversed() {
                let line = try encoder.encode(record) + Data([0x0A])
                if data.count + line.count > maximumBytes, !data.isEmpty { break }
                data.insert(contentsOf: line, at: 0)
            }

            do {
                try SecureLocalFile.validateExistingAncestors(logURL.deletingLastPathComponent())
                try FileManager.default.createDirectory(
                    at: logURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try SecureLocalFile.validateOwnedDirectory(
                    logURL.deletingLastPathComponent(),
                    requirePrivatePermissions: false
                )
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o700],
                    ofItemAtPath: logURL.deletingLastPathComponent().path
                )
                try SecureLocalFile.validateOwnedDirectory(logURL.deletingLastPathComponent())
                try data.write(to: logURL, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: logURL.path)
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
        guard FileManager.default.fileExists(atPath: logURL.path) else { return [] }
        do {
            try SecureLocalFile.validateOwnedDirectory(logURL.deletingLastPathComponent())
            let data = try SecureLocalFile.read(logURL)
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

private enum SecureLocalFile {
    static func validateExistingAncestors(_ url: URL) throws {
        let canonicalPath = PathValidationPolicy.canonicalSystemAlias(url.standardizedFileURL.path)
        var current = "/"
        for component in NSString(string: canonicalPath).pathComponents.dropFirst() {
            current = URL(fileURLWithPath: current, isDirectory: true)
                .appendingPathComponent(component).path
            var value = stat()
            if current.withCString({ Darwin.lstat($0, &value) }) != 0 {
                if errno == ENOENT { return }
                throw KeepItCleanError.io(
                    "Unable to inspect local-state ancestor \(current): \(String(cString: strerror(errno)))"
                )
            }
            guard value.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
                throw KeepItCleanError.io(
                    "Local-state ancestor is not a real directory: \(current)"
                )
            }
        }
    }

    static func validateOwnedDirectory(
        _ url: URL,
        requirePrivatePermissions: Bool = true
    ) throws {
        var current = "/"
        let canonicalPath = PathValidationPolicy.canonicalSystemAlias(url.standardizedFileURL.path)
        for component in NSString(string: canonicalPath).pathComponents.dropFirst() {
            current = URL(fileURLWithPath: current, isDirectory: true)
                .appendingPathComponent(component).path
            var ancestor = stat()
            guard current.withCString({ Darwin.lstat($0, &ancestor) }) == 0,
                  ancestor.st_mode & mode_t(S_IFMT) != mode_t(S_IFLNK)
            else {
                throw KeepItCleanError.io(
                    "Local state directory has a missing or symbolic-link ancestor: \(current)"
                )
            }
        }

        var value = stat()
        guard url.path.withCString({ Darwin.lstat($0, &value) }) == 0,
              value.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              value.st_uid == getuid(),
              !requirePrivatePermissions || value.st_mode & 0o022 == 0
        else {
            throw KeepItCleanError.io(
                "Local state directory is not a protected user-owned real directory: \(url.path)"
            )
        }
    }

    static func read(_ url: URL) throws -> Data {
        let descriptor = url.path.withCString {
            Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            throw KeepItCleanError.io("Unable to securely open \(url.path): \(String(cString: strerror(errno)))")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)

        var value = stat()
        guard Darwin.fstat(descriptor, &value) == 0,
              value.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              value.st_uid == getuid(),
              value.st_mode & 0o022 == 0
        else {
            try? handle.close()
            throw KeepItCleanError.io("Local state file is not a protected user-owned regular file: \(url.path)")
        }
        return try handle.readToEnd() ?? Data()
    }

    static func writeNew(_ data: Data, to url: URL) throws {
        let descriptor = url.path.withCString {
            Darwin.open(
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                mode_t(0o600)
            )
        }
        guard descriptor >= 0 else {
            throw KeepItCleanError.io(
                "Refusing to replace existing plan \(url.path): \(String(cString: strerror(errno)))"
            )
        }
        var completed = false
        defer {
            Darwin.close(descriptor)
            if !completed {
                url.path.withCString { _ = Darwin.unlink($0) }
            }
        }

        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                if written < 0, errno == EINTR { continue }
                guard written > 0 else {
                    throw KeepItCleanError.io(
                        "Unable to write immutable plan \(url.path): \(String(cString: strerror(errno)))"
                    )
                }
                offset += written
            }
        }
        guard Darwin.fsync(descriptor) == 0 else {
            throw KeepItCleanError.io(
                "Unable to persist immutable plan \(url.path): \(String(cString: strerror(errno)))"
            )
        }
        completed = true
    }
}
