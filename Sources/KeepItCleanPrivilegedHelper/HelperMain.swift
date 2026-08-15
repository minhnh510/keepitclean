import Darwin
import Foundation
import KeepItCleanCore
import KeepItCleanFS
import KeepItCleanSystem

private struct HelperEnvelope<Payload: Encodable>: Encodable {
    let schemaVersion = keepItCleanSchemaVersion
    let status: String
    let data: Payload
}

@main
enum KeepItCleanPrivilegedHelper {
    static func main() {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            if arguments == ["--version"] {
                FileHandle.standardOutput.write(
                    Data("KeepItCleanPrivilegedHelper \(keepItCleanVersion) protocol-1\n".utf8)
                )
                return
            }
            guard geteuid() == 0 else {
                throw KeepItCleanError.unsupported(
                    "The KeepItClean privileged helper must run as root through the approved CLI flow."
                )
            }
            _ = Darwin.umask(mode_t(0o077))
            let reader = LocalFileSystemReader()
            let scanner = SystemCacheScanner(fileSystem: reader)
            let store = SystemStateStore()
            let engine = SystemCleanupEngine(
                scanner: scanner,
                store: store,
                reader: reader
            )
            guard let command = arguments.first else {
                throw KeepItCleanError.unsupported("Missing privileged helper command.")
            }

            switch command {
            case "scan":
                try emit(engine.scan())
            case "apply":
                guard arguments.count == 3, let id = UUID(uuidString: arguments[1]) else {
                    throw KeepItCleanError.invalidPath(
                        "apply requires one plan UUID and exact confirmation token"
                    )
                }
                try emit(engine.apply(planID: id, confirmationToken: arguments[2]))
            case "undo":
                guard arguments.count == 2, let id = UUID(uuidString: arguments[1]) else {
                    throw KeepItCleanError.invalidPath("undo requires one operation UUID")
                }
                try emit(engine.undo(operationID: id))
            case "finalize":
                guard arguments.count == 3,
                      let id = UUID(uuidString: arguments[1])
                else {
                    throw KeepItCleanError.invalidPath(
                        "finalize requires one operation UUID and exact token"
                    )
                }
                try emit(engine.finalize(operationID: id, confirmationToken: arguments[2]))
            case "doctor":
                try emit(["helper": "ready", "state": "/var/db/KeepItClean"])
            default:
                throw KeepItCleanError.unsupported("Unknown privileged helper command: \(command)")
            }
        } catch {
            FileHandle.standardError.write(
                Data(("KeepItClean privileged helper: \(error.localizedDescription)\n").utf8)
            )
            Darwin.exit(1)
        }
    }

    private static func emit<Payload: Encodable>(_ payload: Payload) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(HelperEnvelope(status: "ok", data: payload))
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}
