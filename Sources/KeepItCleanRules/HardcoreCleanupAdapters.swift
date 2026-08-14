import Darwin
import Foundation
import KeepItCleanCore

public struct HardcoreGradleTransformRetentionAdapter: RuleAdapter, Sendable {
    public static let retentionDays = 7

    public let descriptor = RuleDescriptor(
        id: "hardcore.gradle-transforms-7d",
        name: "Gradle transform seven-day retention",
        category: "Hardcore / Gradle transforms",
        summary: "Keep the seven most recent days of Gradle transforms and move older entries to Trash.",
        explicitNonTargets: [
            "transform entries modified within the last seven days",
            "modules-2, build cache, wrapper distributions, properties, and credentials",
            "the transforms root or any Gradle version root",
            "any transform while Gradle process state is active or unknown",
        ]
    )

    private let fileSystem: any FileSystemReading
    private let processes: any ProcessProbing

    public init(fileSystem: any FileSystemReading, processes: any ProcessProbing) {
        self.fileSystem = fileSystem
        self.processes = processes
    }

    public func scan(request: ScanRequest) async throws -> [Candidate] {
        guard request.isHardcore, request.deep else { return [] }
        let caches = join(request.homePath, ".gradle/caches")
        guard fileSystem.fileExists(at: caches) else { return [] }

        let cutoff = request.now.addingTimeInterval(
            -Double(Self.retentionDays) * 86_400
        )
        let activeState = processes.state(matching: [
            "exe:gradle", "exe:gradlew", "arg:org.gradle.launcher.daemon", "arg:gradledaemon",
        ])
        var candidates: [Candidate] = []

        for versionDirectory in try fileSystem.immediateChildren(at: caches).sorted() {
            guard ParsedToolVersion(basename(versionDirectory)) != nil,
                  (try? fileSystem.identity(at: versionDirectory).fileKind) == .directory
            else { continue }

            for transformsRoot in try fileSystem.immediateChildren(at: versionDirectory).sorted() {
                let rootName = basename(transformsRoot)
                guard rootName == "transforms" || rootName.hasPrefix("transforms-"),
                      (try? fileSystem.identity(at: transformsRoot).fileKind) == .directory
                else { continue }

                for entry in try fileSystem.immediateChildren(at: transformsRoot).sorted() {
                    guard isInScope(entry, roots: request.roots) else { continue }
                    let identity = try fileSystem.identity(at: entry)
                    guard identity.fileKind == .directory,
                          identity.modifiedAt < cutoff
                    else { continue }
                    var candidate = try makeHardcoreCandidate(
                        descriptor: descriptor,
                        path: entry,
                        displayName: "Gradle \(basename(versionDirectory)) transform / \(basename(entry))",
                        evidence: "transform entry older than the seven-day retention cutoff; recent siblings and the transforms root are retained",
                        risk: .low,
                        rebuildCost: .medium,
                        activeState: activeState,
                        request: request,
                        fileSystem: fileSystem
                    )
                    if activeState != .inactive {
                        candidate.blockReason = activeState == .active
                            ? "Gradle is active. Stop its daemons with your project-approved Gradle command, then rescan."
                            : "Gradle process state is unknown. Prove it inactive, then rescan."
                    }
                    candidates.append(candidate)
                }
            }
        }
        return candidates.sorted(by: candidatePathOrder)
    }
}

public struct HardcoreGradleVersionAdapter: RuleAdapter, Sendable {
    public let descriptor = RuleDescriptor(
        id: "hardcore.gradle-versions",
        name: "Hardcore Gradle version retention",
        category: "Hardcore / Gradle",
        summary: "Keep one referenced Gradle version and offer older version-scoped stores for Trash review.",
        explicitNonTargets: [
            "the retained Gradle version",
            "modules-2 and other unversioned dependency storage",
            "Gradle properties, credentials, and the ~/.gradle root",
            "any version while Gradle process state is active or unknown",
        ]
    )

    private let fileSystem: any FileSystemReading
    private let processes: any ProcessProbing

    public init(fileSystem: any FileSystemReading, processes: any ProcessProbing) {
        self.fileSystem = fileSystem
        self.processes = processes
    }

    public func scan(request: ScanRequest) async throws -> [Candidate] {
        guard request.isHardcore, request.deep else { return [] }
        let installed = try gradleLocations(homePath: request.homePath)
            .filter { isInScope($0.path, roots: request.roots) }
        guard !installed.isEmpty else { return [] }

        let references = try ProjectVersionReferenceScanner(fileSystem: fileSystem)
            .scan(roots: request.roots).gradle
        let installedVersions = Set(installed.map(\.version))
        let referencedInstalled = installedVersions.intersection(references)
        guard let keepVersion = highestVersion(
            in: referencedInstalled.isEmpty ? installedVersions : referencedInstalled
        ) else { return [] }

        let activeState = processes.state(matching: [
            "exe:gradle", "exe:gradlew", "arg:org.gradle.launcher.daemon", "arg:gradledaemon",
        ])
        let referenceEvidence = references.isEmpty
            ? "no wrapper reference found; kept highest installed version \(keepVersion)"
            : "wrapper references \(versionList(references)); kept \(keepVersion)"

        return try installed
            .filter { $0.version != keepVersion }
            .map { location in
                try makeHardcoreCandidate(
                    descriptor: descriptor,
                    path: location.path,
                    displayName: "Gradle \(location.version) / \(location.store)",
                    evidence: "\(referenceEvidence); older version-scoped \(location.store); retained version is never targeted",
                    risk: .high,
                    rebuildCost: .high,
                    activeState: activeState,
                    request: request,
                    fileSystem: fileSystem
                )
            }
            .sorted(by: candidatePathOrder)
    }

