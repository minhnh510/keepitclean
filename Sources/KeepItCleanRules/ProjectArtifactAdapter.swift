import Foundation
import KeepItCleanCore

public struct ProjectArtifactAdapter: RuleAdapter, Sendable {
    public let descriptor = RuleDescriptor(
        id: "project.artifacts",
        name: "Project build artifacts",
        category: "Projects",
        summary: "Direct project dependencies and build outputs with a recognized project manifest.",
        explicitNonTargets: [
            ".git and other source-control data",
            "source files and user documents",
            "unrecognized build, bin, vendor, and output directories",
            "the project or worktree root itself",
            "ignored files that are not an exact supported artifact name",
        ]
    )

    private let fileSystem: any FileSystemReading
    private let processes: any ProcessProbing

    private static let projectIndicators: Set<String> = [
        ".git",
        "Package.swift",
        "build.gradle",
        "build.gradle.kts",
        "build.zig",
        "composer.json",
        "go.mod",
        "package.json",
        "pom.xml",
        "pubspec.yaml",
        "pyproject.toml",
        "requirements.txt",
        "Cargo.toml",
    ]

    private static let artifactNames: Set<String> = [
        ".build",
        ".cxx",
        ".dart_tool",
        ".expo",
        ".gradle",
        ".next",
        ".nox",
        ".nuxt",
        ".output",
        ".parcel-cache",
        ".svelte-kit",
        ".tox",
        ".turbo",
        ".venv",
        "DerivedData",
        "Pods",
        "build",
        "coverage",
        "dist",
        "node_modules",
        "obj",
        "target",
        "venv",
    ]

    private static let traversalExclusions: Set<String> = [
        "Library", ".cache", ".codex", ".gradle", ".konan", ".m2", ".android", ".colima", ".lldb",
    ]

    public init(fileSystem: any FileSystemReading, processes: any ProcessProbing) {
        self.fileSystem = fileSystem
        self.processes = processes
    }

