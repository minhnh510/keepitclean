import Foundation
import KeepItCleanCore

public struct RuleCatalog: Sendable {
    private let fileSystem: any FileSystemReading
    private let processes: any ProcessProbing

    public init(fileSystem: any FileSystemReading, processes: any ProcessProbing) {
        self.fileSystem = fileSystem
        self.processes = processes
    }

    /// `homePath` and `roots` make construction explicit at the composition
    /// boundary. Adapters still consume the values from each `ScanRequest`, so
    /// a catalog can be reused without capturing a stale path.
    public func defaultAdapters(homePath: String, roots: [String]) -> [any RuleAdapter] {
        _ = homePath
        _ = roots

        return [
            HardcoreGradleTransformRetentionAdapter(fileSystem: fileSystem, processes: processes),
            HardcoreGradleVersionAdapter(fileSystem: fileSystem, processes: processes),
            HardcoreNDKVersionAdapter(fileSystem: fileSystem, processes: processes),
            HardcoreAndroidPlatformAdapter(fileSystem: fileSystem, processes: processes),
            HardcoreCodexSessionRetentionAdapter(fileSystem: fileSystem, processes: processes),
            HardcoreCodexSessionArchiveRetentionAdapter(fileSystem: fileSystem, processes: processes),
            HardcoreCodexCorruptSnapshotAdapter(fileSystem: fileSystem, processes: processes),
            HardcoreCoreSimulatorCacheAdapter(fileSystem: fileSystem, processes: processes),
            HardcoreAVDSnapshotAdapter(fileSystem: fileSystem, processes: processes),
            HardcoreBuildArtifactAdapter(fileSystem: fileSystem, processes: processes),
            gradleTransientAdapter(),
            gradleTransformsAdapter(),
            gradleDependencyReportAdapter(),
            lldbCacheAdapter(),
            kotlinNativeCacheAdapter(),
            kotlinNativeToolchainReportAdapter(),
            codexDesktopCacheAdapter(),
            codexRuntimeAdapter(),
            codexTemporaryAdapter(),
            codexProtectedStateAdapter(),
            codexCorruptSnapshotAdapter(),
            legacyMoleCacheAdapter(),
            androidCacheAdapter(),
            androidAVDCacheAdapter(),
            androidAVDReportAdapter(),
            containerStorageReportAdapter(),
            cocoaPodsCacheAdapter(),
            cocoaPodsRepositoryReportAdapter(),
            MavenRemoteArtifactAdapter(fileSystem: fileSystem, processes: processes),
            mavenRepositoryReportAdapter(),
            xcodeDerivedDataAdapter(),
            VSCodeSupersededExtensionAdapter(fileSystem: fileSystem, processes: processes),
            downloadsInstallerAdapter(),
            ProjectArtifactAdapter(fileSystem: fileSystem, processes: processes),
            CachedDirectoryTagAdapter(fileSystem: fileSystem, processes: processes),
        ]
    }

    private func adapter(
        descriptor: RuleDescriptor,
        probe: ProcessProbe? = nil,
        policy: CandidatePolicy,
        discovery: @escaping PathDiscovery
    ) -> DeclarativeRuleAdapter {
        DeclarativeRuleAdapter(
            descriptor: descriptor,
            fileSystem: fileSystem,
            processes: processes,
            processNames: probe.map(probeTerms) ?? [],
            policy: policy,
            discovery: discovery
        )
    }

    private func gradleTransientAdapter() -> DeclarativeRuleAdapter {
        adapter(
            descriptor: RuleDescriptor(
                id: "gradle.transient",
                name: "Gradle transient cache leaves",
                category: "Gradle",
                summary: "Versioned daemon, worker, notification, and build-cache leaves.",
                explicitNonTargets: [
                    "~/.gradle/gradle.properties and credentials",
                    "dependency cache modules-2",
                    "wrapper distributions",
                    "the ~/.gradle root",
                ]
            ),
            probe: KnownProcessProbes.gradle,
            policy: CandidatePolicy(
                actionKind: .trash,
                risk: .low,
                rebuildCost: .low,
                minimumAge: 7 * 86_400
            ),
            discovery: RuleDiscovery.combine([
                RuleDiscovery.homeChildren(parent: ".gradle/caches", matching: .prefix("build-cache-")),
                RuleDiscovery.homeChildren(parent: ".gradle/daemon"),
                RuleDiscovery.homeChildren(parent: ".gradle/notifications"),
                RuleDiscovery.homeChildren(parent: ".gradle/workers"),
                RuleDiscovery.homeChildren(parent: ".gradle/.tmp"),
            ])
        )
    }