    private func gradleLocations(
        homePath: String
    ) throws -> [(path: String, version: String, store: String)] {
        var result: [(String, String, String)] = []
        for (relativeParent, store) in [
            (".gradle/caches", "caches"),
            (".gradle/daemon", "daemon"),
        ] {
            let parent = join(homePath, relativeParent)
            guard fileSystem.fileExists(at: parent) else { continue }
            for child in try fileSystem.immediateChildren(at: parent) {
                let raw = basename(child)
                guard ParsedToolVersion(raw) != nil,
                      (try? fileSystem.identity(at: child).fileKind) == .directory
                else { continue }
                result.append((child, raw, store))
            }
        }

        let distributions = join(homePath, ".gradle/wrapper/dists")
        if fileSystem.fileExists(at: distributions) {
            for child in try fileSystem.immediateChildren(at: distributions) {
                let name = basename(child)
                guard let version = gradleDistributionVersion(name),
                      (try? fileSystem.identity(at: child).fileKind) == .directory
                else { continue }
                result.append((child, version, "wrapper distribution"))
            }
        }
        return result
    }
}

public struct HardcoreNDKVersionAdapter: RuleAdapter, Sendable {
    public let descriptor = RuleDescriptor(
        id: "hardcore.ndk-versions",
        name: "Hardcore Android NDK retention",
        category: "Hardcore / Android",
        summary: "Keep one project-referenced NDK and offer older side-by-side NDK packages for Trash review.",
        explicitNonTargets: [
            "the retained NDK version",
            "Android SDK platforms, build-tools, emulator, AVD data, keys, and licenses",
            "NDK directories outside the standard user Android SDK",
            "any NDK while Gradle, Android Studio, CMake, Ninja, or ndk-build is active or unknown",
        ]
    )

    private let fileSystem: any FileSystemReading
    private let processes: any ProcessProbing

    public init(fileSystem: any FileSystemReading, processes: any ProcessProbing) {
        self.fileSystem = fileSystem
        self.processes = processes
    }

    public func scan(request: ScanRequest) async throws -> [Candidate] {
        guard request.isHardcore, request.deep else { return [] }
        let ndkRoot = join(request.homePath, "Library/Android/sdk/ndk")
        guard fileSystem.fileExists(at: ndkRoot), isInScope(ndkRoot, roots: request.roots) else {
            return []
        }
        let installed = try fileSystem.immediateChildren(at: ndkRoot).compactMap { child -> String? in
            let name = basename(child)
            guard ParsedToolVersion(name) != nil,
                  (try? fileSystem.identity(at: child).fileKind) == .directory
            else { return nil }
            return name
        }
        guard !installed.isEmpty else { return [] }

        let references = try ProjectVersionReferenceScanner(fileSystem: fileSystem)
            .scan(roots: request.roots).ndk
        let installedVersions = Set(installed)
        let referencedInstalled = installedVersions.intersection(references)
        guard let keepVersion = highestVersion(
            in: referencedInstalled.isEmpty ? installedVersions : referencedInstalled
        ) else { return [] }

        let activeState = processes.state(matching: [
            "exe:gradle", "exe:gradlew", "exe:ndk-build", "exe:cmake", "exe:ninja",
            "arg:org.gradle.launcher.daemon", "arg:/android studio.app/",
        ])
        let referenceEvidence = references.isEmpty
            ? "no ndkVersion reference found; kept highest installed version \(keepVersion)"
            : "project ndkVersion references \(versionList(references)); kept \(keepVersion)"

        return try installed
            .filter { $0 != keepVersion }
            .map { version in
                try makeHardcoreCandidate(
                    descriptor: descriptor,
                    path: join(ndkRoot, version),
                    displayName: "Android NDK \(version)",
                    evidence: "\(referenceEvidence); old side-by-side NDK; retained version is never targeted",
                    risk: .high,
                    rebuildCost: .high,
                    activeState: activeState,
                    request: request,
                    fileSystem: fileSystem
                )
            }
            .sorted(by: candidatePathOrder)
    }
}

public struct HardcoreAndroidPlatformAdapter: RuleAdapter, Sendable {
    public let descriptor = RuleDescriptor(
        id: "hardcore.android-platforms",
        name: "Hardcore Android SDK platform retention",
        category: "Hardcore / Android",
        summary: "Keep every project-referenced compile SDK plus the newest installed platform.",
        explicitNonTargets: [
            "project-referenced compile SDK platforms",
            "the newest installed Android SDK platform",
            "build-tools, system images, emulator, AVD data, keys, licenses, and SDK roots",
            "any platform while Gradle, Android Studio, or sdkmanager is active or unknown",
        ]
    )

    private let fileSystem: any FileSystemReading
    private let processes: any ProcessProbing

    public init(fileSystem: any FileSystemReading, processes: any ProcessProbing) {
        self.fileSystem = fileSystem
        self.processes = processes
    }

