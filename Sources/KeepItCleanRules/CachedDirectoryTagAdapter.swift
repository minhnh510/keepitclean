import Foundation
import KeepItCleanCore

public struct CachedDirectoryTagAdapter: RuleAdapter, Sendable {
    public let descriptor = RuleDescriptor(
        id: "cachedir-tag.valid",
        name: "Tagged cache directories",
        category: "Tagged caches",
        summary: "Directories carrying the standard, byte-exact CACHEDIR.TAG signature.",
        explicitNonTargets: [
            "directories with a missing, truncated, symlinked, or invalid tag",
            "the configured scan root itself",
            "recent or active developer state",
        ]
    )

    private static let signature = Data(
        "Signature: 8a477f597d28d172789f06886806bc55".utf8
    )
    private static let managedRootNames: Set<String> = [
        "Library", ".cache", ".codex", ".gradle", ".konan", ".m2", ".android", ".colima", ".lldb",
    ]

    private let fileSystem: any FileSystemReading
    private let processes: any ProcessProbing

    public init(fileSystem: any FileSystemReading, processes: any ProcessProbing) {
        self.fileSystem = fileSystem
        self.processes = processes
    }

    public func scan(request: ScanRequest) async throws -> [Candidate] {
        let scansWholeHome = request.roots.contains {
            URL(fileURLWithPath: $0).standardizedFileURL.path
                == URL(fileURLWithPath: request.homePath).standardizedFileURL.path
        }
        guard request.deep || !scansWholeHome else { return [] }
        let maxDepth = request.deep ? 6 : 3
        var candidates: [Candidate] = []
        var visited = Set<TagFileKey>()
        var processStates: [TaggedCacheOwner: ActiveState] = [:]
        let scanRoots = Set(request.roots.map {
            URL(fileURLWithPath: $0).standardizedFileURL.path
        })

        for root in uniqueSorted(request.roots)
        where fileSystem.fileExists(at: root) && !isManagedHomeRoot(root, homePath: request.homePath)
        {
            try walk(
                directory: root,
                scanRoots: scanRoots,
                depth: 0,
                maxDepth: maxDepth,
                measureRecursively: request.deep,
                now: request.now,
                visited: &visited,
                processStates: &processStates,
                candidates: &candidates
            )
        }

        return candidates.sorted { lhs, rhs in
            lhs.path == rhs.path ? lhs.ruleID < rhs.ruleID : lhs.path < rhs.path
        }
    }

    private func walk(
        directory: String,
        scanRoots: Set<String>,
        depth: Int,
        maxDepth: Int,
        measureRecursively: Bool,
        now: Date,
        visited: inout Set<TagFileKey>,
        processStates: inout [TaggedCacheOwner: ActiveState],
        candidates: inout [Candidate]
    ) throws {
        guard depth <= maxDepth else { return }
        let identity = try fileSystem.identity(at: directory)
        guard identity.fileKind == .directory else { return }
        let key = TagFileKey(device: identity.device, inode: identity.inode)
        guard visited.insert(key).inserted else { return }

        let tagPath = join(directory, "CACHEDIR.TAG")
        if !scanRoots.contains(directory), try hasValidTag(at: tagPath) {
            let owner = cacheOwner(for: directory)
            let activeState: ActiveState
            if let owner {
                if let cached = processStates[owner] {
                    activeState = cached
                } else {
                    let state = processes.state(matching: owner.processTerms)
                    processStates[owner] = state
                    activeState = state
                }
            } else {
                // CACHEDIR.TAG proves cache semantics, but not which process
                // owns an arbitrary directory. Without that relationship we
                // cannot prove inactivity, so the entry remains report-only.
                activeState = .unknown
            }
            let measuredRecursively = activeState == .inactive && measureRecursively
            let usage = measuredRecursively
                ? try fileSystem.usage(at: directory)
                : DiskUsage(
                    logicalBytes: identity.logicalBytes,
                    allocatedBytes: identity.allocatedBytes,
                    reclaimableBytes: identity.reclaimableBytes,
                    fileCount: 1
                )
            let measured = identity.withMeasuredUsage(usage)
            let age = now.timeIntervalSince(measured.modifiedAt)

            let blockReason: String?
            if owner == nil {
                blockReason = "Tagged cache owner is unknown; process inactivity cannot be associated with this directory."
            } else if activeState == .active {
                blockReason = "The owning \(owner?.displayName ?? "tool") process is active."
            } else if activeState == .unknown {
                blockReason = "The owning \(owner?.displayName ?? "tool") process state could not be proven inactive."
            } else if age < 7 * 86_400 {
                blockReason = "Tagged cache was modified within the last 7 days."
            } else {
                blockReason = nil
            }

            candidates.append(
                Candidate(
                    ruleID: descriptor.id,
                    category: descriptor.category,
                    path: directory,
                    displayName: basename(directory),
                    evidence: owner.map {
                        "Valid byte-exact CACHEDIR.TAG signature; \($0.displayName) ownership inferred from exact path/marker; minimum age 7d"
                    } ?? "Valid byte-exact CACHEDIR.TAG signature; owning tool unavailable; report-only",
                    identity: measured,
                    actionKind: owner == nil ? .reportOnly : (blockReason == nil ? .trash : .blocked),
                    risk: owner == nil ? .high : .review,
                    rebuildCost: .medium,
                    confidence: measuredRecursively ? .high : .low,
                    activeState: activeState,
                    defaultSelected: false,
                    blockReason: blockReason
                )
            )

            // The tag declares the whole directory cacheable. Do not recurse
            // and emit nested duplicates that would make a cleanup plan overlap.
            return
        }

        guard depth < maxDepth else { return }
        for child in try fileSystem.immediateChildren(at: directory).sorted() {
            if Self.managedRootNames.contains(basename(child)) { continue }
            let childIdentity = try fileSystem.identity(at: child)
            guard childIdentity.fileKind == .directory else { continue }
            try walk(
                directory: child,
                scanRoots: scanRoots,
                depth: depth + 1,
                maxDepth: maxDepth,
                measureRecursively: measureRecursively,
                now: now,
                visited: &visited,
                processStates: &processStates,
                candidates: &candidates
            )
        }
    }