    public func scan(request: ScanRequest) async throws -> [Candidate] {
        let maxDepth = request.deep ? 6 : 3
        var projectArtifacts: [(path: String, projectRoot: String)] = []
        var visited = Set<FileKey>()
        var processStates: [ArtifactTool: ActiveState] = [:]

        for root in uniqueSorted(request.roots)
        where fileSystem.fileExists(at: root) && !isManagedHomeRoot(root, homePath: request.homePath)
        {
            try discoverProjects(
                below: root,
                depth: 0,
                maxDepth: maxDepth,
                visited: &visited,
                artifacts: &projectArtifacts
            )
        }

        let unique = Dictionary(
            projectArtifacts.map { ($0.path, $0) },
            uniquingKeysWith: { first, _ in first }
        ).values.sorted { $0.path < $1.path }

        return try unique.map { entry in
            let identity = try fileSystem.identity(at: entry.path)
            let proof = identity.fileKind == .directory
                ? artifactProof(for: entry.path, projectRoot: entry.projectRoot)
                : ArtifactProof.insufficient(
                    "Artifact is not a real directory; tool ownership cannot be proven."
                )
            let activeState: ActiveState
            switch proof {
            case let .strong(tool, _):
                if let cached = processStates[tool] {
                    activeState = cached
                } else {
                    let state = processes.state(matching: tool.processTerms)
                    processStates[tool] = state
                    activeState = state
                }
            case .insufficient:
                // A broad global process query creates false positives and still
                // cannot associate state with this project. Keep it report-only.
                activeState = .unknown
            }
            // Symlink artifacts are surfaced as blocked without recursively
            // measuring their targets.
            let usage: DiskUsage
            let measuredRecursively = request.deep && activeState == .inactive
                && (identity.fileKind == .directory || identity.fileKind == .regularFile)
            if measuredRecursively {
                usage = try fileSystem.usage(at: entry.path)
            } else {
                usage = DiskUsage(
                    logicalBytes: identity.logicalBytes,
                    allocatedBytes: identity.allocatedBytes,
                    reclaimableBytes: identity.reclaimableBytes,
                    fileCount: 1
                )
            }
            let measured = identity.withMeasuredUsage(usage)
            let age = request.now.timeIntervalSince(measured.modifiedAt)

            let blockReason: String?
            if measured.fileKind == .symbolicLink {
                blockReason = "Symbolic project artifacts are never followed."
            } else if case let .insufficient(reason) = proof {
                blockReason = reason
            } else if request.isHardcore {
                blockReason = "Hardcore retention preserves the generated root and reviews only superseded .app/.so/.o/.a artifacts."
            } else if activeState == .active {
                blockReason = "The owning build or package-manager process is active."
            } else if activeState == .unknown {
                blockReason = "Owning tool process state could not be proven inactive."
            } else if age < 7 * 86_400 {
                blockReason = "Artifact was modified within the last 7 days."
            } else {
                blockReason = nil
            }

            let actionKind: CandidateActionKind
            switch proof {
            case .insufficient:
                actionKind = measured.fileKind == .symbolicLink ? .blocked : .reportOnly
            case .strong:
                if request.isHardcore {
                    actionKind = .reportOnly
                } else {
                    actionKind = blockReason == nil ? .trash : .blocked
                }
            }
            let proofEvidence: String
            switch proof {
            case let .strong(_, evidence): proofEvidence = evidence
            case let .insufficient(reason): proofEvidence = reason
            }

            return Candidate(
                ruleID: descriptor.id,
                category: descriptor.category,
                path: entry.path,
                displayName: "\(basename(entry.projectRoot)) / \(basename(entry.path))",
                evidence: "\(proofEvidence); project root \(entry.projectRoot); minimum age 7d",
                identity: measured,
                actionKind: actionKind,
                risk: actionKind == .reportOnly ? .high : .review,
                rebuildCost: rebuildCost(for: basename(entry.path)),
                confidence: measuredRecursively ? .medium : .low,
                activeState: activeState,
                defaultSelected: false,
                blockReason: blockReason
            )
        }
    }