    public func scan(request: ScanRequest) async throws -> [Candidate] {
        guard request.isHardcore, request.deep else { return [] }
        let platformRoot = join(request.homePath, "Library/Android/sdk/platforms")
        guard fileSystem.fileExists(at: platformRoot),
              isInScope(platformRoot, roots: request.roots)
        else { return [] }

        let installed = try fileSystem.immediateChildren(at: platformRoot).compactMap {
            child -> Int? in
            guard let api = androidAPI(basename(child)),
                  (try? fileSystem.identity(at: child).fileKind) == .directory
            else { return nil }
            return api
        }
        guard let newest = installed.max() else { return [] }

        let referenced = try ProjectVersionReferenceScanner(fileSystem: fileSystem)
            .scan(roots: request.roots).androidAPIs
        let retained = referenced.intersection(installed).union([newest])
        let activeState = processes.state(matching: [
            "exe:gradle", "exe:gradlew", "exe:sdkmanager",
            "arg:org.gradle.launcher.daemon", "arg:/android studio.app/",
        ])
        let retainedText = retained.sorted().map(String.init).joined(separator: ", ")

        return try installed
            .filter { !retained.contains($0) }
            .map { api in
                try makeHardcoreCandidate(
                    descriptor: descriptor,
                    path: join(platformRoot, "android-\(api)"),
                    displayName: "Android SDK platform \(api)",
                    evidence: "project compileSdk references were scanned; retained API \(retainedText); platform is redownloadable with sdkmanager",
                    risk: .high,
                    rebuildCost: .high,
                    activeState: activeState,
                    request: request,
                    fileSystem: fileSystem
                )
            }
            .sorted(by: candidatePathOrder)
    }
}

public struct HardcoreCodexSessionRetentionAdapter: RuleAdapter, Sendable {
    public let descriptor = RuleDescriptor(
        id: "hardcore.codex-session-days",
        name: "Hardcore Codex session retention",
        category: "Hardcore / Codex history",
        summary: "Keep the latest seven calendar days and offer older day buckets for explicit Trash review.",
        explicitNonTargets: [
            "the latest seven calendar days",
            "all Codex sessions while Codex is active or process state is unknown",
            "memories, SQLite, credentials, config, skills, attachments, and worktrees",
            "automatic selection or permanent deletion",
        ]
    )

    private let fileSystem: any FileSystemReading
    private let processes: any ProcessProbing

    public init(fileSystem: any FileSystemReading, processes: any ProcessProbing) {
        self.fileSystem = fileSystem
        self.processes = processes
    }

    public func scan(request: ScanRequest) async throws -> [Candidate] {
        guard request.isHardcore, request.deep else { return [] }
        let sessionsRoot = join(request.homePath, ".codex/sessions")
        guard fileSystem.fileExists(at: sessionsRoot),
              isInScope(sessionsRoot, roots: request.roots)
        else { return [] }

        let cutoff = codexSessionCutoff(now: request.now)
        let activeState = processes.state(matching: [
            "exe:codex", "arg:/codex.app/", "arg:/library/application support/codex",
            "arg:features.code_mode_host=true app-server",
        ])
        var days: [(path: String, date: Date)] = []
        for year in try fileSystem.immediateChildren(at: sessionsRoot) {
            guard isNumericDirectory(year, digits: 4, fileSystem: fileSystem) else { continue }
            for month in try fileSystem.immediateChildren(at: year) {
                guard isNumericDirectory(month, digits: 2, fileSystem: fileSystem) else { continue }
                for day in try fileSystem.immediateChildren(at: month) {
                    guard isNumericDirectory(day, digits: 2, fileSystem: fileSystem),
                          let date = sessionDate(year: basename(year), month: basename(month), day: basename(day)),
                          date < cutoff,
                          !(try fileSystem.immediateChildren(at: day)).isEmpty
                    else { continue }
                    days.append((day, date))
                }
            }
        }

        return try days.map { day in
            try makeHardcoreCandidate(
                descriptor: descriptor,
                path: day.path,
                displayName: "Codex sessions \(codexDayFormatter.string(from: day.date))",
                evidence: "session history older than the seven-day retention window; export/archive is recommended before Trash",
                risk: .high,
                rebuildCost: .notApplicable,
                activeState: activeState,
                request: request,
                fileSystem: fileSystem
            )
        }.sorted(by: candidatePathOrder)
    }
}

public struct HardcoreCodexCorruptSnapshotAdapter: RuleAdapter, Sendable {
    public let descriptor = RuleDescriptor(
        id: "hardcore.codex-corrupt-snapshots",
        name: "Hardcore old Codex corrupt snapshots",
        category: "Hardcore / Codex recovery",
        summary: "Offer timestamped corrupt snapshots older than 30 days for explicit Trash review.",
        explicitNonTargets: [
            "snapshots newer than 30 days or without a valid timestamp",
            "snapshots while Codex is active or process state is unknown",
            "automatic selection or claims that the snapshot is redundant",
        ]
    )

    private let fileSystem: any FileSystemReading
    private let processes: any ProcessProbing

    public init(fileSystem: any FileSystemReading, processes: any ProcessProbing) {
        self.fileSystem = fileSystem
        self.processes = processes
    }