    private func gradleTransformsAdapter() -> DeclarativeRuleAdapter {
        let discovery: PathDiscovery = { request, fileSystem in
            let caches = join(request.homePath, ".gradle/caches")
            guard fileSystem.fileExists(at: caches) else { return [] }
            return try fileSystem.immediateChildren(at: caches).flatMap { versionDirectory in
                let identity = try fileSystem.identity(at: versionDirectory)
                guard identity.fileKind == .directory else { return [String]() }
                return try fileSystem.immediateChildren(at: versionDirectory).filter {
                    let name = basename($0)
                    return name == "transforms" || name.hasPrefix("transforms-")
                }
            }
        }
        return adapter(
            descriptor: RuleDescriptor(
                id: "gradle.transforms",
                name: "Gradle transformed artifacts",
                category: "Gradle",
                summary: "Version-scoped transformed dependency outputs that Gradle can rebuild.",
                explicitNonTargets: [
                    "modules-2 downloaded dependencies",
                    "wrapper distributions",
                    "Gradle properties and credentials",
                    "active Gradle state",
                ]
            ),
            probe: KnownProcessProbes.gradle,
            policy: CandidatePolicy(
                actionKind: .reportOnly,
                risk: .high,
                rebuildCost: .high,
                reportOnlyReason: "Use hardcore seven-day transform retention instead of moving the entire transforms root.",
                deepOnly: true
            ),
            discovery: discovery
        )
    }

    private func gradleDependencyReportAdapter() -> DeclarativeRuleAdapter {
        adapter(
            descriptor: RuleDescriptor(
                id: "gradle.dependencies-report",
                name: "Gradle dependency storage",
                category: "Gradle",
                summary: "Large downloaded dependency and wrapper stores that may be expensive to rebuild.",
                explicitNonTargets: ["manual deletion", "credentials", "active dependency downloads"]
            ),
            probe: KnownProcessProbes.gradle,
            policy: CandidatePolicy(
                actionKind: .reportOnly,
                risk: .high,
                rebuildCost: .high,
                reportOnlyReason: "Reference completeness is unknown; dependency stores are report-only.",
                deepOnly: true
            ),
            discovery: RuleDiscovery.exactHome([
                ".gradle/caches/modules-2",
                ".gradle/wrapper/dists",
            ])
        )
    }

    private func lldbCacheAdapter() -> DeclarativeRuleAdapter {
        adapter(
            descriptor: RuleDescriptor(
                id: "lldb.module-cache",
                name: "LLDB module and index caches",
                category: "LLDB",
                summary: "Exact LLDB module/index cache leaves only.",
                explicitNonTargets: [
                    "~/.lldbinit",
                    "LLDB command history",
                    "scripts, plugins, source maps, and user configuration",
                    "the ~/.lldb root",
                ]
            ),
            probe: KnownProcessProbes.lldb,
            policy: CandidatePolicy(
                actionKind: .trash,
                risk: .low,
                rebuildCost: .medium,
                minimumAge: 7 * 86_400
            ),
            discovery: RuleDiscovery.exactHome([
                ".lldb/module-cache",
                ".lldb/module_cache",
                ".lldb/ModuleCache",
                ".lldb/ModuleCache.noindex",
                ".lldb/index-cache",
                "Library/Caches/com.apple.dt.lldb",
            ])
        )
    }