    private func artifactProof(for path: String, projectRoot: String) -> ArtifactProof {
        let name = basename(path)
        let ignored = isExplicitlyIgnored(name, by: join(projectRoot, ".gitignore"))

        if ignored, let tool = inferredTool(at: projectRoot) {
            return .strong(
                tool: tool,
                evidence: "Exact root .gitignore entry plus \(tool.evidenceName) project ownership"
            )
        }

        switch name {
        case "node_modules":
            if isRegularFile(join(projectRoot, "package.json")), hasNodeLockfile(at: projectRoot) {
                return .strong(tool: .node, evidence: "package.json plus package-manager lockfile")
            }
        case "Pods":
            if isRegularFile(join(projectRoot, "Podfile.lock")),
               isRegularFile(join(path, "Manifest.lock"))
            {
                return .strong(tool: .cocoaPods, evidence: "Podfile.lock matches a Pods/Manifest.lock owner marker")
            }
        case ".build":
            if isRegularFile(join(projectRoot, "Package.swift")),
               hasAnyRegularFile([join(path, "workspace-state.json"), join(path, "build.db")])
            {
                return .strong(tool: .swift, evidence: "Package.swift plus SwiftPM workspace/build database marker")
            }
        case ".gradle":
            if hasGradleManifest(at: projectRoot),
               isRegularFile(join(path, "buildOutputCleanup/cache.properties"))
            {
                return .strong(tool: .gradle, evidence: "Gradle manifest plus buildOutputCleanup cache marker")
            }
        case ".cxx":
            if hasGradleManifest(at: projectRoot), isRegularFile(join(projectRoot, "CMakeLists.txt")) {
                return .strong(tool: .gradle, evidence: "Android Gradle manifest plus CMakeLists.txt for .cxx")
            }
        case ".dart_tool":
            if isRegularFile(join(projectRoot, "pubspec.lock")),
               isRegularFile(join(path, "package_config.json"))
            {
                return .strong(tool: .dart, evidence: "pubspec.lock plus Dart package_config.json marker")
            }
        case ".next":
            if hasNodeLockfile(at: projectRoot),
               hasAnyRegularFile([join(path, "BUILD_ID"), join(path, "build-manifest.json")])
            {
                return .strong(tool: .node, evidence: "Node lockfile plus Next.js build marker")
            }
        case ".nuxt":
            if hasNodeLockfile(at: projectRoot), isRegularFile(join(path, "nuxt.d.ts")) {
                return .strong(tool: .node, evidence: "Node lockfile plus Nuxt generated type marker")
            }
        case ".svelte-kit":
            if hasNodeLockfile(at: projectRoot), isRegularFile(join(path, "tsconfig.json")) {
                return .strong(tool: .node, evidence: "Node lockfile plus SvelteKit generated tsconfig marker")
            }
        case ".expo":
            if hasNodeLockfile(at: projectRoot),
               hasAnyRegularFile([join(path, "settings.json"), join(path, "devices.json")])
            {
                return .strong(tool: .node, evidence: "Node lockfile plus Expo state marker")
            }
        case ".turbo":
            if hasNodeLockfile(at: projectRoot), isDirectory(join(path, "cache")) {
                return .strong(tool: .node, evidence: "Node lockfile plus Turbo cache directory marker")
            }
        case ".parcel-cache":
            if hasNodeLockfile(at: projectRoot) {
                return .strong(tool: .node, evidence: "Package-manager lockfile plus Parcel-specific cache leaf")
            }
        case ".venv", "venv":
            if hasPythonManifest(at: projectRoot), isRegularFile(join(path, "pyvenv.cfg")) {
                return .strong(tool: .python, evidence: "Python project manifest plus pyvenv.cfg marker")
            }
        case ".tox", ".nox":
            if hasPythonManifest(at: projectRoot), containsPyvenvMarker(below: path) {
                return .strong(tool: .python, evidence: "Python project manifest plus generated environment marker")
            }
        case "target":
            if isRegularFile(join(projectRoot, "Cargo.lock")),
               isRegularFile(join(path, ".rustc_info.json"))
            {
                return .strong(tool: .rust, evidence: "Cargo.lock plus rustc target marker")
            }
            if isRegularFile(join(projectRoot, "pom.xml")), isDirectory(join(path, "maven-status")) {
                return .strong(tool: .maven, evidence: "pom.xml plus Maven status marker")
            }
        case "build":
            if hasGradleManifest(at: projectRoot),
               hasAnyDirectory([
                   join(path, "intermediates"), join(path, "kotlin"),
                   join(path, "generated"), join(path, "tmp"),
               ])
            {
                return .strong(tool: .gradle, evidence: "Gradle manifest plus generated build marker")
            }
            if isRegularFile(join(path, "CMakeCache.txt")) {
                return .strong(tool: .cmake, evidence: "CMakeCache.txt ownership marker")
            }
        case "obj":
            if projectHasFileExtension(["csproj", "fsproj"], at: projectRoot),
               isRegularFile(join(path, "project.assets.json"))
            {
                return .strong(tool: .dotnet, evidence: ".NET project plus project.assets.json marker")
            }
        default:
            break
        }

        return .insufficient(
            "Exact name found, but lockfile, ignore proof, or owning-tool marker is unavailable; report-only."
        )
    }