    public func scan(request: ScanRequest) async throws -> [Candidate] {
        guard request.isHardcore, request.deep else { return [] }
        let cutoff = request.now.addingTimeInterval(-30 * 86_400)
        let activeState = processes.state(matching: [
            "exe:codex", "arg:/codex.app/", "arg:/library/application support/codex",
            "arg:features.code_mode_host=true app-server",
        ])
        let snapshots = try fileSystem.immediateChildren(at: request.homePath).compactMap {
            path -> (String, Date)? in
            guard isInScope(path, roots: request.roots),
                  let date = corruptSnapshotDate(basename(path)),
                  date < cutoff,
                  (try? fileSystem.identity(at: path).fileKind) == .directory
            else { return nil }
            return (path, date)
        }

        return try snapshots.map { snapshot in
            try makeHardcoreCandidate(
                descriptor: descriptor,
                path: snapshot.0,
                displayName: basename(snapshot.0),
                evidence: "timestamped recovery snapshot from \(codexDayFormatter.string(from: snapshot.1)); may contain unique history and must be reviewed",
                risk: .high,
                rebuildCost: .notApplicable,
                activeState: activeState,
                request: request,
                fileSystem: fileSystem
            )
        }.sorted(by: candidatePathOrder)
    }
}

public struct HardcoreCoreSimulatorCacheAdapter: RuleAdapter, Sendable {
    public let descriptor = RuleDescriptor(
        id: "hardcore.coresimulator-caches",
        name: "Hardcore CoreSimulator image/dyld caches",
        category: "Hardcore / Xcode Simulator",
        summary: "Exact user-scoped CoreSimulator Images and dyld cache roots that can be rebuilt.",
        explicitNonTargets: [
            "simulator devices, userdata, runtimes, DeviceSupport, Xcode archives, and /Library",
            "any cache while Xcode, Simulator, simctl, or CoreSimulatorService is active or unknown",
        ]
    )

    private let fileSystem: any FileSystemReading
    private let processes: any ProcessProbing

    public init(fileSystem: any FileSystemReading, processes: any ProcessProbing) {
        self.fileSystem = fileSystem
        self.processes = processes
    }

    public func scan(request: ScanRequest) async throws -> [Candidate] {
        guard request.isHardcore, request.deep else { return [] }
        let activeState = processes.state(matching: [
            "exe:xcode", "exe:xcodebuild", "exe:simctl", "exe:simulator",
            "arg:/xcode.app/", "arg:coresimulatorservice",
        ])
        let paths = [
            "Library/Developer/CoreSimulator/Images",
            "Library/Developer/CoreSimulator/Caches/Images",
            "Library/Developer/CoreSimulator/Caches/dyld",
            "Library/Developer/CoreSimulator/Caches/dyld_sim",
        ].map { join(request.homePath, $0) }.filter {
            fileSystem.fileExists(at: $0) && isInScope($0, roots: request.roots)
        }

        return try paths.map { path in
            try makeHardcoreCandidate(
                descriptor: descriptor,
                path: path,
                displayName: "CoreSimulator \(basename(path)) cache",
                evidence: "exact user-scoped CoreSimulator cache root; regenerated by Xcode/Simulator",
                risk: .review,
                rebuildCost: .medium,
                activeState: activeState,
                request: request,
                fileSystem: fileSystem
            )
        }.sorted(by: candidatePathOrder)
    }
}

public struct HardcoreAVDSnapshotAdapter: RuleAdapter, Sendable {
    public let descriptor = RuleDescriptor(
        id: "hardcore.android-avd-snapshots",
        name: "Hardcore Android AVD snapshots",
        category: "Hardcore / Android AVD",
        summary: "Offer exact snapshot roots inside configured AVDs while preserving userdata and the AVD itself.",
        explicitNonTargets: [
            "AVD userdata, sdcard, config, keys, and the .avd directory",
            "cache.img leaves already handled by android.avd-cache",
            "any snapshot while an emulator is active or process state is unknown",
        ]
    )

    private let fileSystem: any FileSystemReading
    private let processes: any ProcessProbing

    public init(fileSystem: any FileSystemReading, processes: any ProcessProbing) {
        self.fileSystem = fileSystem
        self.processes = processes
    }

    public func scan(request: ScanRequest) async throws -> [Candidate] {
        guard request.isHardcore, request.deep else { return [] }
        let avdRoot = join(request.homePath, ".android/avd")
        guard fileSystem.fileExists(at: avdRoot), isInScope(avdRoot, roots: request.roots) else {
            return []
        }
        let activeState = processes.state(matching: [
            "exe:emulator", "arg:qemu-system-", "arg:-avd ",
        ])
        let snapshots = try fileSystem.immediateChildren(at: avdRoot).compactMap {
            avd -> String? in
            guard basename(avd).hasSuffix(".avd"),
                  (try? fileSystem.identity(at: avd).fileKind) == .directory
            else { return nil }
            let path = join(avd, "snapshots")
            guard fileSystem.fileExists(at: path),
                  (try? fileSystem.identity(at: path).fileKind) == .directory
            else { return nil }
            return path
        }

        return try snapshots.map { path in
            try makeHardcoreCandidate(
                descriptor: descriptor,
                path: path,
                displayName: "\(basename(URL(fileURLWithPath: path).deletingLastPathComponent().path)) snapshots",
                evidence: "exact snapshots root; AVD userdata/config are retained; cold boot will be required",
                risk: .high,
                rebuildCost: .notApplicable,
                activeState: activeState,
                request: request,
                fileSystem: fileSystem
            )
        }.sorted(by: candidatePathOrder)
    }
}

