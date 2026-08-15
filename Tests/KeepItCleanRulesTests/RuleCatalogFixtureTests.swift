import Foundation
import KeepItCleanCore
@testable import KeepItCleanRules
import Testing

@Test func defaultCatalogFindsExactLeavesAndProtectsDurableState() async throws {
    let fixture = try FixtureHome()
    let oldPaths = try populateFixture(fixture)
    for path in oldPaths {
        try fixture.markOld(path)
    }

    let projectRoot = fixture.url.appendingPathComponent("Projects").path
    let catalog = RuleCatalog(fileSystem: FixtureFileSystem(), processes: FixedProcessProbe(.inactive))
    let scanner = RuleScanner(
        catalog: catalog,
        homePath: fixture.url.path,
        roots: [projectRoot]
    )
    let report = await scanner.scan(
        request: ScanRequest(
            roots: [fixture.url.path, projectRoot],
            homePath: fixture.url.path,
            deep: true,
            now: Date()
        )
    )

    #expect(!report.partial)
    #expect(report.issues.isEmpty)

    let byPath = Dictionary(grouping: report.candidates, by: \.path)
    let trashPaths = Set(
        report.candidates.filter { $0.actionKind == .trash }.map(\.path)
    )

    #expect(trashPaths.contains(fixture.url.appendingPathComponent(".lldb/module-cache").path))
    #expect(trashPaths.contains(fixture.url.appendingPathComponent(".lldb/module_cache").path))
    let transformsRoot = fixture.url.appendingPathComponent(".gradle/caches/9.5.0/transforms").path
    #expect(!trashPaths.contains(transformsRoot))
    #expect(byPath[transformsRoot]?.allSatisfy { $0.actionKind == .reportOnly } == true)
    #expect(trashPaths.contains(fixture.url.appendingPathComponent(".gradle/.tmp/stale.bin").path))
    #expect(trashPaths.contains(fixture.url.appendingPathComponent(".konan/cache").path))
    #expect(trashPaths.contains(fixture.url.appendingPathComponent(".android/cache").path))
    #expect(trashPaths.contains(fixture.url.appendingPathComponent(".android/avd/Pixel.avd/cache.img").path))
    #expect(trashPaths.contains(fixture.url.appendingPathComponent("Projects/App/node_modules").path))
    #expect(trashPaths.contains(fixture.url.appendingPathComponent("Downloads/old-installer.dmg").path))

    let unknownTaggedCache = fixture.url.appendingPathComponent("Projects/App/.fixture-cache").path
    #expect(!trashPaths.contains(unknownTaggedCache))
    #expect(byPath[unknownTaggedCache]?.allSatisfy { $0.actionKind == .reportOnly } == true)

    let codexSessions = fixture.url.appendingPathComponent(".codex/sessions").path
    let codexDatabase = fixture.url.appendingPathComponent(".codex/state_5.sqlite").path
    let codexMemories = fixture.url.appendingPathComponent(".codex/memories").path
    let codexSkills = fixture.url.appendingPathComponent(".codex/skills").path
    let codexAttachments = fixture.url.appendingPathComponent(".codex/attachments").path
    let codexWorktrees = fixture.url.appendingPathComponent(".codex/worktrees").path
    for protectedPath in [
        codexSessions, codexDatabase, codexMemories, codexSkills, codexAttachments, codexWorktrees,
    ] {
        #expect(!trashPaths.contains(protectedPath))
        #expect(byPath[protectedPath]?.contains(where: { $0.actionKind == .reportOnly }) == true)
    }

    #expect(!trashPaths.contains(fixture.url.appendingPathComponent(".codex/auth.json").path))
    #expect(!trashPaths.contains(fixture.url.appendingPathComponent(".codex/config.toml").path))
    #expect(!trashPaths.contains(fixture.url.appendingPathComponent(".codex/.tmp/user-note").path))
    #expect(!trashPaths.contains(fixture.url.appendingPathComponent(".codex/worktrees/active/source.swift").path))
    #expect(!trashPaths.contains(fixture.url.appendingPathComponent(".lldbinit").path))
    #expect(!trashPaths.contains(fixture.url.appendingPathComponent(".android/avd/Pixel.avd/userdata-qemu.img").path))
    #expect(!trashPaths.contains(fixture.url.appendingPathComponent(".android/avd/Pixel.avd/snapshots/default_boot/ram.img").path))
    #expect(!trashPaths.contains(fixture.url.appendingPathComponent(".m2/settings.xml").path))
    #expect(!trashPaths.contains(fixture.url.appendingPathComponent("Library/Developer/Xcode/Archives/Release.xcarchive").path))
    #expect(!trashPaths.contains(fixture.url.appendingPathComponent(".vscode/settings.json").path))
    #expect(!trashPaths.contains(fixture.url.appendingPathComponent("Projects/App/src/main.swift").path))
    #expect(!trashPaths.contains(fixture.url.appendingPathComponent("Projects/App/output").path))
    #expect(!trashPaths.contains(fixture.url.appendingPathComponent("Projects/App/.invalid-cache").path))
    #expect(!trashPaths.contains(fixture.url.appendingPathComponent("Downloads/archive.zip").path))

    let colima = fixture.url.appendingPathComponent(".colima").path
    let maven = fixture.url.appendingPathComponent(".m2/repository").path
    let cocoaPodsRepo = fixture.url.appendingPathComponent(".cocoapods/repos").path
    let cocoaPodsHomeCache = fixture.url.appendingPathComponent(".cocoapods/cache/Pods").path
    let remoteMaven = fixture.url.appendingPathComponent(".m2/repository/org/remote/lib/1.0").path
    let localMaven = fixture.url.appendingPathComponent(".m2/repository/vn/momo/private-lib/1.0").path
    let oldExtension = fixture.url.appendingPathComponent(".vscode/extensions/openai.chatgpt-1.0.0-darwin-arm64").path
    let currentExtension = fixture.url.appendingPathComponent(".vscode/extensions/openai.chatgpt-2.0.0-darwin-arm64").path
    #expect(byPath[colima]?.allSatisfy { $0.actionKind == .native } == true)
    #expect(trashPaths.contains(remoteMaven))
    #expect(!trashPaths.contains(localMaven))
    #expect(byPath[oldExtension]?.allSatisfy { $0.actionKind == .reportOnly } == true)
    #expect(byPath[currentExtension] == nil)
    #expect(byPath[maven]?.allSatisfy { $0.actionKind == .reportOnly } == true)
    #expect(byPath[cocoaPodsRepo]?.allSatisfy { $0.actionKind == .reportOnly } == true)
    #expect(byPath[cocoaPodsHomeCache]?.allSatisfy { $0.actionKind == .native } == true)

    #expect(report.candidates == report.candidates.sorted(by: candidateOrder))
}