    private func inferredTool(at projectRoot: String) -> ArtifactTool? {
        if isRegularFile(join(projectRoot, "package.json")), hasNodeLockfile(at: projectRoot) { return .node }
        if isRegularFile(join(projectRoot, "Package.swift")) { return .swift }
        if hasGradleManifest(at: projectRoot) { return .gradle }
        if isRegularFile(join(projectRoot, "Podfile.lock")) { return .cocoaPods }
        if isRegularFile(join(projectRoot, "Cargo.lock")) { return .rust }
        if isRegularFile(join(projectRoot, "pom.xml")) { return .maven }
        if hasPythonManifest(at: projectRoot) { return .python }
        if isRegularFile(join(projectRoot, "pubspec.lock")) { return .dart }
        if isRegularFile(join(projectRoot, "CMakeLists.txt")) { return .cmake }
        if projectHasFileExtension(["csproj", "fsproj"], at: projectRoot) { return .dotnet }
        return nil
    }

    private func hasNodeLockfile(at root: String) -> Bool {
        hasAnyRegularFile([
            join(root, "package-lock.json"), join(root, "npm-shrinkwrap.json"),
            join(root, "pnpm-lock.yaml"), join(root, "yarn.lock"),
            join(root, "bun.lock"), join(root, "bun.lockb"),
        ])
    }

    private func hasGradleManifest(at root: String) -> Bool {
        hasAnyRegularFile([join(root, "build.gradle"), join(root, "build.gradle.kts")])
    }

    private func hasPythonManifest(at root: String) -> Bool {
        hasAnyRegularFile([
            join(root, "pyproject.toml"), join(root, "requirements.txt"),
            join(root, "tox.ini"), join(root, "noxfile.py"),
        ])
    }

    private func hasAnyRegularFile(_ paths: [String]) -> Bool {
        paths.contains(where: isRegularFile)
    }

    private func hasAnyDirectory(_ paths: [String]) -> Bool {
        paths.contains(where: isDirectory)
    }

    private func isRegularFile(_ path: String) -> Bool {
        guard fileSystem.fileExists(at: path),
              let identity = try? fileSystem.identity(at: path)
        else { return false }
        return identity.fileKind == .regularFile
    }

    private func isDirectory(_ path: String) -> Bool {
        guard fileSystem.fileExists(at: path),
              let identity = try? fileSystem.identity(at: path)
        else { return false }
        return identity.fileKind == .directory
    }

    private func projectHasFileExtension(_ extensions: Set<String>, at root: String) -> Bool {
        guard let children = try? fileSystem.immediateChildren(at: root) else { return false }
        return children.contains { extensions.contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) }
    }

    private func containsPyvenvMarker(below root: String) -> Bool {
        guard let children = try? fileSystem.immediateChildren(at: root) else { return false }
        return children.contains { child in
            isDirectory(child) && isRegularFile(join(child, "pyvenv.cfg"))
        }
    }

    private func isExplicitlyIgnored(_ artifactName: String, by ignoreFile: String) -> Bool {
        guard isRegularFile(ignoreFile),
              let identity = try? fileSystem.identity(at: ignoreFile),
              identity.logicalBytes <= 256 * 1_024,
              let data = try? fileSystem.readPrefix(at: ignoreFile, maxBytes: Int(identity.logicalBytes)),
              data.count == Int(identity.logicalBytes),
              let text = String(data: data, encoding: .utf8)
        else { return false }

        let positive = Set([artifactName, "\(artifactName)/", "/\(artifactName)", "/\(artifactName)/"])
        let negative = Set(positive.map { "!\($0)" })
        var ignored = false
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if positive.contains(line) { ignored = true }
            if negative.contains(line) { ignored = false }
        }
        return ignored
    }

    private func isManagedHomeRoot(_ path: String, homePath: String) -> Bool {
        Self.traversalExclusions.contains { name in
            let managed = join(homePath, name)
            return path == managed || isDescendant(path, of: managed)
        }
    }

    private func discoverProjects(
        below directory: String,
        depth: Int,
        maxDepth: Int,
        visited: inout Set<FileKey>,
        artifacts: inout [(path: String, projectRoot: String)]
    ) throws {
        guard depth <= maxDepth else { return }
        let identity = try fileSystem.identity(at: directory)
        guard identity.fileKind == .directory else { return }

        let key = FileKey(device: identity.device, inode: identity.inode)
        guard visited.insert(key).inserted else { return }

        let children = try fileSystem.immediateChildren(at: directory).sorted()
        let names = Set(children.map(basename))
        let isProject = !names.isDisjoint(with: Self.projectIndicators)

        if isProject {
            for child in children where Self.artifactNames.contains(basename(child)) {
                let artifactIdentity = try fileSystem.identity(at: child)
                if artifactIdentity.fileKind == .directory || artifactIdentity.fileKind == .symbolicLink {
                    artifacts.append((path: child, projectRoot: directory))
                }
            }
        }

        guard depth < maxDepth else { return }
        for child in children {
            let name = basename(child)
            guard !Self.artifactNames.contains(name), name != ".git",
                  !Self.traversalExclusions.contains(name), !name.hasPrefix(".")
            else { continue }
            let childIdentity = try fileSystem.identity(at: child)
            guard childIdentity.fileKind == .directory else { continue }
            try discoverProjects(
                below: child,
                depth: depth + 1,
                maxDepth: maxDepth,
                visited: &visited,
                artifacts: &artifacts
            )
        }
    }

    private func rebuildCost(for name: String) -> RebuildCost {
        switch name {
        case "node_modules", "Pods", ".venv", "venv", "target": .high
        case ".gradle", ".dart_tool", ".build", ".cxx": .medium
        default: .low
        }
    }
}