public struct HardcoreBuildArtifactAdapter: RuleAdapter, Sendable {
    public let descriptor = RuleDescriptor(
        id: "hardcore.build-artifacts",
        name: "Hardcore newest build-artifact retention",
        category: "Hardcore / Build artifacts",
        summary: "Within proven generated build roots, keep the newest same-name .app, .so, .o, or .a artifact.",
        explicitNonTargets: [
            "source trees, vendor/prebuilt directories, and arbitrary binaries",
            "artifacts outside a proven generated build root",
            "the newest member of every project/name/extension group",
            "any artifact while its owning build tool is active or unknown",
        ]
    )

    private let fileSystem: any FileSystemReading
    private let processes: any ProcessProbing

    private static let projectIndicators: Set<String> = [
        "Package.swift", "build.gradle", "build.gradle.kts", "Cargo.toml", "CMakeLists.txt",
        "package.json", "pom.xml", "pubspec.yaml", "pyproject.toml",
    ]
    private static let generatedNames: Set<String> = [".build", ".cxx", "build", "obj", "target"]
    private static let traversalExclusions: Set<String> = [
        ".git", ".gradle", ".cache", ".codex", ".konan", ".m2", ".android", ".colima",
        "node_modules", "Pods", "Library", "Downloads", "Movies", "Music", "Pictures",
    ]
    private static let artifactExtensions: Set<String> = ["so", "o", "a"]

    public init(fileSystem: any FileSystemReading, processes: any ProcessProbing) {
        self.fileSystem = fileSystem
        self.processes = processes
    }

    public func scan(request: ScanRequest) async throws -> [Candidate] {
        guard request.isHardcore, request.deep else { return [] }
        var generatedRoots: [GeneratedBuildRoot] = []
        var visited = Set<HardcoreFileKey>()
        var visitedCount = 0
        for root in uniqueSorted(request.roots)
            where fileSystem.fileExists(at: root) && !isHardcoreToolStorageRoot(root)
        {
            let identity = try fileSystem.identity(at: root)
            guard identity.fileKind == .directory else { continue }
            try discoverGeneratedRoots(
                below: root,
                depth: 0,
                maxDepth: 7,
                visited: &visited,
                visitedCount: &visitedCount,
                output: &generatedRoots
            )
        }
        try addDerivedDataRoots(request: request, output: &generatedRoots)

        let uniqueRoots = Dictionary(
            generatedRoots.map { ($0.path, $0) },
            uniquingKeysWith: { first, _ in first }
        ).values.sorted { $0.path < $1.path }

        var artifacts: [GeneratedArtifact] = []
        for root in uniqueRoots {
            var entries = 0
            try collectArtifacts(
                below: root.path,
                generatedRoot: root,
                depth: 0,
                maxDepth: 12,
                visitedEntries: &entries,
                output: &artifacts
            )
        }

        let grouped = Dictionary(grouping: artifacts) { artifact in
            "\(artifact.root.projectRoot)|\(basename(artifact.path).lowercased())"
        }
        var processStates: [HardcoreBuildTool: ActiveState] = [:]
        var candidates: [Candidate] = []
        for group in grouped.values where group.count > 1 {
            let ordered = group.sorted {
                if $0.identity.modifiedAt != $1.identity.modifiedAt {
                    return $0.identity.modifiedAt > $1.identity.modifiedAt
                }
                return $0.path > $1.path
            }
            guard let retained = ordered.first else { continue }
            for artifact in ordered.dropFirst() {
                let state: ActiveState
                if let cached = processStates[artifact.root.tool] {
                    state = cached
                } else {
                    state = processes.state(matching: artifact.root.tool.processTerms)
                    processStates[artifact.root.tool] = state
                }
                candidates.append(try makeHardcoreCandidate(
                    descriptor: descriptor,
                    path: artifact.path,
                    displayName: "\(basename(artifact.root.projectRoot)) / \(basename(artifact.path)) (older)",
                    evidence: "proven generated root \(artifact.root.path); kept newest \(retained.path); grouped by exact project and filename",
                    risk: .high,
                    rebuildCost: .medium,
                    activeState: state,
                    request: request,
                    fileSystem: fileSystem
                ))
            }
        }
        return candidates.sorted(by: candidatePathOrder)
    }

    private func discoverGeneratedRoots(
        below directory: String,
        depth: Int,
        maxDepth: Int,
        visited: inout Set<HardcoreFileKey>,
        visitedCount: inout Int,
        output: inout [GeneratedBuildRoot]
    ) throws {
        guard depth <= maxDepth else { return }
        visitedCount += 1
        guard visitedCount <= 20_000 else {
            throw KeepItCleanError.io("Hardcore project discovery exceeded 20,000 directories.")
        }
        let identity = try fileSystem.identity(at: directory)
        guard identity.fileKind == .directory,
              visited.insert(HardcoreFileKey(identity)).inserted
        else { return }

        let children = try fileSystem.immediateChildren(at: directory).sorted()
        let names = Set(children.map(basename))
        let hasProjectIndicator = !names.isDisjoint(with: Self.projectIndicators)
            || children.contains { ["xcodeproj", "xcworkspace", "csproj", "fsproj"].contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) }
        if hasProjectIndicator {
            for child in children where Self.generatedNames.contains(basename(child)) {
                if let tool = generatedRootTool(path: child, projectRoot: directory) {
                    output.append(GeneratedBuildRoot(path: child, projectRoot: directory, tool: tool))
                }
            }
        }