    private func isManagedHomeRoot(_ path: String, homePath: String) -> Bool {
        Self.managedRootNames.contains { name in
            let managed = join(homePath, name)
            return path == managed || isDescendant(path, of: managed)
        }
    }

    private func hasValidTag(at path: String) throws -> Bool {
        guard fileSystem.fileExists(at: path) else { return false }
        let identity = try fileSystem.identity(at: path)
        guard identity.fileKind == .regularFile else { return false }
        return try fileSystem.readPrefix(at: path, maxBytes: Self.signature.count) == Self.signature
    }

    private func cacheOwner(for directory: String) -> TaggedCacheOwner? {
        let name = basename(directory).lowercased()
        let parent = URL(fileURLWithPath: directory).deletingLastPathComponent().path
        let normalized = URL(fileURLWithPath: directory).standardizedFileURL.path.lowercased()

        switch name {
        case ".pytest_cache", ".ruff_cache", ".mypy_cache", "__pycache__":
            return .python
        case ".parcel-cache", ".next", ".nuxt", ".svelte-kit", ".turbo", "node_modules":
            return .node
        case ".dart_tool":
            return .dart
        case ".gradle":
            return .gradle
        case ".build":
            return fileSystem.fileExists(at: join(parent, "Package.swift")) ? .swift : nil
        case "target":
            if fileSystem.fileExists(at: join(parent, "Cargo.lock")) { return .rust }
            if fileSystem.fileExists(at: join(parent, "pom.xml")) { return .maven }
            return nil
        case "build":
            if fileSystem.fileExists(at: join(parent, "build.gradle"))
                || fileSystem.fileExists(at: join(parent, "build.gradle.kts"))
            {
                return .gradle
            }
            if fileSystem.fileExists(at: join(directory, "CMakeCache.txt")) { return .cmake }
            return nil
        default:
            if normalized.contains("/library/developer/xcode/deriveddata/") { return .xcode }
            return nil
        }
    }
}

private struct TagFileKey: Hashable {
    let device: UInt64
    let inode: UInt64
}

private enum TaggedCacheOwner: Hashable {
    case node
    case python
    case swift
    case gradle
    case dart
    case rust
    case maven
    case cmake
    case xcode

    var displayName: String {
        switch self {
        case .node: "Node/package-manager"
        case .python: "Python"
        case .swift: "SwiftPM"
        case .gradle: "Gradle"
        case .dart: "Dart/Flutter"
        case .rust: "Cargo"
        case .maven: "Maven"
        case .cmake: "CMake"
        case .xcode: "Xcode"
        }
    }

    var processTerms: [String] {
        switch self {
        case .node:
            ["exe:node", "exe:npm", "exe:pnpm", "exe:yarn", "exe:bun"]
        case .python:
            ["exe:python", "exe:python3", "exe:pytest", "exe:ruff"]
        case .swift:
            ["exe:swift", "exe:swift-frontend", "exe:xcodebuild"]
        case .gradle:
            ["exe:gradle", "exe:gradlew", "arg:org.gradle.launcher.daemon", "arg:gradledaemon"]
        case .dart:
            ["exe:dart", "exe:flutter"]
        case .rust:
            ["exe:cargo", "exe:rustc"]
        case .maven:
            ["exe:mvn", "exe:mvnw", "arg:org.codehaus.plexus.classworlds.launcher"]
        case .cmake:
            ["exe:cmake", "exe:ninja", "exe:make", "exe:clang"]
        case .xcode:
            ["exe:xcode", "exe:xcodebuild", "exe:swift-frontend", "arg:sourcekitservice", "arg:/xcode.app/"]
        }
    }
}