@Test func hardcoreGradleTransformsKeepSevenDaysAndTargetOnlyOldEntries() async throws {
    let fixture = try FixtureHome()
    let old = try fixture.file(".gradle/caches/9.5.0/transforms/old-hash/output.bin")
    let recent = try fixture.file(".gradle/caches/9.5.0/transforms/recent-hash/output.bin")
    try fixture.markOld(".gradle/caches/9.5.0/transforms/old-hash", days: 8)
    try fixture.markOld(".gradle/caches/9.5.0/transforms/recent-hash", days: 6)
    let root = fixture.url.appendingPathComponent(".gradle/caches/9.5.0/transforms").path
    let adapter = HardcoreGradleTransformRetentionAdapter(
        fileSystem: FixtureFileSystem(),
        processes: FixedProcessProbe(.inactive)
    )

    let candidates = try await adapter.scan(request: ScanRequest(
        roots: [root],
        homePath: fixture.url.path,
        deep: true,
        hardcore: true,
        now: Date()
    ))

    let candidate = try #require(candidates.first)
    #expect(candidates.count == 1)
    #expect(candidate.path == URL(fileURLWithPath: old).deletingLastPathComponent().path)
    #expect(candidate.path != URL(fileURLWithPath: recent).deletingLastPathComponent().path)
    #expect(candidate.ruleID == "hardcore.gradle-transforms-7d")
    #expect(candidate.actionKind == .trash)
    #expect(candidate.activeState == .inactive)
    #expect(candidate.evidence.contains("seven-day retention cutoff"))
    #expect(!candidates.contains { $0.path == root })
}

@Test func hardcoreGradleTransformsFailClosedWhileGradleIsActiveOrUnknown() async throws {
    let fixture = try FixtureHome()
    try fixture.file(".gradle/caches/9.5.0/transforms/old-hash/output.bin")
    try fixture.markOld(".gradle/caches/9.5.0/transforms/old-hash", days: 8)

    for state in [ActiveState.active, .unknown] {
        let adapter = HardcoreGradleTransformRetentionAdapter(
            fileSystem: FixtureFileSystem(),
            processes: FixedProcessProbe(state)
        )
        let candidates = try await adapter.scan(request: ScanRequest(
            roots: [fixture.url.path],
            homePath: fixture.url.path,
            deep: true,
            hardcore: true,
            now: Date()
        ))
        let candidate = try #require(candidates.first)
        #expect(candidate.actionKind == .blocked)
        #expect(candidate.activeState == state)
        #expect(candidate.reclaimableBytes == 0)
    }
}

@Test func activeAndUnknownProcessStatesBlockDeveloperCleanup() async throws {
    let fixture = try FixtureHome()
    try fixture.file(".gradle/caches/build-cache-1/data.bin")
    try fixture.markOld(".gradle/caches/build-cache-1")

    for state in [ActiveState.active, .unknown] {
        let catalog = RuleCatalog(fileSystem: FixtureFileSystem(), processes: FixedProcessProbe(state))
        let adapter = catalog.defaultAdapters(homePath: fixture.url.path, roots: [])
            .first { $0.descriptor.id == "gradle.transient" }
        let candidates = try await adapter?.scan(
            request: ScanRequest(roots: [], homePath: fixture.url.path, now: Date())
        )

        #expect(candidates?.count == 1)
        #expect(candidates?.first?.actionKind == .blocked)
        #expect(candidates?.first?.activeState == state)
        #expect(candidates?.first?.defaultSelected == false)
        #expect(candidates?.first?.blockReason != nil)
    }
}