    private func kotlinNativeCacheAdapter() -> DeclarativeRuleAdapter {
        adapter(
            descriptor: RuleDescriptor(
                id: "kotlin-native.cache",
                name: "Kotlin/Native compilation cache",
                category: "Kotlin Native",
                summary: "Exact ~/.konan/cache leaf; compiler distributions and dependencies are excluded.",
                explicitNonTargets: [
                    "kotlin-native-prebuilt toolchains",
                    "downloaded native dependencies",
                    "the ~/.konan root",
                ]
            ),
            probe: KnownProcessProbes.kotlinNative,
            policy: CandidatePolicy(
                actionKind: .trash,
                risk: .review,
                rebuildCost: .medium,
                minimumAge: 14 * 86_400,
                deepOnly: true
            ),
            discovery: RuleDiscovery.exactHome([".konan/cache"])
        )
    }

    private func kotlinNativeToolchainReportAdapter() -> DeclarativeRuleAdapter {
        adapter(
            descriptor: RuleDescriptor(
                id: "kotlin-native.toolchains-report",
                name: "Kotlin/Native downloaded toolchains",
                category: "Kotlin Native",
                summary: "Downloaded compiler distributions and dependency storage.",
                explicitNonTargets: ["automatic deletion without project and toolchain reference proof"]
            ),
            probe: KnownProcessProbes.kotlinNative,
            policy: CandidatePolicy(
                actionKind: .reportOnly,
                risk: .high,
                rebuildCost: .high,
                reportOnlyReason: "Toolchain reference state is unknown; review only.",
                deepOnly: true
            ),
            discovery: RuleDiscovery.combine([
                RuleDiscovery.homeChildren(parent: ".konan", matching: .prefix("kotlin-native-prebuilt-")),
                RuleDiscovery.exactHome([".konan/dependencies"]),
            ])
        )
    }

    private func codexDesktopCacheAdapter() -> DeclarativeRuleAdapter {
        adapter(
            descriptor: RuleDescriptor(
                id: "codex.desktop-cache",
                name: "Codex Desktop Chromium caches",
                category: "Codex",
                summary: "Chromium Cache and Code Cache leaves under Codex Desktop's cache root.",
                explicitNonTargets: codexDurableNonTargets
            ),
            probe: KnownProcessProbes.codex,
            policy: CandidatePolicy(
                actionKind: .trash,
                risk: .low,
                rebuildCost: .low,
                minimumAge: 7 * 86_400
            ),
            discovery: RuleDiscovery.exactHome([
                "Library/Caches/Codex/Default/Cache",
                "Library/Caches/Codex/Default/Code Cache",
                "Library/Caches/Codex/Default/Partitions/codex-browser-app/Cache",
                "Library/Caches/Codex/Default/Partitions/codex-browser-app/Code Cache",
                "Library/Caches/Codex/codex-browser-app/Cache",
                "Library/Caches/Codex/codex-browser-app/Code Cache",
            ])
        )
    }

    private func codexRuntimeAdapter() -> DeclarativeRuleAdapter {
        let discovery: PathDiscovery = { request, fileSystem in
            let root = join(request.homePath, ".cache/codex-runtimes")
            guard fileSystem.fileExists(at: root) else { return [] }
            return try fileSystem.immediateChildren(at: root).filter { runtime in
                !fileSystem.fileExists(at: join(runtime, ".active"))
            }
        }
        return adapter(
            descriptor: RuleDescriptor(
                id: "codex.stale-runtimes",
                name: "Inactive Codex runtimes",
                category: "Codex",
                summary: "Runtime generations without an active marker and older than 30 days.",
                explicitNonTargets: codexDurableNonTargets + ["runtimes carrying an .active marker"]
            ),
            probe: KnownProcessProbes.codex,
            policy: CandidatePolicy(
                actionKind: .trash,
                risk: .review,
                rebuildCost: .high,
                minimumAge: 30 * 86_400
            ),
            discovery: discovery
        )
    }

    private func codexTemporaryAdapter() -> DeclarativeRuleAdapter {
        let matcher = NameMatcher.prefix("marketplace-")
        return adapter(
            descriptor: RuleDescriptor(
                id: "codex.abandoned-staging",
                name: "Codex abandoned staging",
                category: "Codex",
                summary: "Exact marketplace staging children under ~/.codex/.tmp.",
                explicitNonTargets: codexDurableNonTargets + ["unrecognized ~/.codex/.tmp entries"]
            ),
            probe: KnownProcessProbes.codex,
            policy: CandidatePolicy(
                actionKind: .trash,
                risk: .review,
                rebuildCost: .low,
                minimumAge: 7 * 86_400,
                deepOnly: true
            ),
            discovery: RuleDiscovery.homeChildren(parent: ".codex/.tmp", matching: matcher)
        )
    }

