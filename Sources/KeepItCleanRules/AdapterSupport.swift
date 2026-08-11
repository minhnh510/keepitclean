import Foundation
import KeepItCleanCore

typealias PathDiscovery = @Sendable (ScanRequest, any FileSystemReading) throws -> [String]

struct CandidatePolicy: Sendable {
    let actionKind: CandidateActionKind
    let risk: RiskLevel
    let rebuildCost: RebuildCost
    let defaultSelected: Bool
    let minimumAge: TimeInterval?
    let reportOnlyReason: String?
    let deepOnly: Bool

    init(
        actionKind: CandidateActionKind,
        risk: RiskLevel,
        rebuildCost: RebuildCost,
        defaultSelected: Bool = false,
        minimumAge: TimeInterval? = nil,
        reportOnlyReason: String? = nil,
        deepOnly: Bool = false
    ) {
        self.actionKind = actionKind
        self.risk = risk
        self.rebuildCost = rebuildCost
        self.defaultSelected = defaultSelected
        self.minimumAge = minimumAge
        self.reportOnlyReason = reportOnlyReason
        self.deepOnly = deepOnly
    }
}

struct DeclarativeRuleAdapter: RuleAdapter, Sendable {
    let descriptor: RuleDescriptor
    private let fileSystem: any FileSystemReading
    private let processes: any ProcessProbing
    private let processNames: [String]
    private let policy: CandidatePolicy
    private let discovery: PathDiscovery

    init(
        descriptor: RuleDescriptor,
        fileSystem: any FileSystemReading,
        processes: any ProcessProbing,
        processNames: [String] = [],
        policy: CandidatePolicy,
        discovery: @escaping PathDiscovery
    ) {
        self.descriptor = descriptor
        self.fileSystem = fileSystem
        self.processes = processes
        self.processNames = processNames
        self.policy = policy
        self.discovery = discovery
    }

    func scan(request: ScanRequest) async throws -> [Candidate] {
        guard request.deep || !policy.deepOnly else { return [] }
        let activeState = processNames.isEmpty
            ? ActiveState.inactive
            : processes.state(matching: processNames)
        let discovered = try discovery(request, fileSystem)
        let paths = request.roots.isEmpty
            ? discovered
            : discovered.filter { path in
                request.roots.contains { root in
                    let normalizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
                    let normalizedRoot = URL(fileURLWithPath: root).standardizedFileURL.path
                    return normalizedPath == normalizedRoot || isDescendant(normalizedPath, of: normalizedRoot)
                }
            }

        return try uniqueSorted(paths).compactMap { path in
            guard fileSystem.fileExists(at: path) else { return nil }
            let identity = try fileSystem.identity(at: path)
            // Never ask a filesystem implementation to recurse through an
            // unsupported object. In particular, usage measurement must not
            // follow a symlink before the candidate can be blocked.
            let usage: DiskUsage
            let measuredRecursively = activeState == .inactive && request.deep
                && (identity.fileKind == .directory || identity.fileKind == .regularFile)
            if measuredRecursively {
                usage = try fileSystem.usage(at: path)
            } else {
                usage = DiskUsage(
                    logicalBytes: identity.logicalBytes,
                    allocatedBytes: identity.allocatedBytes,
                    reclaimableBytes: identity.reclaimableBytes,
                    fileCount: 1
                )
            }
            let measuredIdentity = identity.withUsage(usage)

            let blockReason = blockReason(
                path: path,
                identity: measuredIdentity,
                activeState: activeState,
                now: request.now
            )
            let action: CandidateActionKind
            if policy.actionKind == .reportOnly {
                action = .reportOnly
            } else {
                action = blockReason == nil ? policy.actionKind : .blocked
            }

            return Candidate(
                ruleID: descriptor.id,
                category: descriptor.category,
                path: path,
                displayName: displayName(for: path),
                evidence: evidence(for: path, usage: usage, measuredRecursively: measuredRecursively),
                identity: measuredIdentity,
                actionKind: action,
                risk: policy.risk,
                rebuildCost: policy.rebuildCost,
                confidence: measuredRecursively ? .high : .low,
                activeState: activeState,
                defaultSelected: blockReason == nil && policy.defaultSelected,
                blockReason: blockReason
            )
        }
    }

