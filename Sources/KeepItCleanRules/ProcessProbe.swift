import Foundation
import KeepItCleanCore

/// A bounded, read-only process query used by rules immediately before they
/// classify tool-owned cache leaves. A rule must treat `.unknown` exactly like
/// `.active`: neither state authorizes a cleanup candidate.
public struct ProcessProbe: Hashable, Sendable {
    public let id: String
    public let executableNames: Set<String>
    public let argumentFragments: Set<String>

    public init(
        id: String,
        executableNames: Set<String> = [],
        argumentFragments: Set<String> = []
    ) {
        self.id = id
        self.executableNames = Set(executableNames.map { $0.lowercased() })
        self.argumentFragments = Set(argumentFragments.map { $0.lowercased() })
    }
}

public struct ProcessRecord: Hashable, Sendable {
    public let executable: String
    public let arguments: String

    public init(executable: String, arguments: String) {
        self.executable = executable
        self.arguments = arguments
    }

    fileprivate var executableBasename: String {
        URL(fileURLWithPath: executable).lastPathComponent.lowercased()
    }

    fileprivate var normalizedArguments: String {
        arguments.lowercased()
    }
}

public protocol ProcessSnapshotProviding: Sendable {
    func snapshot() throws -> [ProcessRecord]
}

public protocol ProcessStateProbing: Sendable {
    func state(for probe: ProcessProbe) -> ActiveState
}

public struct ConservativeProcessStateProbe: ProcessStateProbing, ProcessProbing, Sendable {
    private let provider: any ProcessSnapshotProviding

    public init(provider: any ProcessSnapshotProviding) {
        self.provider = provider
    }

    public func state(for probe: ProcessProbe) -> ActiveState {
        let records: [ProcessRecord]
        do {
            records = try provider.snapshot()
        } catch {
            return .unknown
        }

        // A real macOS process table is never empty. Treat an empty snapshot as
        // an incomplete observation instead of incorrectly proving inactivity.
        guard !records.isEmpty else {
            return .unknown
        }

        for record in records {
            if probe.executableNames.contains(record.executableBasename) {
                return .active
            }

            let arguments = record.normalizedArguments
            if probe.argumentFragments.contains(where: { arguments.contains($0) }) {
                return .active
            }
        }

        return .inactive
    }

    /// Core's catalog-facing probe accepts a flat set of process terms. Match
    /// executable basenames exactly and command arguments by containment. The
    /// observation still fails closed when the process table is unavailable.
    public func state(matching processNames: [String]) -> ActiveState {
        let terms = Set(
            processNames
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
        )
        guard !terms.isEmpty else { return .inactive }

        var executableTerms = Set<String>()
        var argumentTerms = Set<String>()
        for term in terms {
            if term.hasPrefix("exe:") {
                executableTerms.insert(String(term.dropFirst(4)))
            } else if term.hasPrefix("arg:") {
                argumentTerms.insert(String(term.dropFirst(4)))
            } else if term.contains("/") || term.contains(".") || term.contains(" ") {
                argumentTerms.insert(term)
            } else {
                // Bare terms are executable basenames only. Otherwise the
                // scan command's own `--root ~/.lldb` argv self-matches LLDB.
                executableTerms.insert(term)
            }
        }

        let records: [ProcessRecord]
        do {
            records = try provider.snapshot()
        } catch {
            return .unknown
        }
        guard !records.isEmpty else { return .unknown }

        for record in records {
            if executableTerms.contains(record.executableBasename) {
                return .active
            }
            if argumentTerms.contains(where: { record.normalizedArguments.contains($0) }) {
                return .active
            }
        }
        return .inactive
    }
}

/// Production provider. It is intentionally separate from the matcher so all
/// rule tests can inject a deterministic snapshot and never inspect the host.
public struct SystemProcessSnapshotProvider: ProcessSnapshotProviding {
    public init() {}

    public func snapshot() throws -> [ProcessRecord] {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "comm=,args="]
        process.standardOutput = output
        process.standardError = errors

        try process.run()
        // Drain stdout while `ps` is running. Waiting first can deadlock when a
        // large process table fills the pipe buffer.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errorData, as: UTF8.self)
            throw KeepItCleanError.io("Unable to inspect process state: \(message)")
        }

        return Self.parse(String(decoding: data, as: UTF8.self))
    }

    static func parse(_ output: String) -> [ProcessRecord] {
        output.split(whereSeparator: \.isNewline).compactMap { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { return nil }

            let pieces = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard let executable = pieces.first else { return nil }
            let arguments = pieces.count == 2 ? String(pieces[1]) : String(executable)
            return ProcessRecord(executable: String(executable), arguments: arguments)
        }
    }
}

public enum KnownProcessProbes {
    public static let gradle = ProcessProbe(
        id: "gradle",
        executableNames: ["gradle", "gradlew"],
        argumentFragments: ["org.gradle.launcher.daemon", "gradledaemon"]
    )
    public static let lldb = ProcessProbe(
        id: "lldb",
        executableNames: ["lldb", "debugserver"],
        argumentFragments: ["lldb-rpc-server"]
    )
    public static let kotlinNative = ProcessProbe(
        id: "kotlin-native",
        executableNames: ["konanc", "cinterop"],
        argumentFragments: ["kotlin-native"]
    )
    public static let codex = ProcessProbe(
        id: "codex",
        executableNames: ["codex"],
        argumentFragments: [
            "/codex.app/",
            "/library/application support/codex",
            "features.code_mode_host=true app-server",
        ]
    )
    public static let android = ProcessProbe(
        id: "android",
        executableNames: ["emulator"],
        argumentFragments: ["qemu-system-", "-avd "]
    )
    public static let colimaDocker = ProcessProbe(
        id: "colima-docker",
        executableNames: [
            "colima", "docker", "dockerd", "containerd", "lima", "limactl", "hostagent",
        ],
        argumentFragments: ["docker desktop", "/.colima/_lima/", "lima-colima"]
    )
    public static let cocoaPods = ProcessProbe(
        id: "cocoapods",
        executableNames: ["pod"],
        argumentFragments: ["cocoapods"]
    )
    public static let maven = ProcessProbe(
        id: "maven",
        executableNames: ["mvn", "mvnw"],
        argumentFragments: ["org.codehaus.plexus.classworlds.launcher"]
    )
    public static let xcode = ProcessProbe(
        id: "xcode",
        executableNames: ["xcode", "xcodebuild", "swift-frontend"],
        argumentFragments: ["sourcekitservice", "/xcode.app/"]
    )
    public static let visualStudioCode = ProcessProbe(
        id: "vscode",
        executableNames: ["code"],
        argumentFragments: ["visual studio code.app"]
    )
}