        guard depth < maxDepth else { return }
        for child in children {
            let name = basename(child)
            guard !Self.generatedNames.contains(name),
                  !Self.traversalExclusions.contains(name),
                  !name.hasPrefix(".")
            else { continue }
            let childIdentity = try fileSystem.identity(at: child)
            guard childIdentity.fileKind == .directory else { continue }
            try discoverGeneratedRoots(
                below: child,
                depth: depth + 1,
                maxDepth: maxDepth,
                visited: &visited,
                visitedCount: &visitedCount,
                output: &output
            )
        }
    }

    private func generatedRootTool(path: String, projectRoot: String) -> HardcoreBuildTool? {
        switch basename(path) {
        case ".build":
            guard isRegularFile(join(projectRoot, "Package.swift")),
                  hasAny([join(path, "workspace-state.json"), join(path, "build.db")], kind: .regularFile)
            else { return nil }
            return .swift
        case ".cxx":
            guard hasGradleManifest(projectRoot), isRegularFile(join(projectRoot, "CMakeLists.txt")) else { return nil }
            return .gradle
        case "build":
            if hasGradleManifest(projectRoot),
               hasAny([join(path, "intermediates"), join(path, "generated"), join(path, "tmp")], kind: .directory)
            { return .gradle }
            if isRegularFile(join(path, "CMakeCache.txt")) { return .cmake }
            return nil
        case "target":
            guard isRegularFile(join(projectRoot, "Cargo.toml")),
                  isRegularFile(join(path, ".rustc_info.json"))
            else { return nil }
            return .rust
        case "obj":
            guard isRegularFile(join(path, "project.assets.json")) else { return nil }
            return .dotnet
        default:
            return nil
        }
    }

    private func addDerivedDataRoots(
        request: ScanRequest,
        output: inout [GeneratedBuildRoot]
    ) throws {
        let root = join(request.homePath, "Library/Developer/Xcode/DerivedData")
        guard fileSystem.fileExists(at: root), isInScope(root, roots: request.roots) else { return }
        for project in try fileSystem.immediateChildren(at: root) {
            let products = join(project, "Build/Products")
            guard isDirectory(products) else { continue }
            output.append(GeneratedBuildRoot(path: products, projectRoot: project, tool: .xcode))
        }
    }

    private func collectArtifacts(
        below directory: String,
        generatedRoot: GeneratedBuildRoot,
        depth: Int,
        maxDepth: Int,
        visitedEntries: inout Int,
        output: inout [GeneratedArtifact]
    ) throws {
        guard depth <= maxDepth else { return }
        for child in try fileSystem.immediateChildren(at: directory).sorted() {
            visitedEntries += 1
            guard visitedEntries <= 100_000 else {
                throw KeepItCleanError.io("Hardcore artifact discovery exceeded 100,000 entries in \(generatedRoot.path).")
            }
            let identity = try fileSystem.identity(at: child)
            let extensionName = URL(fileURLWithPath: child).pathExtension.lowercased()
            if extensionName == "app", identity.fileKind == .directory {
                output.append(GeneratedArtifact(path: child, identity: identity, root: generatedRoot))
                continue
            }
            if Self.artifactExtensions.contains(extensionName), identity.fileKind == .regularFile {
                output.append(GeneratedArtifact(path: child, identity: identity, root: generatedRoot))
                continue
            }
            guard depth < maxDepth, identity.fileKind == .directory else { continue }
            try collectArtifacts(
                below: child,
                generatedRoot: generatedRoot,
                depth: depth + 1,
                maxDepth: maxDepth,
                visitedEntries: &visitedEntries,
                output: &output
            )
        }
    }

    private func hasGradleManifest(_ root: String) -> Bool {
        isRegularFile(join(root, "build.gradle")) || isRegularFile(join(root, "build.gradle.kts"))
    }

    private func hasAny(_ paths: [String], kind: FileKind) -> Bool {
        paths.contains { path in
            guard fileSystem.fileExists(at: path), let identity = try? fileSystem.identity(at: path) else { return false }
            return identity.fileKind == kind
        }
    }

    private func isRegularFile(_ path: String) -> Bool {
        guard fileSystem.fileExists(at: path), let identity = try? fileSystem.identity(at: path) else { return false }
        return identity.fileKind == .regularFile
    }

    private func isDirectory(_ path: String) -> Bool {
        guard fileSystem.fileExists(at: path), let identity = try? fileSystem.identity(at: path) else { return false }
        return identity.fileKind == .directory
    }
}

private struct ProjectVersionReferences {
    var gradle = Set<String>()
    var ndk = Set<String>()
    var androidAPIs = Set<Int>()
}

private struct ProjectVersionReferenceScanner {
    let fileSystem: any FileSystemReading
    private let excluded: Set<String> = [
        ".git", ".gradle", ".build", ".cache", ".codex", ".konan", ".m2", ".android",
        ".colima", ".cxx", "build", "target", "node_modules", "Pods", "Library",
        "Downloads", "Movies", "Music", "Pictures",
    ]

    func scan(roots: [String]) throws -> ProjectVersionReferences {
        var references = ProjectVersionReferences()
        var visited = Set<HardcoreFileKey>()
        var count = 0
        for root in uniqueSorted(roots)
            where fileSystem.fileExists(at: root) && !isHardcoreToolStorageRoot(root)
        {
            let identity = try fileSystem.identity(at: root)
            if identity.fileKind == .regularFile {
                try inspect(path: root, references: &references)
            } else if identity.fileKind == .directory {
                try walk(
                    directory: root,
                    depth: 0,
                    visited: &visited,
                    count: &count,
                    references: &references
                )
            }
        }
        return references
    }