@Test func shallowRuleScanDefersRecursiveAccountingUntilDeepPhase() async throws {
    let fixture = try FixtureHome()
    try fixture.file(".lldb/module_cache/module.pcm", contents: String(repeating: "x", count: 8_192))
    try fixture.markOld(".lldb/module_cache")
    let catalog = RuleCatalog(
        fileSystem: FixtureFileSystem(),
        processes: FixedProcessProbe(.inactive)
    )
    let adapter = try #require(
        catalog.defaultAdapters(homePath: fixture.url.path, roots: [])
            .first { $0.descriptor.id == "lldb.module-cache" }
    )
    let shallow = try await adapter.scan(request: ScanRequest(
        roots: [fixture.url.path],
        homePath: fixture.url.path,
        deep: false
    ))
    let deep = try await adapter.scan(request: ScanRequest(
        roots: [fixture.url.path],
        homePath: fixture.url.path,
        deep: true
    ))
    let shallowCandidate = try #require(shallow.first)
    let deepCandidate = try #require(deep.first)

    #expect(shallowCandidate.confidence == .low)
    #expect(deepCandidate.confidence == .high)
    #expect((deepCandidate.identity?.logicalBytes ?? 0) > (shallowCandidate.identity?.logicalBytes ?? 0))
    #expect((deepCandidate.identity?.allocatedBytes ?? 0) >= (shallowCandidate.identity?.allocatedBytes ?? 0))
}

@Test func symlinkCacheLeafIsBlockedWithoutMeasuringItsTarget() async throws {
    let fixture = try FixtureHome()
    try fixture.file("Sensitive/keep.txt")
    let link = try fixture.symbolicLink(
        ".gradle/caches/build-cache-linked",
        to: "Sensitive"
    )

    let catalog = RuleCatalog(
        fileSystem: SymlinkRejectingUsageFileSystem(),
        processes: FixedProcessProbe(.inactive)
    )
    let adapter = catalog.defaultAdapters(homePath: fixture.url.path, roots: [])
        .first { $0.descriptor.id == "gradle.transient" }
    let candidates = try await adapter?.scan(
        request: ScanRequest(roots: [], homePath: fixture.url.path, now: Date())
    )

    #expect(candidates?.count == 1)
    #expect(candidates?.first?.path == link)
    #expect(candidates?.first?.identity?.fileKind == .symbolicLink)
    #expect(candidates?.first?.actionKind == .blocked)
    #expect(candidates?.first?.blockReason?.contains("Symbolic") == true)
}

@Test func explicitScanRootDoesNotMeasureUnrelatedHomeRules() async throws {
    let fixture = try FixtureHome()
    try fixture.file(".gradle/caches/build-cache-1/data.bin")
    try fixture.file(".lldb/module_cache/object.pcm")
    try fixture.markOld(".gradle/caches/build-cache-1")
    try fixture.markOld(".lldb/module_cache")
    let root = fixture.url.appendingPathComponent(".lldb").path
    let scanner = RuleScanner(
        catalog: RuleCatalog(fileSystem: FixtureFileSystem(), processes: FixedProcessProbe(.inactive)),
        homePath: fixture.url.path,
        roots: [root]
    )

    let report = await scanner.scan(request: ScanRequest(
        roots: [root],
        homePath: fixture.url.path,
        deep: false
    ))

    #expect(!report.candidates.isEmpty)
    #expect(report.candidates.allSatisfy { $0.path == root || $0.path.hasPrefix(root + "/") })
    #expect(!report.candidates.contains { $0.path.contains("/.gradle/") })
}

@Test func cachedirTagMustHaveExactSignatureAndNeverTargetsScanRoot() async throws {
    let fixture = try FixtureHome()
    try fixture.file("Root/CACHEDIR.TAG", contents: "Signature: 8a477f597d28d172789f06886806bc55")
    try fixture.file("Root/valid/CACHEDIR.TAG", contents: "Signature: 8a477f597d28d172789f06886806bc55\n")
    try fixture.file("Root/invalid/CACHEDIR.TAG", contents: "Signature: not-the-standard-value")
    try fixture.markOld("Root")
    try fixture.markOld("Root/valid")
    try fixture.markOld("Root/invalid")

    let root = fixture.url.appendingPathComponent("Root").path
    let adapter = CachedDirectoryTagAdapter(
        fileSystem: FixtureFileSystem(),
        processes: FixedProcessProbe(.inactive)
    )
    let candidates = try await adapter.scan(
        request: ScanRequest(
            roots: [root, fixture.url.appendingPathComponent("Root/valid").path],
            homePath: fixture.url.path,
            deep: true
        )
    )

    #expect(candidates.isEmpty)
}

