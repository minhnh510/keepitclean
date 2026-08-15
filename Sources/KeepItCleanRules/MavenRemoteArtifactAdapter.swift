import Foundation
import KeepItCleanCore

public struct MavenRemoteArtifactAdapter: RuleAdapter, Sendable {
    public let descriptor = RuleDescriptor(
        id: "maven.remote-artifacts",
        name: "Remote Maven artifact versions",
        category: "Maven",
        summary: "Old version directories carrying Maven remote-repository provenance.",
        explicitNonTargets: [
            "artifacts with maven-metadata-local.xml in their ancestry",
            "~/.m2/settings.xml and credentials",
            "the complete ~/.m2/repository root",
            "recent or active Maven state",
        ]
    )

    private let fileSystem: any FileSystemReading
    private let processes: any ProcessProbing
    private let maximumDirectories: Int

    public init(
        fileSystem: any FileSystemReading,
        processes: any ProcessProbing,
        maximumDirectories: Int = 100_000
    ) {
        self.fileSystem = fileSystem
        self.processes = processes
        self.maximumDirectories = max(1, maximumDirectories)
    }

    public func scan(request: ScanRequest) async throws -> [Candidate] {
        guard request.deep else { return [] }
        let repository = join(request.homePath, ".m2/repository")
        guard fileSystem.fileExists(at: repository) else { return [] }

        let starts = relevantStarts(repository: repository, roots: request.roots)
        guard !starts.isEmpty else { return [] }
        let activeState = processes.state(matching: [
            "mvn", "mvnw", "org.codehaus.plexus.classworlds.launcher",
        ])
        var visited = Set<MavenDirectoryKey>()
        var candidates: [Candidate] = []
        var directoryCount = 0

        for start in starts {
            try walk(
                directory: start,
                repository: repository,
                inheritedLocal: try hasLocalMetadataInAncestors(from: start, through: repository),
                activeState: activeState,
                now: request.now,
                directoryCount: &directoryCount,
                visited: &visited,
                candidates: &candidates
            )
        }
        return candidates.sorted { $0.path < $1.path }
    }

    private func walk(
        directory: String,
        repository: String,
        inheritedLocal: Bool,
        activeState: ActiveState,
        now: Date,
        directoryCount: inout Int,
        visited: inout Set<MavenDirectoryKey>,
        candidates: inout [Candidate]
    ) throws {
        directoryCount += 1
        guard directoryCount <= maximumDirectories else {
            throw KeepItCleanError.io("Maven metadata directory budget exceeded.")
        }
        let identity = try fileSystem.identity(at: directory)
        guard identity.fileKind == .directory else { return }
        let key = MavenDirectoryKey(device: identity.device, inode: identity.inode)
        guard visited.insert(key).inserted else { return }

        let children = try fileSystem.immediateChildren(at: directory)
        let names = Set(children.map(basename))
        let isLocal = inheritedLocal || names.contains("maven-metadata-local.xml")
        if isLocal {
            // A locally installed/published artifact may have no remote source;
            // protect its whole subtree even if a stale remote marker coexists.
            return
        }

        if directory != repository, names.contains("_remote.repositories") {
            let usage = activeState == .inactive
                ? try fileSystem.usage(at: directory)
                : DiskUsage(
                    logicalBytes: identity.logicalBytes,
                    allocatedBytes: identity.allocatedBytes,
                    reclaimableBytes: identity.reclaimableBytes,
                    fileCount: 1
                )
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
            let isOld = now.timeIntervalSince(measured.modifiedAt) >= 30 * 86_400
            let blockReason: String?
            if activeState == .active {
                blockReason = "Maven is active."
            } else if activeState == .unknown {
                blockReason = "Maven process state could not be proven inactive."
            } else if !isOld {
                blockReason = "Remote artifact was modified within the last 30 days."
            } else {
                blockReason = nil
            }
            candidates.append(Candidate(
                ruleID: descriptor.id,
                category: descriptor.category,
                path: directory,
                displayName: basename(directory),
                evidence: "_remote.repositories provenance present; no local metadata ancestor; minimum age 30d",
                identity: measured,
                actionKind: blockReason == nil ? .trash : .blocked,
                risk: .review,
                rebuildCost: .high,
                confidence: activeState == .inactive ? .high : .low,
                activeState: activeState,
                defaultSelected: false,
                blockReason: blockReason
            ))
            return
        }

        for child in children {
            let childIdentity = try fileSystem.identity(at: child)
            guard childIdentity.fileKind == .directory else { continue }
            try walk(
                directory: child,
                repository: repository,
                inheritedLocal: false,
                activeState: activeState,
                now: now,
                directoryCount: &directoryCount,
                visited: &visited,
                candidates: &candidates
            )
        }
    }

    private func relevantStarts(repository: String, roots: [String]) -> [String] {
        guard !roots.isEmpty else { return [repository] }
        var starts: [String] = []
        for rawRoot in roots {
            let root = URL(fileURLWithPath: rawRoot).standardizedFileURL.path
            if root == repository || isDescendant(repository, of: root) {
                starts.append(repository)
            } else if isDescendant(root, of: repository) {
                starts.append(root)
            }
        }
        return uniqueSorted(starts)
    }

    private func hasLocalMetadataInAncestors(from start: String, through repository: String) throws -> Bool {
        var current = start
        while current == repository || isDescendant(current, of: repository) {
            if fileSystem.fileExists(at: join(current, "maven-metadata-local.xml")) {
                return true
            }
            if current == repository { break }
            current = URL(fileURLWithPath: current).deletingLastPathComponent().path
        }
        return false
    }
}

private struct MavenDirectoryKey: Hashable {
    let device: UInt64
    let inode: UInt64
}