    private func walk(
        directory: String,
        depth: Int,
        visited: inout Set<HardcoreFileKey>,
        count: inout Int,
        references: inout ProjectVersionReferences
    ) throws {
        guard depth <= 9 else { return }
        count += 1
        guard count <= 20_000 else {
            throw KeepItCleanError.io("Hardcore project-reference scan exceeded 20,000 directories.")
        }
        let identity = try fileSystem.identity(at: directory)
        guard identity.fileKind == .directory,
              visited.insert(HardcoreFileKey(identity)).inserted
        else { return }

        for child in try fileSystem.immediateChildren(at: directory).sorted() {
            let name = basename(child)
            let childIdentity = try fileSystem.identity(at: child)
            if childIdentity.fileKind == .regularFile,
               (name == "gradle-wrapper.properties"
                    || name == "build.gradle"
                    || name == "build.gradle.kts"
                    || name == "gradle.properties")
            {
                try inspect(path: child, references: &references)
                continue
            }
            guard depth < 9,
                  childIdentity.fileKind == .directory,
                  !excluded.contains(name),
                  !name.hasPrefix(".")
            else { continue }
            try walk(
                directory: child,
                depth: depth + 1,
                visited: &visited,
                count: &count,
                references: &references
            )
        }
    }

    private func inspect(
        path: String,
        references: inout ProjectVersionReferences
    ) throws {
        guard let text = try readSmallText(path, fileSystem: fileSystem, maxBytes: 1_048_576) else { return }
        let name = basename(path)
        if name == "gradle-wrapper.properties" {
            references.gradle.formUnion(captures(
                pattern: #"gradle-([0-9][0-9A-Za-z.+_-]*)-(?:bin|all)\.zip"#,
                text: text
            ))
        }
        if name == "build.gradle" || name == "build.gradle.kts" {
            references.ndk.formUnion(captures(
                pattern: #"ndkVersion\s*(?:=)?\s*[\"']([0-9][0-9A-Za-z.+_-]*)[\"']"#,
                text: text
            ))
            references.androidAPIs.formUnion(captures(
                pattern: #"(?:compileSdk|compileSdkVersion)\s*(?:=)?\s*\(?\s*([0-9]{1,3})"#,
                text: text
            ).compactMap(Int.init))
        }
        if name == "gradle.properties" {
            references.ndk.formUnion(captures(
                pattern: #"(?m)^\s*(?:android\.)?ndkVersion\s*=\s*([0-9][0-9A-Za-z.+_-]*)\s*$"#,
                text: text
            ))
            references.androidAPIs.formUnion(captures(
                pattern: #"(?m)^\s*(?:android\.)?compileSdk\s*=\s*([0-9]{1,3})\s*$"#,
                text: text
            ).compactMap(Int.init))
        }
    }
}

private struct GeneratedBuildRoot: Hashable {
    let path: String
    let projectRoot: String
    let tool: HardcoreBuildTool
}

private struct GeneratedArtifact {
    let path: String
    let identity: FileIdentity
    let root: GeneratedBuildRoot
}

private enum HardcoreBuildTool: Hashable {
    case gradle
    case swift
    case xcode
    case rust
    case cmake
    case dotnet

    var processTerms: [String] {
        switch self {
        case .gradle:
            ["exe:gradle", "exe:gradlew", "arg:org.gradle.launcher.daemon", "arg:gradledaemon"]
        case .swift:
            ["exe:swift", "exe:swift-frontend", "exe:xcodebuild"]
        case .xcode:
            ["exe:xcode", "exe:xcodebuild", "exe:swift-frontend", "arg:/xcode.app/"]
        case .rust:
            ["exe:cargo", "exe:rustc"]
        case .cmake:
            ["exe:cmake", "exe:ninja", "exe:make", "exe:clang"]
        case .dotnet:
            ["exe:dotnet", "exe:msbuild"]
        }
    }
}

private struct HardcoreFileKey: Hashable {
    let device: UInt64
    let inode: UInt64

    init(_ identity: FileIdentity) {
        device = identity.device
        inode = identity.inode
    }
}

private struct ParsedToolVersion: Comparable, Hashable {
    let raw: String
    let components: [Int]
    let suffix: String

    init?(_ raw: String) {
        guard raw.range(
            of: #"^[0-9]+(?:[._+-][0-9A-Za-z]+)*$"#,
            options: .regularExpression
        ) != nil else { return nil }
        let pieces = raw.split(whereSeparator: { !$0.isNumber })
        guard !pieces.isEmpty,
              pieces.allSatisfy({ Int($0) != nil })
        else { return nil }
        self.raw = raw
        components = pieces.compactMap { Int($0) }
        suffix = raw.lowercased()
    }

    static func < (lhs: ParsedToolVersion, rhs: ParsedToolVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return lhs.suffix < rhs.suffix
    }
}