    private func codexProtectedStateAdapter() -> DeclarativeRuleAdapter {
        let sqliteDiscovery = RuleDiscovery.homeChildren(
            parent: ".codex",
            matching: .fileExtensions(["sqlite", "sqlite3", "db"])
        )
        return adapter(
            descriptor: RuleDescriptor(
                id: "codex.protected-state",
                name: "Protected Codex state",
                category: "Codex protected state",
                summary: "Durable Codex sessions, databases, memories, credentials, configuration, skills, attachments, and worktrees.",
                explicitNonTargets: codexDurableNonTargets
            ),
            probe: KnownProcessProbes.codex,
            policy: CandidatePolicy(
                actionKind: .reportOnly,
                risk: .high,
                rebuildCost: .notApplicable,
                reportOnlyReason: "Durable Codex state is protected and never a cleanup target."
            ),
            discovery: RuleDiscovery.combine([
                RuleDiscovery.exactHome([
                    ".codex/sessions",
                    ".codex/memories",
                    ".codex/memory",
                    ".codex/credentials",
                    ".codex/auth.json",
                    ".codex/credentials.json",
                    ".codex/config.toml",
                    ".codex/config.json",
                    ".codex/skills",
                    ".codex/attachments",
                    ".codex/worktrees",
                ]),
                sqliteDiscovery,
            ])
        )
    }

    private func codexCorruptSnapshotAdapter() -> DeclarativeRuleAdapter {
        adapter(
            descriptor: RuleDescriptor(
                id: "codex.corrupt-snapshots",
                name: "Codex corrupt snapshots",
                category: "Codex protected state",
                summary: "Top-level ~/.codex.corrupt.* snapshots are surfaced for manual recovery review.",
                explicitNonTargets: ["automatic deletion", "snapshots without verified replacement state"]
            ),
            probe: KnownProcessProbes.codex,
            policy: CandidatePolicy(
                actionKind: .reportOnly,
                risk: .high,
                rebuildCost: .notApplicable,
                reportOnlyReason: "A corrupt snapshot may be the only recoverable copy; report-only."
            ),
            discovery: RuleDiscovery.homeTopLevel(matching: .prefix(".codex.corrupt."))
        )
    }

    private func legacyMoleCacheAdapter() -> DeclarativeRuleAdapter {
        adapter(
            descriptor: RuleDescriptor(
                id: "mole.legacy-cache",
                name: "Legacy Mole scan cache",
                category: "Legacy cleaner cache",
                summary: "Exact ~/.cache/mole cache generated by Mole; never a blanket ~/.cache rule.",
                explicitNonTargets: [
                    "the ~/.cache root",
                    "active or recently modified Mole state",
                    "all sibling model, runtime, and application caches",
                ]
            ),
            probe: ProcessProbe(id: "mole", executableNames: ["mo", "mole"]),
            policy: CandidatePolicy(
                actionKind: .trash,
                risk: .review,
                rebuildCost: .low,
                minimumAge: 7 * 86_400,
                deepOnly: true
            ),
            discovery: RuleDiscovery.exactHome([".cache/mole"])
        )
    }

    private func androidCacheAdapter() -> DeclarativeRuleAdapter {
        adapter(
            descriptor: RuleDescriptor(
                id: "android.cache",
                name: "Android SDK/build caches",
                category: "Android",
                summary: "Exact ~/.android/cache and ~/.android/build-cache leaves.",
                explicitNonTargets: androidDurableNonTargets
            ),
            probe: KnownProcessProbes.android,
            policy: CandidatePolicy(
                actionKind: .trash,
                risk: .low,
                rebuildCost: .medium,
                minimumAge: 7 * 86_400
            ),
            discovery: RuleDiscovery.exactHome([".android/cache", ".android/build-cache"])
        )
    }

