import Darwin
import Foundation
import KeepItCleanCore
import KeepItCleanSystem

private struct PrivilegedHelperEnvelope<Payload: Decodable>: Decodable {
    let schemaVersion: Int
    let status: String
    let data: Payload
}

struct PrivilegedHelperClient: Sendable {
    private let sudoPath = "/usr/bin/sudo"
    private let helperPath: String

    init(helperPath: String = keepItCleanPrivilegedHelperPath) {
        self.helperPath = helperPath
    }

    func scan() throws -> SystemCleanupScanResult {
        try invoke(arguments: ["scan"], as: SystemCleanupScanResult.self)
    }

    func apply(planID: UUID, confirmationToken: String) throws -> SystemCleanupOperation {
        try invoke(
            arguments: ["apply", planID.uuidString, confirmationToken],
            as: SystemCleanupOperation.self
        )
    }

    func undo(operationID: UUID) throws -> SystemCleanupOperation {
        try invoke(arguments: ["undo", operationID.uuidString], as: SystemCleanupOperation.self)
    }

    func finalize(operationID: UUID, token: String) throws -> SystemCleanupOperation {
        try invoke(
            arguments: ["finalize", operationID.uuidString, token],
            as: SystemCleanupOperation.self
        )
    }

    func doctor() -> String {
        let check = doctorCheck()
        return check.status == "ok"
            ? "ready: root-owned helper installed at \(helperPath)"
            : "unavailable: \(check.message)"
    }

    func doctorCheck() -> DoctorCheck {
        do {
            try validateRootOwnedExecutable(sudoPath)
            try validateRootOwnedDirectory("/usr/bin")
            try validateRootOwnedExecutable(helperPath)
            try validateRootOwnedDirectory(
                URL(fileURLWithPath: helperPath).deletingLastPathComponent().path
            )
            return DoctorCheck(
                id: "system-helper",
                status: "ok",
                message: "Root-owned helper is installed and verified at \(helperPath)."
            )
        } catch {
            return DoctorCheck(
                id: "system-helper",
                status: "optional",
                message: "Optional system cleanup is unavailable. Run `make install-helper` from the source directory to enable it."
            )
        }
    }

    var isReady: Bool {
        do {
            try validateRootOwnedExecutable(sudoPath)
            try validateRootOwnedDirectory("/usr/bin")
            try validateRootOwnedExecutable(helperPath)
            try validateRootOwnedDirectory(
                URL(fileURLWithPath: helperPath).deletingLastPathComponent().path
            )
            return true
        } catch {
            return false
        }
    }

    private func invoke<Payload: Decodable>(
        arguments: [String],
        as type: Payload.Type
    ) throws -> Payload {
        try validateRootOwnedExecutable(sudoPath)
        try validateRootOwnedDirectory("/usr/bin")
        try validateRootOwnedExecutable(helperPath)
        try validateRootOwnedDirectory(
            URL(fileURLWithPath: helperPath).deletingLastPathComponent().path
        )
        let data = try spawnSudo(arguments: arguments)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let envelope = try decoder.decode(PrivilegedHelperEnvelope<Payload>.self, from: data)
        guard envelope.schemaVersion == keepItCleanSchemaVersion,
              envelope.status == "ok"
        else {
            throw KeepItCleanError.unsupported("Privileged helper returned an invalid envelope.")
        }
        return envelope.data
    }

    private func spawnSudo(arguments: [String]) throws -> Data {
        var descriptors = [Int32](repeating: -1, count: 2)
        guard Darwin.pipe(&descriptors) == 0 else {
            throw KeepItCleanError.io("Unable to create privileged helper output pipe.")
        }
        defer {
            if descriptors[0] >= 0 { Darwin.close(descriptors[0]) }
            if descriptors[1] >= 0 { Darwin.close(descriptors[1]) }
        }

        var actions: posix_spawn_file_actions_t? = nil
        guard posix_spawn_file_actions_init(&actions) == 0 else {
            throw KeepItCleanError.io("Unable to initialize privileged process actions.")
        }
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDOUT_FILENO)
        posix_spawn_file_actions_addclose(&actions, descriptors[0])

        let values = [
            sudoPath,
            "-p",
            "KeepItClean system cleanup requires administrator access: ",
            "--",
            helperPath,
        ] + arguments
        let storage = values.map { strdup($0) }
        defer { storage.forEach { free($0) } }
        var argv = storage + [nil]
        var processID = pid_t()
        let spawnStatus = posix_spawn(
            &processID,
            sudoPath,
            &actions,
            nil,
            &argv,
            environ
        )
        guard spawnStatus == 0 else {
            throw KeepItCleanError.io("Unable to launch /usr/bin/sudo (code \(spawnStatus)).")
        }
        Darwin.close(descriptors[1])
        descriptors[1] = -1

        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptors[0], $0.baseAddress, $0.count)
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw KeepItCleanError.io("Unable to read privileged helper output.")
            }
            guard output.count + count <= 64 * 1_024 * 1_024 else {
                kill(processID, SIGTERM)
                throw KeepItCleanError.io("Privileged helper output exceeded 64 MiB.")
            }
            output.append(contentsOf: buffer.prefix(count))
        }
        Darwin.close(descriptors[0])
        descriptors[0] = -1

        var status: Int32 = 0
        var waited: pid_t
        repeat {
            waited = waitpid(processID, &status, 0)
        } while waited < 0 && errno == EINTR
        guard waited == processID else {
            throw KeepItCleanError.io("Unable to collect privileged helper status.")
        }
        let exitedNormally = status & 0x7f == 0
        let exitCode = Int((status >> 8) & 0xff)
        guard exitedNormally, exitCode == 0 else {
            throw KeepItCleanError.io("Privileged helper was cancelled or failed.")
        }
        return output
    }

    private func validateRootOwnedExecutable(_ path: String) throws {
        var metadata = stat()
        guard Darwin.lstat(path, &metadata) == 0,
              metadata.st_uid == 0,
              metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              metadata.st_mode & mode_t(0o022) == 0,
              metadata.st_mode & mode_t(0o111) != 0
        else {
            throw KeepItCleanError.unsupported(
                "Install the root-owned helper first by running `make install-helper` from the KeepItClean source directory."
            )
        }
    }

    private func validateRootOwnedDirectory(_ path: String) throws {
        var metadata = stat()
        guard Darwin.lstat(path, &metadata) == 0,
              metadata.st_uid == 0,
              metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              metadata.st_mode & mode_t(0o022) == 0
        else {
            throw KeepItCleanError.protectedPath(path)
        }
    }
}