@Test func projectArtifactsRequireStrongOwnershipProofAndUseToolSpecificProcessState() async throws {
    let fixture = try FixtureHome()
    try fixture.file("Workspace/Weak/package.json")
    try fixture.file("Workspace/Weak/dist/payload.bin")
    try fixture.file("Workspace/Node/package.json")
    try fixture.file("Workspace/Node/package-lock.json")
    try fixture.file("Workspace/Node/node_modules/pkg/index.js")
    try fixture.file("Workspace/Swift/Package.swift")
    try fixture.file("Workspace/Swift/.build/workspace-state.json")
    try fixture.file("Workspace/Swift/.build/products/App")
    for path in [
        "Workspace/Weak/dist",
        "Workspace/Node/node_modules",
        "Workspace/Swift/.build",
    ] {
        try fixture.markOld(path)
    }

    let root = fixture.url.appendingPathComponent("Workspace").path
    let adapter = ProjectArtifactAdapter(
        fileSystem: FixtureFileSystem(),
        processes: SelectiveProcessProbe(activeTerms: ["exe:node"])
    )
    let candidates = try await adapter.scan(request: ScanRequest(
        roots: [root],
        homePath: fixture.url.path,
        deep: true
    ))
    let byPath = Dictionary(uniqueKeysWithValues: candidates.map { ($0.path, $0) })
    let weak = fixture.url.appendingPathComponent("Workspace/Weak/dist").path
    let node = fixture.url.appendingPathComponent("Workspace/Node/node_modules").path
    let swift = fixture.url.appendingPathComponent("Workspace/Swift/.build").path

    #expect(byPath[weak]?.actionKind == .reportOnly)
    #expect(byPath[weak]?.activeState == .unknown)
    #expect(byPath[weak]?.blockReason?.contains("report-only") == true)
    #expect(byPath[node]?.actionKind == .blocked)
    #expect(byPath[node]?.activeState == .active)
    #expect(byPath[swift]?.actionKind == .trash)
    #expect(byPath[swift]?.activeState == .inactive)
    #expect(byPath[swift]?.evidence.contains("SwiftPM") == true)
}

@Test func taggedCachesAreReportOnlyWithoutOwnerAndProbeOnlyTheirOwningTool() async throws {
    let fixture = try FixtureHome()
    let signature = "Signature: 8a477f597d28d172789f06886806bc55\n"
    try fixture.file("Workspace/Unknown/cache-leaf/CACHEDIR.TAG", contents: signature)
    try fixture.file("Workspace/Unknown/cache-leaf/data.bin")
    try fixture.file("Workspace/Python/.pytest_cache/CACHEDIR.TAG", contents: signature)
    try fixture.file("Workspace/Python/.pytest_cache/data.bin")
    try fixture.file("Workspace/Node/.parcel-cache/CACHEDIR.TAG", contents: signature)
    try fixture.file("Workspace/Node/.parcel-cache/data.bin")
    for path in [
        "Workspace/Unknown/cache-leaf",
        "Workspace/Python/.pytest_cache",
        "Workspace/Node/.parcel-cache",
    ] {
        try fixture.markOld(path)
    }

    let root = fixture.url.appendingPathComponent("Workspace").path
    let adapter = CachedDirectoryTagAdapter(
        fileSystem: FixtureFileSystem(),
        processes: SelectiveProcessProbe(activeTerms: ["exe:node"])
    )
    let candidates = try await adapter.scan(request: ScanRequest(
        roots: [root],
        homePath: fixture.url.path,
        deep: true
    ))
    let byPath = Dictionary(uniqueKeysWithValues: candidates.map { ($0.path, $0) })
    let unknown = fixture.url.appendingPathComponent("Workspace/Unknown/cache-leaf").path
    let python = fixture.url.appendingPathComponent("Workspace/Python/.pytest_cache").path
    let node = fixture.url.appendingPathComponent("Workspace/Node/.parcel-cache").path

    #expect(byPath[unknown]?.actionKind == .reportOnly)
    #expect(byPath[unknown]?.activeState == .unknown)
    #expect(byPath[python]?.actionKind == .trash)
    #expect(byPath[python]?.activeState == .inactive)
    #expect(byPath[node]?.actionKind == .blocked)
    #expect(byPath[node]?.activeState == .active)
}

@Test func vscodeExplicitRootEmitsNoSiblingAndParsesRightmostSemanticVersion() async throws {
    let fixture = try FixtureHome()
    try fixture.file(
        ".vscode/extensions/publisher.foo-2fa-1.0.0/package.json",
        contents: #"{"publisher":"publisher","name":"foo-2fa","version":"1.0.0"}"#
    )
    try fixture.file(
        ".vscode/extensions/publisher.foo-2fa-2.0.0/package.json",
        contents: #"{"publisher":"publisher","name":"foo-2fa","version":"2.0.0"}"#
    )
    try fixture.file(
        ".vscode/extensions/publisher.bar-1.0.0/package.json",
        contents: #"{"publisher":"publisher","name":"bar","version":"1.0.0"}"#
    )
    try fixture.file(
        ".vscode/extensions/publisher.bar-2.0.0/package.json",
        contents: #"{"publisher":"publisher","name":"bar","version":"2.0.0"}"#
    )
    try fixture.file(
        ".vscode/extensions/publisher.foo-1.0.0/package.json",
        contents: #"{"publisher":"publisher","name":"foo","version":"1.0.0"}"#
    )

    let exactOldRoot = fixture.url
        .appendingPathComponent(".vscode/extensions/publisher.foo-2fa-1.0.0").path
    let adapter = VSCodeSupersededExtensionAdapter(
        fileSystem: FixtureFileSystem(),
        processes: FixedProcessProbe(.inactive)
    )
    let candidates = try await adapter.scan(request: ScanRequest(
        roots: [exactOldRoot],
        homePath: fixture.url.path,
        deep: true
    ))

    #expect(candidates.count == 1)
    #expect(candidates.first?.path == exactOldRoot)
    #expect(candidates.first?.displayName == "publisher.foo-2fa 1.0.0")
    #expect(candidates.first?.evidence.contains("Exact extension ID publisher.foo-2fa") == true)
    #expect(candidates.first?.actionKind == .reportOnly)
    #expect(candidates.first?.blockReason?.contains("no version-specific uninstall") == true)
}

