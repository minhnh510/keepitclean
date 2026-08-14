import Foundation
import KeepItCleanCore
import KeepItCleanFS

public struct SystemCacheRoots: Hashable, Sendable {
    public let libraryCaches: String
    public let diagnosticReports: String
    public let systemLogs: String

    public init(
        libraryCaches: String = "/Library/Caches",
        diagnosticReports: String = "/Library/Logs/DiagnosticReports",
        systemLogs: String = "/private/var/log"
    ) {
        self.libraryCaches = PathValidationPolicy.canonicalSystemAlias(libraryCaches)
        self.diagnosticReports = PathValidationPolicy.canonicalSystemAlias(diagnosticReports)
        self.systemLogs = PathValidationPolicy.canonicalSystemAlias(systemLogs)
    }
}

public struct SystemCacheScanner: Sendable {
    private let fileSystem: any FileSystemReading
    private let roots: SystemCacheRoots
    private let expectedOwnerID: UInt32
    private let maximumEntries: Int

    public init(
        fileSystem: any FileSystemReading,
        roots: SystemCacheRoots = SystemCacheRoots(),
        expectedOwnerID: UInt32 = 0,
        maximumEntries: Int = 50_000
    ) {
        self.fileSystem = fileSystem
        self.roots = roots
        self.expectedOwnerID = expectedOwnerID
        self.maximumEntries = max(1, maximumEntries)
    }

    public func scan(now: Date = Date()) throws -> SystemCleanupScanResult {
        var candidates: [SystemCleanupCandidate] = []
        var warnings: [String] = []
        var visited = 0

        try collect(
            root: roots.libraryCaches,
            ruleID: "system.cache-files",
            minimumAge: 7 * 86_400,
            maximumDepth: 8,
            now: now,
            candidates: &candidates,
            warnings: &warnings,
            visited: &visited
        ) { path in
            // `/Library/Caches` is itself the semantic boundary. Emit exact
            // old regular-file leaves instead of deleting an app cache root.
            !URL(fileURLWithPath: path).lastPathComponent.isEmpty
        }
        try collect(
            root: roots.diagnosticReports,
            ruleID: "system.crash-reports",
            minimumAge: 7 * 86_400,
            maximumDepth: 4,
            now: now,
            candidates: &candidates,
            warnings: &warnings,
            visited: &visited
        ) { path in
            [".crash", ".ips", ".diag", ".spin", ".hang"].contains {
                path.lowercased().hasSuffix($0)
            }
        }
        try collect(
            root: roots.systemLogs,
            ruleID: "system.rotated-logs",
            minimumAge: 14 * 86_400,
            maximumDepth: 4,
            now: now,
            candidates: &candidates,
            warnings: &warnings,
            visited: &visited
        ) { path in
            let name = URL(fileURLWithPath: path).lastPathComponent.lowercased()
            return name.hasSuffix(".gz") || name.hasSuffix(".bz2")
                || name.hasSuffix(".old") || name.range(of: #"\.[0-9]+$"#, options: .regularExpression) != nil
        }

        candidates.sort { $0.path < $1.path }
        return SystemCleanupScanResult(
            plan: SystemCleanupPlan(createdAt: now, candidates: candidates),
            warnings: warnings
        )
    }

    private func collect(
        root: String,
        ruleID: String,
        minimumAge: TimeInterval,
        maximumDepth: Int,
        now: Date,
        candidates: inout [SystemCleanupCandidate],
        warnings: inout [String],
        visited: inout Int,
        matches: (String) -> Bool
    ) throws {
        guard fileSystem.fileExists(at: root) else { return }
        let rootIdentity = try fileSystem.identity(at: root)
        guard rootIdentity.fileKind == .directory,
              rootIdentity.ownerID == expectedOwnerID
        else {
            warnings.append("Skipped a system root whose ownership/type was unexpected: \(root)")
            return
        }
        var stack: [(String, Int)] = [(root, 0)]

        while let (directory, depth) = stack.popLast() {
            guard visited < maximumEntries else {
                warnings.append("System scan reached the \(maximumEntries)-entry safety limit.")
                return
            }
            for child in try fileSystem.immediateChildren(at: directory).sorted() {
                visited += 1
                guard visited <= maximumEntries else {
                    warnings.append("System scan reached the \(maximumEntries)-entry safety limit.")
                    return
                }
                let identity = try fileSystem.identity(at: child)
                guard identity.device == rootIdentity.device else { continue }
                if identity.fileKind == .directory {
                    guard identity.ownerID == expectedOwnerID,
                          depth < maximumDepth,
                          !isProtectedSubtree(child, root: root)
                    else { continue }
                    stack.append((child, depth + 1))
                    continue
                }
                guard identity.fileKind == .regularFile,
                      identity.ownerID == expectedOwnerID,
                      identity.modifiedAt < now.addingTimeInterval(-minimumAge),
                      matches(child)
                else { continue }
                candidates.append(SystemCleanupCandidate(
                    ruleID: ruleID,
                    path: child,
                    displayName: URL(fileURLWithPath: child).lastPathComponent,
                    reason: "root-owned rebuildable cache/log leaf older than the rule retention window",
                    identity: identity
                ))
            }
        }
    }

    private func isProtectedSubtree(_ path: String, root: String) -> Bool {
        guard root == roots.libraryCaches else { return false }
        let relative = String(path.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let first = relative.split(separator: "/").first else { return true }
        let name = first.lowercased()
        return name == "com.apple.softwareupdate"
            || name.hasPrefix("com.apple.softwareupdate.")
            || name == "com.apple.mobileasset"
            || name.hasPrefix("com.apple.mobileasset.")
    }
}