    private func blockReason(
        path: String,
        identity: FileIdentity,
        activeState: ActiveState,
        now: Date
    ) -> String? {
        if identity.fileKind == .symbolicLink {
            return "Symbolic links are report-only and are never followed."
        }
        if identity.fileKind != .directory && identity.fileKind != .regularFile {
            return "Unsupported filesystem object type."
        }
        switch activeState {
        case .active:
            return "Related developer process is active."
        case .unknown:
            return "Related process state could not be proven inactive."
        case .inactive:
            break
        }
        if let minimumAge = policy.minimumAge,
           now.timeIntervalSince(identity.modifiedAt) < minimumAge
        {
            return "Recently modified; minimum inactive age has not elapsed."
        }
        return policy.reportOnlyReason
    }

    private func evidence(for path: String, usage: DiskUsage, measuredRecursively: Bool) -> String {
        var parts = [descriptor.summary]
        if let minimumAge = policy.minimumAge {
            parts.append("minimum age \(Int(minimumAge / 86_400))d")
        }
        parts.append("\(usage.fileCount) paths / \(usage.uniqueFileCount) unique inodes")
        if !measuredRecursively {
            parts.append("recursive size deferred while related process state is not inactive")
        }
        parts.append("exact leaf \(URL(fileURLWithPath: path).lastPathComponent)")
        return parts.joined(separator: "; ")
    }
}

enum RuleDiscovery {
    static func exactHome(_ relativePaths: [String]) -> PathDiscovery {
        { request, _ in
            relativePaths.map { join(request.homePath, $0) }
        }
    }

    static func homeChildren(
        parent relativeParent: String,
        matching matcher: NameMatcher = .any
    ) -> PathDiscovery {
        { request, fileSystem in
            let parent = join(request.homePath, relativeParent)
            guard fileSystem.fileExists(at: parent) else { return [] }
            return try fileSystem.immediateChildren(at: parent).filter { matcher.matches(basename($0)) }
        }
    }

    static func homeTopLevel(matching matcher: NameMatcher) -> PathDiscovery {
        { request, fileSystem in
            guard fileSystem.fileExists(at: request.homePath) else { return [] }
            return try fileSystem.immediateChildren(at: request.homePath).filter {
                matcher.matches(basename($0))
            }
        }
    }

    static func combine(_ discoveries: [PathDiscovery]) -> PathDiscovery {
        { request, fileSystem in
            try discoveries.flatMap { try $0(request, fileSystem) }
        }
    }
}

enum NameMatcher: Sendable {
    case any
    case exact(Set<String>)
    case prefix(String)
    case suffix(String)
    case fileExtensions(Set<String>)

    func matches(_ name: String) -> Bool {
        switch self {
        case .any:
            true
        case let .exact(names):
            names.contains(name)
        case let .prefix(prefix):
            name.hasPrefix(prefix)
        case let .suffix(suffix):
            name.hasSuffix(suffix)
        case let .fileExtensions(extensions):
            extensions.contains(URL(fileURLWithPath: name).pathExtension.lowercased())
        }
    }
}

func join(_ base: String, _ relative: String) -> String {
    URL(fileURLWithPath: base, isDirectory: true)
        .appendingPathComponent(relative)
        .standardizedFileURL.path
}

func basename(_ path: String) -> String {
    URL(fileURLWithPath: path).lastPathComponent
}

func displayName(for path: String) -> String {
    let name = basename(path)
    return name.isEmpty ? path : name
}

func uniqueSorted(_ paths: [String]) -> [String] {
    Array(Set(paths)).sorted()
}

func isDescendant(_ path: String, of root: String) -> Bool {
    let normalizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
    let normalizedRoot = URL(fileURLWithPath: root).standardizedFileURL.path
    return normalizedPath.hasPrefix(normalizedRoot + "/")
}

private extension FileIdentity {
    func withUsage(_ usage: DiskUsage) -> FileIdentity {
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