private enum ArtifactProof {
    case strong(tool: ArtifactTool, evidence: String)
    case insufficient(String)
}

private enum ArtifactTool: Hashable {
    case node
    case swift
    case gradle
    case cocoaPods
    case python
    case dart
    case rust
    case maven
    case cmake
    case dotnet

    var evidenceName: String {
        switch self {
        case .node: "Node/package-manager"
        case .swift: "SwiftPM"
        case .gradle: "Gradle"
        case .cocoaPods: "CocoaPods"
        case .python: "Python"
        case .dart: "Dart/Flutter"
        case .rust: "Cargo"
        case .maven: "Maven"
        case .cmake: "CMake"
        case .dotnet: ".NET"
        }
    }

    var processTerms: [String] {
        switch self {
        case .node:
            ["exe:node", "exe:npm", "exe:pnpm", "exe:yarn", "exe:bun"]
        case .swift:
            ["exe:swift", "exe:swift-frontend", "exe:xcodebuild"]
        case .gradle:
            ["exe:gradle", "exe:gradlew", "arg:org.gradle.launcher.daemon", "arg:gradledaemon"]
        case .cocoaPods:
            ["exe:pod", "exe:xcodebuild", "arg:/xcode.app/"]
        case .python:
            ["exe:python", "exe:python3", "exe:pytest", "exe:tox", "exe:nox", "exe:ruff"]
        case .dart:
            ["exe:dart", "exe:flutter"]
        case .rust:
            ["exe:cargo", "exe:rustc"]
        case .maven:
            ["exe:mvn", "exe:mvnw", "arg:org.codehaus.plexus.classworlds.launcher"]
        case .cmake:
            ["exe:cmake", "exe:ninja", "exe:make", "exe:clang"]
        case .dotnet:
            ["exe:dotnet", "exe:msbuild"]
        }
    }
}

private struct FileKey: Hashable {
    let device: UInt64
    let inode: UInt64
}

extension FileIdentity {
    func withMeasuredUsage(_ usage: DiskUsage) -> FileIdentity {
        FileIdentity(
            device: device,
            inode: inode,
            ownerID: ownerID,
            fileKind: fileKind,
            logicalBytes: usage.logicalBytes,
            allocatedBytes: usage.allocatedBytes,
            modifiedAt: modifiedAt,
            linkCount: linkCount,
            reclaimableBytes: usage.reclaimableBytes
        )
    }
}