    private func androidAVDCacheAdapter() -> DeclarativeRuleAdapter {
        let discovery: PathDiscovery = { request, fileSystem in
            let avdRoot = join(request.homePath, ".android/avd")
            guard fileSystem.fileExists(at: avdRoot) else { return [] }
            let avds = try fileSystem.immediateChildren(at: avdRoot).filter {
                basename($0).hasSuffix(".avd")
            }
            let cacheNames = ["cache.img", "cache.img.qcow2"]
            return avds.flatMap { avd in
                cacheNames.map { join(avd, $0) }.filter(fileSystem.fileExists)
            }
        }
        return adapter(
            descriptor: RuleDescriptor(
                id: "android.avd-cache",
                name: "Android AVD cache images",
                category: "Android",
                summary: "Only cache.img and cache.img.qcow2 inside exact .avd directories.",
                explicitNonTargets: androidDurableNonTargets
            ),
            probe: KnownProcessProbes.android,
            policy: CandidatePolicy(
                actionKind: .trash,
                risk: .review,
                rebuildCost: .low,
                minimumAge: 7 * 86_400
            ),
            discovery: discovery
        )
    }

    private func androidAVDReportAdapter() -> DeclarativeRuleAdapter {
        adapter(
            descriptor: RuleDescriptor(
                id: "android.avd-report",
                name: "Android virtual devices",
                category: "Android AVDs",
                summary: "Configured AVD directories; deletion is available only through avdmanager native actions.",
                explicitNonTargets: androidDurableNonTargets + ["direct filesystem deletion of an AVD"]
            ),
            probe: KnownProcessProbes.android,
            policy: CandidatePolicy(
                actionKind: .native,
                risk: .high,
                rebuildCost: .notApplicable
            ),
            discovery: RuleDiscovery.homeChildren(parent: ".android/avd", matching: .suffix(".avd"))
        )
    }

    private func containerStorageReportAdapter() -> DeclarativeRuleAdapter {
        adapter(
            descriptor: RuleDescriptor(
                id: "containers.managed-storage",
                name: "Colima and Docker managed storage",
                category: "Containers",
                summary: "Daemon-managed roots surfaced for native Docker/Colima inspection and actions.",
                explicitNonTargets: [
                    "direct deletion of VM disks",
                    "named Docker volumes",
                    "running container state",
                    "the ~/.colima or Docker data root as a trash target",
                ]
            ),
            probe: KnownProcessProbes.colimaDocker,
            policy: CandidatePolicy(
                actionKind: .native,
                risk: .high,
                rebuildCost: .notApplicable
            ),
            discovery: RuleDiscovery.exactHome([
                ".colima",
                ".docker/buildx",
                "Library/Containers/com.docker.docker/Data",
            ])
        )
    }

    private func cocoaPodsCacheAdapter() -> DeclarativeRuleAdapter {
        adapter(
            descriptor: RuleDescriptor(
                id: "cocoapods.cache",
                name: "CocoaPods download cache",
                category: "CocoaPods",
                summary: "Exact CocoaPods download cache, managed through `pod cache` native actions.",
                explicitNonTargets: ["project Pods directories", "Podfile.lock", "CocoaPods configuration and auth"]
            ),
            probe: KnownProcessProbes.cocoaPods,
            policy: CandidatePolicy(
                actionKind: .native,
                risk: .review,
                rebuildCost: .high
            ),
            discovery: RuleDiscovery.exactHome([
                "Library/Caches/CocoaPods",
                ".cocoapods/cache/Pods",
            ])
        )
    }

    private func cocoaPodsRepositoryReportAdapter() -> DeclarativeRuleAdapter {
        adapter(
            descriptor: RuleDescriptor(
                id: "cocoapods.repos-report",
                name: "CocoaPods repository indexes",
                category: "CocoaPods",
                summary: "Local specs/CDN repository state under ~/.cocoapods/repos.",
                explicitNonTargets: ["direct filesystem deletion", "CocoaPods credentials and configuration"]
            ),
            probe: KnownProcessProbes.cocoaPods,
            policy: CandidatePolicy(
                actionKind: .reportOnly,
                risk: .high,
                rebuildCost: .high,
                reportOnlyReason: "Repository ownership and rebuild source require CocoaPods; report-only.",
                deepOnly: true
            ),
            discovery: RuleDiscovery.exactHome([".cocoapods/repos"])
        )
    }