@Test func hardcoreVersionRetentionKeepsOneReferencedGradleAndNDK() async throws {
    let fixture = try FixtureHome()
    try fixture.file(
        "Projects/App/gradle/wrapper/gradle-wrapper.properties",
        contents: "distributionUrl=https\\://services.gradle.org/distributions/gradle-9.5.0-bin.zip"
    )
    try fixture.file(
        "Projects/App/build.gradle.kts",
        contents: "android { ndkVersion = \"27.0.12077973\" }"
    )
    for version in ["8.14.1", "9.4.1", "9.5.0"] {
        try fixture.file(".gradle/caches/\(version)/metadata.bin")
        try fixture.file(".gradle/daemon/\(version)/registry.bin")
        try fixture.file(".gradle/wrapper/dists/gradle-\(version)-bin/hash/marker.bin")
    }
    try fixture.file(".gradle/caches/9evil/metadata.bin")
    try fixture.file(".gradle/caches/9.5.0 backup/metadata.bin")
    for version in ["25.2.9519653", "26.3.11579264", "27.0.12077973"] {
        try fixture.file("Library/Android/sdk/ndk/\(version)/source.properties")
    }
    try fixture.file("Library/Android/sdk/ndk/27evil/source.properties")

    let request = ScanRequest(
        roots: [fixture.url.path],
        homePath: fixture.url.path,
        deep: true,
        hardcore: true
    )
    let gradle = try await HardcoreGradleVersionAdapter(
        fileSystem: FixtureFileSystem(),
        processes: FixedProcessProbe(.inactive)
    ).scan(request: request)
    let ndk = try await HardcoreNDKVersionAdapter(
        fileSystem: FixtureFileSystem(),
        processes: FixedProcessProbe(.inactive)
    ).scan(request: request)

    #expect(gradle.count == 6)
    #expect(gradle.allSatisfy { $0.actionKind == .trash && !$0.defaultSelected })
    #expect(gradle.allSatisfy { $0.evidence.contains("kept 9.5.0") })
    #expect(!gradle.contains { $0.path.contains("/9.5.0") || $0.path.contains("gradle-9.5.0-") })
    #expect(!gradle.contains { $0.path.contains("9evil") || $0.path.contains(" backup") })
    #expect(ndk.count == 2)
    #expect(ndk.allSatisfy { $0.actionKind == .trash && !$0.defaultSelected })
    #expect(ndk.allSatisfy { $0.evidence.contains("kept 27.0.12077973") })
    #expect(!ndk.contains { $0.path.hasSuffix("/27.0.12077973") })
    #expect(!ndk.contains { $0.path.hasSuffix("/27evil") })

    let conservative = ScanRequest(
        roots: [fixture.url.path],
        homePath: fixture.url.path,
        deep: true
    )
    #expect(try await HardcoreGradleVersionAdapter(
        fileSystem: FixtureFileSystem(),
        processes: FixedProcessProbe(.inactive)
    ).scan(request: conservative).isEmpty)
    #expect(try await HardcoreNDKVersionAdapter(
        fileSystem: FixtureFileSystem(),
        processes: FixedProcessProbe(.inactive)
    ).scan(request: conservative).isEmpty)
}

@Test func hardcoreVersionRetentionBlocksWhileOwningToolsAreActive() async throws {
    let fixture = try FixtureHome()
    try fixture.file(".gradle/caches/9.4.1/metadata.bin")
    try fixture.file(".gradle/caches/9.5.0/metadata.bin")
    try fixture.file("Library/Android/sdk/ndk/26.3.11579264/source.properties")
    try fixture.file("Library/Android/sdk/ndk/27.0.12077973/source.properties")
    let request = ScanRequest(
        roots: [fixture.url.path],
        homePath: fixture.url.path,
        deep: true,
        hardcore: true
    )
    let gradle = try await HardcoreGradleVersionAdapter(
        fileSystem: FixtureFileSystem(),
        processes: FixedProcessProbe(.active)
    ).scan(request: request)
    let ndk = try await HardcoreNDKVersionAdapter(
        fileSystem: FixtureFileSystem(),
        processes: FixedProcessProbe(.active)
    ).scan(request: request)

    #expect(gradle.count == 1)
    #expect(ndk.count == 1)
    #expect((gradle + ndk).allSatisfy {
        $0.actionKind == .blocked && $0.activeState == .active && $0.blockReason != nil
    })
    #expect((gradle + ndk).allSatisfy {
        $0.evidence.contains("2 paths / 2 unique inodes")
    })
}

