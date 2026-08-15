import Darwin
import Foundation
import KeepItCleanCore

/// Public, typed facade over KeepItClean's fd-relative private state store.
/// The directory is opened component-by-component without following symlinks;
/// files are locked, bounded, fsynced, and published relative to the held fd.
public struct SecureJSONStateDirectory: Sendable {
    public let directory: URL
    public let maximumBytes: Int

    public init(directory: URL, maximumBytes: Int = 64 * 1_024 * 1_024) {
        self.directory = directory.standardizedFileURL
        self.maximumBytes = max(1_024, maximumBytes)
    }

    public func writeNew<Value: Encodable>(_ value: Value, named name: String) throws {
        let data = try encode(value)
        let state = try SecureStateDirectory.openOrCreate(directory)
        let operationLock = try state.acquireExclusiveLock()
        defer { withExtendedLifetime(operationLock) {} }
        try state.writeNew(data, named: name)
    }

    public func replace<Value: Encodable>(_ value: Value, named name: String) throws {
        let data = try encode(value)
        let state = try SecureStateDirectory.openOrCreate(directory)
        let operationLock = try state.acquireExclusiveLock()
        defer { withExtendedLifetime(operationLock) {} }
        try state.replaceAtomically(data, named: name)
    }

    public func read<Value: Decodable>(_ type: Value.Type, named name: String) throws -> Value {
        let state = try SecureStateDirectory.openExisting(directory)
        let operationLock = try state.acquireExclusiveLock()
        defer { withExtendedLifetime(operationLock) {} }
        let data = try state.read(named: name, maximumBytes: maximumBytes)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }

    private func encode<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        guard data.count <= maximumBytes else {
            throw KeepItCleanError.io("Privileged state exceeds the \(maximumBytes)-byte limit.")
        }
        return data
    }
}
