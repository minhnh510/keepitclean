import Foundation
import KeepItCleanCore
@testable import KeepItCleanRules
import Testing

@Test func conservativeProcessProbeIsTriState() {
    let active = ConservativeProcessStateProbe(
        provider: FixedSnapshotProvider(records: [
            ProcessRecord(executable: "/usr/bin/java", arguments: "java org.gradle.launcher.daemon.bootstrap.GradleDaemon"),
        ])
    )
    #expect(active.state(for: KnownProcessProbes.gradle) == .active)
    #expect(active.state(matching: ["gradle", "org.gradle.launcher.daemon"]) == .active)

    let inactive = ConservativeProcessStateProbe(
        provider: FixedSnapshotProvider(records: [
            ProcessRecord(executable: "/sbin/launchd", arguments: "/sbin/launchd"),
        ])
    )
    #expect(inactive.state(for: KnownProcessProbes.gradle) == .inactive)
    #expect(inactive.state(matching: ["gradle"]) == .inactive)

    let scannerOnly = ConservativeProcessStateProbe(
        provider: FixedSnapshotProvider(records: [
            ProcessRecord(executable: "/tmp/keep", arguments: "keep scan --root /Users/test/.gradle"),
        ])
    )
    #expect(scannerOnly.state(matching: ["gradle", "org.gradle.launcher.daemon"]) == .inactive)
    #expect(scannerOnly.state(matching: ["lldb", "lldb-rpc-server"]) == .inactive)

    let scannerAtProtectedRoots = ConservativeProcessStateProbe(
        provider: FixedSnapshotProvider(records: [
            ProcessRecord(
                executable: "/tmp/keep",
                arguments: "keep scan --root /Users/test/.codex/cache --root /Users/test/.vscode/extensions --root /Users/test/.colima"
            ),
        ])
    )
    #expect(scannerAtProtectedRoots.state(for: KnownProcessProbes.codex) == .inactive)
    #expect(scannerAtProtectedRoots.state(for: KnownProcessProbes.visualStudioCode) == .inactive)
    #expect(scannerAtProtectedRoots.state(for: KnownProcessProbes.colimaDocker) == .inactive)

    let unrelatedElectron = ConservativeProcessStateProbe(
        provider: FixedSnapshotProvider(records: [
            ProcessRecord(
                executable: "/Applications/Slack.app/Contents/Frameworks/Electron Framework.framework/Electron Framework",
                arguments: "/Applications/Slack.app/Contents/MacOS/Slack"
            ),
        ])
    )
    #expect(unrelatedElectron.state(for: KnownProcessProbes.visualStudioCode) == .inactive)

    let actualVSCode = ConservativeProcessStateProbe(
        provider: FixedSnapshotProvider(records: [
            ProcessRecord(
                executable: "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper",
                arguments: "/Applications/Visual Studio Code.app/Contents/MacOS/Electron"
            ),
        ])
    )
    #expect(actualVSCode.state(for: KnownProcessProbes.visualStudioCode) == .active)

    let actualCodexDesktop = ConservativeProcessStateProbe(
        provider: FixedSnapshotProvider(records: [
            ProcessRecord(
                executable: "/Applications/ChatGPT.app/Contents/Frameworks/Codex Framework.framework/Codex Service",
                arguments: "Codex Service --user-data-dir=/Users/test/Library/Application Support/Codex"
            ),
        ])
    )
    #expect(actualCodexDesktop.state(for: KnownProcessProbes.codex) == .active)

    let actualCodexAppServer = ConservativeProcessStateProbe(
        provider: FixedSnapshotProvider(records: [
            ProcessRecord(
                executable: "/Applications/ChatGPT.app/Contents/Resources/codex",
                arguments: "codex -c features.code_mode_host=true app-server"
            ),
        ])
    )
    #expect(actualCodexAppServer.state(for: KnownProcessProbes.codex) == .active)

    let actualColima = ConservativeProcessStateProbe(
        provider: FixedSnapshotProvider(records: [
            ProcessRecord(
                executable: "/usr/local/bin/qemu-system-aarch64",
                arguments: "qemu-system-aarch64 -pidfile /Users/test/.colima/_lima/colima/qemu.pid"
            ),
        ])
    )
    #expect(actualColima.state(for: KnownProcessProbes.colimaDocker) == .active)

    let empty = ConservativeProcessStateProbe(provider: FixedSnapshotProvider(records: []))
    #expect(empty.state(for: KnownProcessProbes.gradle) == .unknown)
    #expect(empty.state(matching: ["gradle"]) == .unknown)

    let failed = ConservativeProcessStateProbe(provider: FailingSnapshotProvider())
    #expect(failed.state(for: KnownProcessProbes.gradle) == .unknown)
    #expect(failed.state(matching: ["gradle"]) == .unknown)
}

@Test func scannerReturnsPartialReportAndKeepsDeterministicCandidates() async {
    let identity = FileIdentity(
        device: 1,
        inode: 2,
        ownerID: 501,
        fileKind: .directory,
        logicalBytes: 100,
        allocatedBytes: 4_096,
        modifiedAt: .distantPast
    )
    let scanner = RuleScanner(adapters: [
        ThrowingRuleAdapter(),
        StaticRuleAdapter(candidates: [
            Candidate(
                ruleID: "z",
                category: "B",
                path: "/tmp/z",
                displayName: "z",
                evidence: "fixture",
                identity: identity,
                actionKind: .trash,
                risk: .low,
                rebuildCost: .low,
                activeState: .inactive,
                defaultSelected: false
            ),
            Candidate(
                ruleID: "a",
                category: "A",
                path: "/tmp/a",
                displayName: "a",
                evidence: "fixture",
                identity: identity,
                actionKind: .trash,
                risk: .low,
                rebuildCost: .low,
                activeState: .inactive,
                defaultSelected: false
            ),
        ]),
    ])

    let report = await scanner.scan(
        request: ScanRequest(roots: [], homePath: "/tmp", now: Date(timeIntervalSince1970: 100))
    )
    #expect(report.partial)
    #expect(report.issues.count == 1)
    #expect(report.candidates.map(\.path) == ["/tmp/a", "/tmp/z"])
}

private struct FixedSnapshotProvider: ProcessSnapshotProviding {
    let records: [ProcessRecord]
    func snapshot() throws -> [ProcessRecord] { records }
}

private struct FailingSnapshotProvider: ProcessSnapshotProviding {
    func snapshot() throws -> [ProcessRecord] {
        throw KeepItCleanError.io("fixture failure")
    }
}

private struct ThrowingRuleAdapter: RuleAdapter {
    let descriptor = RuleDescriptor(id: "throws", name: "throws", category: "test", summary: "fixture")
    func scan(request: ScanRequest) async throws -> [Candidate] {
        throw KeepItCleanError.io("fixture adapter failed")
    }
}

private struct StaticRuleAdapter: RuleAdapter {
    let descriptor = RuleDescriptor(id: "static", name: "static", category: "test", summary: "fixture")
    let candidates: [Candidate]
    func scan(request: ScanRequest) async throws -> [Candidate] { candidates }
}