@Test func hardcoreStorageRetentionFindsOldCodexAndroidAndSimulatorState() async throws {
    let fixture = try FixtureHome()
    try fixture.file(".codex/sessions/2026/07/01/old.jsonl", contents: "old history")
    try fixture.file(".codex/sessions/2026/08/10/recent.jsonl", contents: "recent history")
    try fixture.file(".codex/session-archives/2026-through-07-01/old.jsonl", contents: "old archive")
    try fixture.file(".codex/session-archives/2026-through-08-10/recent.jsonl", contents: "recent archive")
    try fixture.file(".codex.corrupt.20260527-115342/sessions/recovery.jsonl")
    try fixture.file(".codex.corrupt.20260813-115342/sessions/recovery.jsonl")
    try fixture.file(".codex.corrupt.unknown/sessions/recovery.jsonl")
    try fixture.file("Projects/App/build.gradle.kts", contents: "android { compileSdk = 34 }")
    for api in [25, 34, 35] {
        try fixture.file("Library/Android/sdk/platforms/android-\(api)/package.xml")
    }
    try fixture.file("Library/Developer/CoreSimulator/Images/runtime-cache.bin")
    try fixture.file("Library/Developer/CoreSimulator/Caches/dyld/cache.bin")
    try fixture.file(".android/avd/Pixel.avd/snapshots/default_boot/ram.img")
    try fixture.file(".android/avd/Pixel.avd/userdata-qemu.img")

    let now = try #require(
        ISO8601DateFormatter().date(from: "2026-08-14T12:00:00Z")
    )
    let request = ScanRequest(
        roots: [fixture.url.path],
        homePath: fixture.url.path,
        deep: true,
        hardcore: true,
        now: now
    )
    let adapters: [any RuleAdapter] = [
        HardcoreAndroidPlatformAdapter(
            fileSystem: FixtureFileSystem(), processes: FixedProcessProbe(.inactive)
        ),
        HardcoreCodexSessionRetentionAdapter(
            fileSystem: FixtureFileSystem(), processes: FixedProcessProbe(.inactive)
        ),
        HardcoreCodexSessionArchiveRetentionAdapter(
            fileSystem: FixtureFileSystem(), processes: FixedProcessProbe(.inactive)
        ),
        HardcoreCodexCorruptSnapshotAdapter(
            fileSystem: FixtureFileSystem(), processes: FixedProcessProbe(.inactive)
        ),
        HardcoreCoreSimulatorCacheAdapter(
            fileSystem: FixtureFileSystem(), processes: FixedProcessProbe(.inactive)
        ),
        HardcoreAVDSnapshotAdapter(
            fileSystem: FixtureFileSystem(), processes: FixedProcessProbe(.inactive)
        ),
    ]
    let candidates = try await scanAdapters(adapters, request: request)
    let paths = Set(candidates.map(\.path))

    #expect(candidates.count == 7)
    #expect(candidates.allSatisfy { $0.actionKind == .trash && !$0.defaultSelected })
    #expect(paths.contains(fixture.url.appendingPathComponent(".codex/sessions/2026/07/01").path))
    #expect(!paths.contains(fixture.url.appendingPathComponent(".codex/sessions/2026/08/10").path))
    #expect(paths.contains(fixture.url.appendingPathComponent(".codex/session-archives/2026-through-07-01").path))
    #expect(!paths.contains(fixture.url.appendingPathComponent(".codex/session-archives/2026-through-08-10").path))
    #expect(paths.contains(fixture.url.appendingPathComponent(".codex.corrupt.20260527-115342").path))
    #expect(!paths.contains(fixture.url.appendingPathComponent(".codex.corrupt.20260813-115342").path))
    #expect(!paths.contains(fixture.url.appendingPathComponent(".codex.corrupt.unknown").path))
    #expect(paths.contains(fixture.url.appendingPathComponent("Library/Android/sdk/platforms/android-25").path))
    #expect(!paths.contains(fixture.url.appendingPathComponent("Library/Android/sdk/platforms/android-34").path))
    #expect(!paths.contains(fixture.url.appendingPathComponent("Library/Android/sdk/platforms/android-35").path))
    #expect(paths.contains(fixture.url.appendingPathComponent("Library/Developer/CoreSimulator/Images").path))
    #expect(paths.contains(fixture.url.appendingPathComponent("Library/Developer/CoreSimulator/Caches/dyld").path))
    #expect(paths.contains(fixture.url.appendingPathComponent(".android/avd/Pixel.avd/snapshots").path))
    #expect(!paths.contains(fixture.url.appendingPathComponent(".android/avd/Pixel.avd/userdata-qemu.img").path))

    let activeCandidates = try await scanAdapters([
        HardcoreAndroidPlatformAdapter(
            fileSystem: FixtureFileSystem(), processes: FixedProcessProbe(.active)
        ) as any RuleAdapter,
        HardcoreCodexSessionRetentionAdapter(
            fileSystem: FixtureFileSystem(), processes: FixedProcessProbe(.active)
        ) as any RuleAdapter,
        HardcoreCodexSessionArchiveRetentionAdapter(
            fileSystem: FixtureFileSystem(), processes: FixedProcessProbe(.active)
        ) as any RuleAdapter,
        HardcoreCodexCorruptSnapshotAdapter(
            fileSystem: FixtureFileSystem(), processes: FixedProcessProbe(.active)
        ) as any RuleAdapter,
        HardcoreCoreSimulatorCacheAdapter(
            fileSystem: FixtureFileSystem(), processes: FixedProcessProbe(.active)
        ) as any RuleAdapter,
        HardcoreAVDSnapshotAdapter(
            fileSystem: FixtureFileSystem(), processes: FixedProcessProbe(.active)
        ) as any RuleAdapter,
    ], request: request)
    #expect(!activeCandidates.isEmpty)
    #expect(activeCandidates.allSatisfy {
        $0.actionKind == .blocked && $0.activeState == .active && $0.blockReason != nil
    })

    let sdkRoot = fixture.url.appendingPathComponent("Library/Android/sdk").path
    let sdkOnlyReport = await RuleScanner(
        catalog: RuleCatalog(
            fileSystem: FixtureFileSystem(), processes: FixedProcessProbe(.inactive)
        ),
        homePath: fixture.url.path,
        roots: [sdkRoot]
    ).scan(request: ScanRequest(
        roots: [sdkRoot],
        homePath: fixture.url.path,
        deep: true,
        hardcore: true,
        now: now
    ))
    #expect(!sdkOnlyReport.issues.contains {
        $0.message.contains("project-reference scan exceeded")
            || $0.message.contains("project discovery exceeded")
    })
    #expect(sdkOnlyReport.candidates.contains {
        $0.ruleID == "hardcore.android-platforms"
            && $0.path.hasSuffix("/platforms/android-34")
    })
}