private func makeHardcoreCandidate(
    descriptor: RuleDescriptor,
    path: String,
    displayName: String,
    evidence: String,
    risk: RiskLevel,
    rebuildCost: RebuildCost,
    activeState: ActiveState,
    request: ScanRequest,
    fileSystem: any FileSystemReading
) throws -> Candidate {
    let identity = try fileSystem.identity(at: path)
    let supported = identity.fileKind == .directory || identity.fileKind == .regularFile
    let usage: DiskUsage
    if supported, request.deep {
        usage = try fileSystem.usage(at: path)
    } else {
        usage = DiskUsage(
            logicalBytes: identity.logicalBytes,
            allocatedBytes: identity.allocatedBytes,
            reclaimableBytes: identity.reclaimableBytes,
            fileCount: 1
        )
    }
    let measured = FileIdentity(
        device: identity.device,
        inode: identity.inode,
        ownerID: identity.ownerID,
        fileKind: identity.fileKind,
        logicalBytes: usage.logicalBytes,
        allocatedBytes: usage.allocatedBytes,
        modifiedAt: identity.modifiedAt,
        linkCount: identity.linkCount,
        reclaimableBytes: usage.reclaimableBytes
    )

    let blockReason: String?
    if identity.fileKind == .symbolicLink {
        blockReason = "Symbolic artifacts are never followed."
    } else if !supported {
        blockReason = "Unsupported filesystem object type."
    } else if identity.ownerID != getuid() {
        blockReason = "Artifact is not owned by the current user."
    } else if activeState == .active {
        blockReason = "Owning build tool is active."
    } else if activeState == .unknown {
        blockReason = "Owning build-tool process state could not be proven inactive."
    } else {
        blockReason = nil
    }

    return Candidate(
        ruleID: descriptor.id,
        ruleVersion: "1-hardcore",
        category: descriptor.category,
        path: path,
        displayName: displayName,
        evidence: "\(evidence); \(usage.fileCount) paths / \(usage.uniqueFileCount) unique inodes",
        identity: measured,
        actionKind: blockReason == nil ? .trash : .blocked,
        risk: risk,
        rebuildCost: rebuildCost,
        confidence: activeState == .inactive ? .high : .low,
        activeState: activeState,
        defaultSelected: false,
        blockReason: blockReason
    )
}

private func highestVersion(in versions: Set<String>) -> String? {
    versions.compactMap(ParsedToolVersion.init).max()?.raw
}

private func versionList(_ versions: Set<String>) -> String {
    versions.compactMap(ParsedToolVersion.init).sorted().map(\.raw).joined(separator: ", ")
}

private func gradleDistributionVersion(_ name: String) -> String? {
    let matches = captures(
        pattern: #"^gradle-([0-9][0-9A-Za-z.+_-]*)-(?:bin|all)$"#,
        text: name
    )
    return matches.first
}

private func readSmallText(
    _ path: String,
    fileSystem: any FileSystemReading,
    maxBytes: Int
) throws -> String? {
    guard fileSystem.fileExists(at: path) else { return nil }
    let identity = try fileSystem.identity(at: path)
    guard identity.fileKind == .regularFile,
          identity.logicalBytes <= UInt64(maxBytes)
    else { return nil }
    let data = try fileSystem.readPrefix(at: path, maxBytes: Int(identity.logicalBytes))
    guard data.count == Int(identity.logicalBytes) else { return nil }
    return String(data: data, encoding: .utf8)
}

private func captures(pattern: String, text: String) -> Set<String> {
    guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    return Set(expression.matches(in: text, range: range).compactMap { match in
        guard match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[range])
    })
}

private func isInScope(_ path: String, roots: [String]) -> Bool {
    roots.isEmpty || roots.contains { root in path == root || isDescendant(path, of: root) }
}

private func candidatePathOrder(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
    lhs.path < rhs.path
}

private func isHardcoreToolStorageRoot(_ rawPath: String) -> Bool {
    let path = URL(fileURLWithPath: rawPath).standardizedFileURL.path
    let stateComponents: Set<String> = [
        ".android", ".codex", ".colima", ".gradle", ".konan", ".m2",
        "node_modules", "Pods",
    ]
    if !stateComponents.isDisjoint(with: path.split(separator: "/").map(String.init)) {
        return true
    }
    return path.contains("/Library/Android/sdk")
        || path.contains("/Library/Developer/CoreSimulator")
        || path.contains("/Library/Developer/Xcode/DerivedData")
        || path.contains("/Library/Containers/com.docker.docker")
}

private func androidAPI(_ name: String) -> Int? {
    guard name.range(of: #"^android-[0-9]{1,3}$"#, options: .regularExpression) != nil else {
        return nil
    }
    return Int(name.dropFirst("android-".count))
}

private let codexDayFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.isLenient = false
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
}()

private func codexSessionCutoff(now: Date) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let start = calendar.startOfDay(for: now)
    return calendar.date(byAdding: .day, value: -7, to: start) ?? start
}

private func sessionDate(year: String, month: String, day: String) -> Date? {
    codexDayFormatter.date(from: "\(year)-\(month)-\(day)")
}

private func isNumericDirectory(
    _ path: String,
    digits: Int,
    fileSystem: any FileSystemReading
) -> Bool {
    let name = basename(path)
    guard name.count == digits, name.allSatisfy(\.isNumber) else { return false }
    return (try? fileSystem.identity(at: path).fileKind) == .directory
}

private func corruptSnapshotDate(_ name: String) -> Date? {
    let values = captures(
        pattern: #"^\.codex\.corrupt\.([0-9]{8})(?:-[0-9]{6})?$"#,
        text: name
    )
    guard let value = values.first else { return nil }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.isLenient = false
    formatter.dateFormat = "yyyyMMdd"
    return formatter.date(from: value)
}
