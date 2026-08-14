import Foundation
import KeepItCleanCore
import KeepItCleanFS

public final class SystemStateStore: @unchecked Sendable {
    public let baseDirectory: URL
    public let ownerID: UInt32
    private let fileSystem = FDRelativeFileSystem()
    private let lock = NSLock()

    public init(
        baseDirectory: URL = URL(fileURLWithPath: "/var/db/KeepItClean", isDirectory: true),
        ownerID: UInt32 = 0
    ) {
        self.baseDirectory = baseDirectory.standardizedFileURL
        self.ownerID = ownerID
    }

    public var quarantineDirectory: URL {
        baseDirectory.appendingPathComponent("Quarantine", isDirectory: true)
    }

    public func save(plan: SystemCleanupPlan) throws {
        try withLock {
            let directory = try prepareDirectory("Plans")
            try SecureJSONStateDirectory(directory: directory).writeNew(
                plan,
                named: "\(plan.id.uuidString).json"
            )
        }
    }

    public func loadPlan(id: UUID) throws -> SystemCleanupPlan {
        try withLock {
            try SecureJSONStateDirectory(
                directory: baseDirectory.appendingPathComponent("Plans", isDirectory: true)
            ).read(
                SystemCleanupPlan.self,
                named: "\(id.uuidString).json"
            )
        }
    }

    public func save(operation: SystemCleanupOperation) throws {
        try withLock {
            let directory = try prepareDirectory("Operations")
            try SecureJSONStateDirectory(directory: directory).replace(
                operation,
                named: "\(operation.id.uuidString).json"
            )
        }
    }

    public func loadOperation(id: UUID) throws -> SystemCleanupOperation {
        try withLock {
            try SecureJSONStateDirectory(
                directory: baseDirectory.appendingPathComponent("Operations", isDirectory: true)
            ).read(
                SystemCleanupOperation.self,
                named: "\(id.uuidString).json"
            )
        }
    }

    public func prepareQuarantine(operationID: UUID) throws -> URL {
        try withLock {
            _ = try prepareDirectory("Quarantine")
            let operation = quarantineDirectory.appendingPathComponent(
                operationID.uuidString,
                isDirectory: true
            )
            try fileSystem.ensurePrivateDirectory(
                atAbsolutePath: operation.path,
                ownerID: ownerID
            )
            return operation
        }
    }

    private func prepareDirectory(_ name: String) throws -> URL {
        try fileSystem.ensurePrivateDirectory(
            atAbsolutePath: baseDirectory.path,
            ownerID: ownerID
        )
        let directory = baseDirectory.appendingPathComponent(name, isDirectory: true)
        try fileSystem.ensurePrivateDirectory(
            atAbsolutePath: directory.path,
            ownerID: ownerID
        )
        return directory
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