@Test func hardcoreBuildArtifactsKeepNewestOnlyInsideProvenGeneratedRoots() async throws {
    let fixture = try FixtureHome()
    try fixture.file(".lldb/module_cache/stale.pcm")
    try fixture.markOld(".lldb/module_cache")
    try fixture.file("Workspace/App/build.gradle.kts")
    try fixture.file("Workspace/App/build/intermediates/marker.bin")
    try fixture.file("Workspace/App/build/outputs/old/Demo.app/Contents/MacOS/Demo")
    try fixture.file("Workspace/App/build/outputs/new/Demo.app/Contents/MacOS/Demo")
    try fixture.file("Workspace/App/build/native/old/libdemo.so")
    try fixture.file("Workspace/App/build/native/new/libdemo.so")
    try fixture.file("Workspace/App/build/objects/old/foo.o")
    try fixture.file("Workspace/App/build/objects/new/foo.o")
    try fixture.file("Workspace/App/build/static/old/libdemo.a")
    try fixture.file("Workspace/App/build/static/new/libdemo.a")
    try fixture.file("Workspace/App/src/libdemo.so")
    for path in [
        "Workspace/App/build/outputs/old/Demo.app",
        "Workspace/App/build/native/old/libdemo.so",
        "Workspace/App/build/objects/old/foo.o",
        "Workspace/App/build/static/old/libdemo.a",
    ] {
        try fixture.markOld(path)
    }

    let root = fixture.url.path
    let request = ScanRequest(
        roots: [root],
        homePath: fixture.url.path,
        deep: true,
        hardcore: true
    )
    let adapter = HardcoreBuildArtifactAdapter(
        fileSystem: FixtureFileSystem(),
        processes: FixedProcessProbe(.inactive)
    )
    let candidates = try await adapter.scan(request: request)
    let paths = Set(candidates.map(\.path))

    #expect(candidates.count == 4)
    #expect(candidates.allSatisfy { $0.actionKind == .trash && !$0.defaultSelected })
    #expect(paths.contains(fixture.url.appendingPathComponent("Workspace/App/build/outputs/old/Demo.app").path))
    #expect(paths.contains(fixture.url.appendingPathComponent("Workspace/App/build/native/old/libdemo.so").path))
    #expect(paths.contains(fixture.url.appendingPathComponent("Workspace/App/build/objects/old/foo.o").path))
    #expect(paths.contains(fixture.url.appendingPathComponent("Workspace/App/build/static/old/libdemo.a").path))
    #expect(!paths.contains(fixture.url.appendingPathComponent("Workspace/App/build/outputs/new/Demo.app").path))
    #expect(!paths.contains(fixture.url.appendingPathComponent("Workspace/App/src/libdemo.so").path))

    let scanner = RuleScanner(
        catalog: RuleCatalog(fileSystem: FixtureFileSystem(), processes: FixedProcessProbe(.inactive)),
        homePath: fixture.url.path,
        roots: [root]
    )
    let report = await scanner.scan(request: request)
    #expect(report.candidates.contains { $0.ruleID == "hardcore.build-artifacts" })
    #expect(report.candidates.first { $0.ruleID == "lldb.module-cache" }?.confidence == .low)
    #expect(report.candidates.filter { $0.ruleID == "hardcore.build-artifacts" }.allSatisfy {
        $0.confidence == .high
    })
    #expect(!report.candidates.contains {
        $0.ruleID == "project.artifacts" && $0.path.hasSuffix("/Workspace/App/build")
    })
}