    private func mavenRepositoryReportAdapter() -> DeclarativeRuleAdapter {
        adapter(
            descriptor: RuleDescriptor(
                id: "maven.repository-report",
                name: "Maven local repository",
                category: "Maven",
                summary: "Downloaded Maven artifacts and wrapper distributions.",
                explicitNonTargets: ["~/.m2/settings.xml", "credentials", "automatic deletion without reference proof"]
            ),
            probe: KnownProcessProbes.maven,
            policy: CandidatePolicy(
                actionKind: .reportOnly,
                risk: .high,
                rebuildCost: .high,
                reportOnlyReason: "Dependency reference completeness is unknown; report-only.",
                deepOnly: true
            ),
            discovery: RuleDiscovery.exactHome([".m2/repository", ".m2/wrapper/dists"])
        )
    }

    private func xcodeDerivedDataAdapter() -> DeclarativeRuleAdapter {
        adapter(
            descriptor: RuleDescriptor(
                id: "xcode.derived-data",
                name: "Xcode DerivedData projects",
                category: "Xcode",
                summary: "Individual direct children of Xcode DerivedData.",
                explicitNonTargets: [
                    "Xcode Archives",
                    "DeviceSupport and simulator runtimes",
                    "UserData, signing assets, and project sources",
                    "the entire Developer directory",
                ]
            ),
            probe: KnownProcessProbes.xcode,
            policy: CandidatePolicy(
                actionKind: .trash,
                risk: .low,
                rebuildCost: .medium,
                minimumAge: 7 * 86_400,
                deepOnly: true
            ),
            discovery: RuleDiscovery.homeChildren(parent: "Library/Developer/Xcode/DerivedData")
        )
    }

    private func vscodeExtensionAdapter() -> DeclarativeRuleAdapter {
        adapter(
            descriptor: RuleDescriptor(
                id: "vscode.extensions",
                name: "VS Code extensions",
                category: "VS Code",
                summary: "Exact installed extension directories, actionable only through the VS Code CLI.",
                explicitNonTargets: [
                    "direct filesystem deletion of extensions",
                    "settings, keybindings, snippets, profiles, and extension state",
                    "the ~/.vscode root",
                ]
            ),
            probe: KnownProcessProbes.visualStudioCode,
            policy: CandidatePolicy(
                actionKind: .native,
                risk: .high,
                rebuildCost: .notApplicable
            ),
            discovery: RuleDiscovery.homeChildren(parent: ".vscode/extensions", matching: .any)
        )
    }

    private func downloadsInstallerAdapter() -> DeclarativeRuleAdapter {
        adapter(
            descriptor: RuleDescriptor(
                id: "downloads.installers",
                name: "Old installer files",
                category: "Installers",
                summary: "Direct installer files in Downloads older than 30 days.",
                explicitNonTargets: [
                    "archives without installer-specific extensions",
                    "subdirectories and documents",
                    "recent downloads",
                ]
            ),
            policy: CandidatePolicy(
                actionKind: .trash,
                risk: .review,
                rebuildCost: .notApplicable,
                minimumAge: 30 * 86_400
            ),
            discovery: RuleDiscovery.homeChildren(
                parent: "Downloads",
                matching: .fileExtensions(["dmg", "iso", "mpkg", "pkg", "xip"])
            )
        )
    }

    private var codexDurableNonTargets: [String] {
        [
            "Codex sessions and local thread indexes",
            "state/log SQLite databases and WAL companions",
            "memories",
            "credentials and auth tokens",
            "configuration",
            "skills and plugins",
            "attachments",
            "worktrees and their source/ignored files",
        ]
    }

    private var androidDurableNonTargets: [String] {
        [
            "AVD userdata and SD card images",
            "AVD snapshots and config.ini",
            "debug.keystore and adb keys",
            "SDK licenses, installed platforms, build-tools, and system images",
        ]
    }

    private func probeTerms(_ probe: ProcessProbe) -> [String] {
        (probe.executableNames.map { "exe:\($0)" }
            + probe.argumentFragments.map { "arg:\($0)" })
            .sorted()
    }
}