private func populateFixture(_ fixture: FixtureHome) throws -> [String] {
    try fixture.file(".gradle/caches/build-cache-1/data.bin")
    try fixture.file(".gradle/caches/modules-2/files/lib.jar")
    try fixture.file(".gradle/caches/9.5.0/transforms/output.bin")
    try fixture.file(".gradle/.tmp/stale.bin")
    try fixture.file(".gradle/gradle.properties", contents: "repoPassword=secret")
    try fixture.file(".lldb/module-cache/object.pcm")
    try fixture.file(".lldb/module_cache/object.pcm")
    try fixture.file(".lldbinit", contents: "command script import private.py")
    try fixture.file(".konan/cache/target/cache.bin")
    try fixture.file(".konan/kotlin-native-prebuilt-macos-aarch64-2.1/bin/konanc")

    try fixture.file(".codex/sessions/2026/session.jsonl")
    try fixture.file(".codex/state_5.sqlite")
    try fixture.file(".codex/memories/project.md")
    try fixture.file(".codex/auth.json", contents: "credential")
    try fixture.file(".codex/config.toml")
    try fixture.file(".codex/skills/private/SKILL.md")
    try fixture.file(".codex/attachments/image.png")
    try fixture.file(".codex/worktrees/active/source.swift")
    try fixture.file(".codex/.tmp/marketplace-abandoned/download.tmp")
    try fixture.file(".codex/.tmp/user-note/keep.txt")
    try fixture.file("Library/Caches/Codex/Default/Cache/cache.bin")
    try fixture.file(".cache/codex-runtimes/old-runtime/bin/node")
    try fixture.file(".cache/codex-runtimes/active-runtime/.active")
    try fixture.file(".codex.corrupt.20260811/sessions/recovery.jsonl")

    try fixture.file(".android/cache/repository.xml")
    try fixture.file(".android/avd/Pixel.avd/cache.img")
    try fixture.file(".android/avd/Pixel.avd/userdata-qemu.img")
    try fixture.file(".android/avd/Pixel.avd/snapshots/default_boot/ram.img")
    try fixture.file(".android/avd/Pixel.avd/config.ini")
    try fixture.file(".android/debug.keystore")

    try fixture.file(".colima/default/diffdisk")
    try fixture.file("Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw")
    try fixture.file("Library/Caches/CocoaPods/Pods/Archive.zip")
    try fixture.file(".cocoapods/cache/Pods/Archive.zip")
    try fixture.file(".cocoapods/repos/trunk/Specs/index")
    try fixture.file(".m2/repository/org/example/lib.jar")
    try fixture.file(".m2/repository/org/remote/lib/1.0/_remote.repositories")
    try fixture.file(".m2/repository/org/remote/lib/1.0/lib-1.0.jar")
    try fixture.file(".m2/repository/vn/momo/private-lib/maven-metadata-local.xml")
    try fixture.file(".m2/repository/vn/momo/private-lib/1.0/_remote.repositories")
    try fixture.file(".m2/repository/vn/momo/private-lib/1.0/private-lib-1.0.jar")
    try fixture.file(".m2/settings.xml", contents: "credentials")

    try fixture.file("Library/Developer/Xcode/DerivedData/App-abc/Build/product")
    try fixture.file("Library/Developer/Xcode/Archives/Release.xcarchive/Info.plist")
    try fixture.file(
        ".vscode/extensions/openai.chatgpt-1.0.0-darwin-arm64/package.json",
        contents: #"{"publisher":"openai","name":"chatgpt","version":"1.0.0"}"#
    )
    try fixture.file(
        ".vscode/extensions/openai.chatgpt-2.0.0-darwin-arm64/package.json",
        contents: #"{"publisher":"openai","name":"chatgpt","version":"2.0.0"}"#
    )
    try fixture.file(".vscode/settings.json")

    try fixture.file("Downloads/old-installer.dmg")
    try fixture.file("Downloads/archive.zip")

    try fixture.file("Projects/App/package.json")
    try fixture.file("Projects/App/package-lock.json")
    try fixture.file("Projects/App/node_modules/pkg/index.js")
    try fixture.file("Projects/App/src/main.swift")
    try fixture.file("Projects/App/output/binary")
    try fixture.file(
        "Projects/App/.fixture-cache/CACHEDIR.TAG",
        contents: "Signature: 8a477f597d28d172789f06886806bc55\n"
    )
    try fixture.file("Projects/App/.fixture-cache/data.bin")
    try fixture.file("Projects/App/.invalid-cache/CACHEDIR.TAG", contents: "invalid")
    try fixture.file("Projects/App/.invalid-cache/data.bin")

    return [
        ".gradle/caches/build-cache-1",
        ".gradle/caches/modules-2",
        ".gradle/caches/9.5.0/transforms",
        ".gradle/.tmp/stale.bin",
        ".lldb/module-cache",
        ".lldb/module_cache",
        ".konan/cache",
        ".konan/kotlin-native-prebuilt-macos-aarch64-2.1",
        ".codex/.tmp/marketplace-abandoned",
        "Library/Caches/Codex/Default/Cache",
        ".cache/codex-runtimes/old-runtime",
        ".android/cache",
        ".android/avd/Pixel.avd/cache.img",
        ".m2/repository/org/remote/lib/1.0",
        ".m2/repository/vn/momo/private-lib/1.0",
        "Library/Caches/CocoaPods",
        "Library/Developer/Xcode/DerivedData/App-abc",
        "Downloads/old-installer.dmg",
        "Projects/App/node_modules",
        "Projects/App/.fixture-cache",
    ]
}

private func candidateOrder(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
    if lhs.category != rhs.category { return lhs.category < rhs.category }
    if lhs.path != rhs.path { return lhs.path < rhs.path }
    return lhs.ruleID < rhs.ruleID
}

private func scanAdapters(
    _ adapters: [any RuleAdapter],
    request: ScanRequest
) async throws -> [Candidate] {
    var result: [Candidate] = []
    for adapter in adapters {
        result.append(contentsOf: try await adapter.scan(request: request))
    }
    return result
}
