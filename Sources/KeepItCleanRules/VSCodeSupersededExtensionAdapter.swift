import Foundation
import KeepItCleanCore

public struct VSCodeSupersededExtensionAdapter: RuleAdapter, Sendable {
    public let descriptor = RuleDescriptor(
        id: "vscode.superseded-extensions",
        name: "Superseded VS Code extension versions",
        category: "VS Code",
        summary: "Older on-disk versions only when exact package manifests prove a newer version of the same extension ID.",
        explicitNonTargets: [
            "the newest installed version of each extension ID",
            "single-version extensions",
            "directories whose publisher, name, or semantic version cannot be verified from package.json",
            "settings, profiles, credentials, snippets, and extension state",
            "direct raw deletion or full-extension uninstall; VS Code has no version-specific uninstall action",
        ]
    )

    private let fileSystem: any FileSystemReading
    private let processes: any ProcessProbing

    public init(fileSystem: any FileSystemReading, processes: any ProcessProbing) {
        self.fileSystem = fileSystem
        self.processes = processes
    }

    public func scan(request: ScanRequest) async throws -> [Candidate] {
        let root = join(request.homePath, ".vscode/extensions")
        guard fileSystem.fileExists(at: root), inventoryIsInScope(root, roots: request.roots) else {
            return []
        }
        let entries = try fileSystem.immediateChildren(at: root)
        let parsed = try entries.compactMap { path -> InstalledExtension? in
            let identity = try fileSystem.identity(at: path)
            guard identity.fileKind == .directory,
                  let parts = parseDirectoryName(basename(path)),
                  let manifest = try extensionManifest(at: path),
                  manifest.identifier == parts.identifier,
                  directoryVersion(parts.version, matchesManifestVersion: manifest.version)
            else { return nil }
            return InstalledExtension(
                path: path,
                identifier: manifest.identifier,
                version: manifest.version,
                semanticVersion: manifest.semanticVersion
            )
        }
        let state = processes.state(matching: ["exe:code", "arg:visual studio code.app"])
        var results: [Candidate] = []

        for group in Dictionary(grouping: parsed, by: \.identifier).values where group.count > 1 {
            guard let newest = group.max(by: {
                $0.semanticVersion < $1.semanticVersion
            }) else { continue }
            for old in group where old.semanticVersion < newest.semanticVersion {
                // Inventory comparison may inspect siblings to prove which
                // version is newest, but an explicit root authorizes emitting
                // only that exact root or its descendants.
                guard candidateIsInScope(old.path, roots: request.roots) else { continue }
                let identity = try fileSystem.identity(at: old.path)
                let usage = state == .inactive && request.deep
                    ? try fileSystem.usage(at: old.path)
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
                let reason: String
                if state == .active {
                    reason = "VS Code is active, and its CLI cannot uninstall only one superseded version."
                } else if state == .unknown {
                    reason = "VS Code process state is unknown, and its CLI cannot uninstall only one superseded version."
                } else {
                    reason = "VS Code CLI has no version-specific uninstall; full-extension uninstall would also remove the newest version."
                }
                results.append(Candidate(
                    ruleID: descriptor.id,
                    category: descriptor.category,
                    path: old.path,
                    displayName: "\(old.identifier) \(old.version)",
                    evidence: "Exact extension ID \(old.identifier); newer installed version: \(newest.version); no version-specific CLI uninstall exists; report-only, never raw delete.",
                    identity: measured,
                    actionKind: .reportOnly,
                    risk: .high,
                    rebuildCost: .low,
                    activeState: state,
                    defaultSelected: false,
                    blockReason: reason
                ))
            }
        }
        return results.sorted { $0.path < $1.path }
    }

    private func parseDirectoryName(
        _ name: String
    ) -> (identifier: String, version: String)? {
        for index in name.indices.reversed() where name[index] == "-" {
            let next = name.index(after: index)
            guard next < name.endIndex else { continue }
            let identifier = String(name[..<index])
            let version = String(name[next...])
            guard NativeActionCatalog.validatedExtensionIdentifier(identifier) != nil,
                  SemanticVersion(version) != nil
            else { continue }
            return (identifier, version)
        }
        return nil
    }

    private func extensionManifest(at directory: String) throws -> ExtensionManifest? {
        let path = join(directory, "package.json")
        guard fileSystem.fileExists(at: path) else { return nil }
        let identity = try fileSystem.identity(at: path)
        guard identity.fileKind == .regularFile,
              identity.logicalBytes > 0,
              identity.logicalBytes <= 512 * 1_024
        else { return nil }
        let data = try fileSystem.readPrefix(at: path, maxBytes: Int(identity.logicalBytes))
        guard data.count == Int(identity.logicalBytes),
              let decoded = try? JSONDecoder().decode(ExtensionManifestPayload.self, from: data),
              let identifier = NativeActionCatalog.validatedExtensionIdentifier(
                  "\(decoded.publisher).\(decoded.name)"
              ),
              let semanticVersion = SemanticVersion(decoded.version)
        else { return nil }
        return ExtensionManifest(
            identifier: identifier,
            version: decoded.version,
            semanticVersion: semanticVersion
        )
    }

    private func directoryVersion(_ directoryVersion: String, matchesManifestVersion version: String) -> Bool {
        directoryVersion == version
            || directoryVersion.hasPrefix(version + "-")
            || directoryVersion.hasPrefix(version + "+")
    }

    private func inventoryIsInScope(_ path: String, roots: [String]) -> Bool {
        roots.isEmpty || roots.contains { root in
            let normalizedRoot = URL(fileURLWithPath: root).standardizedFileURL.path
            return path == normalizedRoot
                || isDescendant(path, of: normalizedRoot)
                || isDescendant(normalizedRoot, of: path)
        }
    }

    private func candidateIsInScope(_ path: String, roots: [String]) -> Bool {
        roots.isEmpty || roots.contains { root in
            let normalizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
            let normalizedRoot = URL(fileURLWithPath: root).standardizedFileURL.path
            return normalizedPath == normalizedRoot || isDescendant(normalizedPath, of: normalizedRoot)
        }
    }
}

private struct InstalledExtension {
    let path: String
    let identifier: String
    let version: String
    let semanticVersion: SemanticVersion
}

private struct ExtensionManifest {
    let identifier: String
    let version: String
    let semanticVersion: SemanticVersion
}

private struct ExtensionManifestPayload: Decodable {
    let publisher: String
    let name: String
    let version: String
}

private struct SemanticVersion: Comparable {
    private enum Identifier: Equatable {
        case numeric(Int)
        case text(String)
    }

    let major: Int
    let minor: Int
    let patch: Int
    private let prerelease: [Identifier]?

    init?(_ value: String) {
        let buildParts = value.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)
        guard buildParts.count <= 2,
              buildParts.count == 1 || Self.validDotIdentifiers(buildParts[1])
        else { return nil }

        let versionParts = buildParts[0].split(
            separator: "-",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        let core = versionParts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard core.count == 3,
              let major = Self.coreNumber(core[0]),
              let minor = Self.coreNumber(core[1]),
              let patch = Self.coreNumber(core[2])
        else { return nil }

        let prerelease: [Identifier]?
        if versionParts.count == 2 {
            let rawIdentifiers = versionParts[1].split(
                separator: ".",
                omittingEmptySubsequences: false
            )
            guard !rawIdentifiers.isEmpty,
                  rawIdentifiers.allSatisfy(Self.validIdentifier)
            else { return nil }
            prerelease = rawIdentifiers.map { raw in
                if raw.allSatisfy(\.isNumber), let value = Int(raw) {
                    return .numeric(value)
                }
                return .text(String(raw))
            }
        } else {
            prerelease = nil
        }

        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }

        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil):
            return false
        case (nil, .some):
            return false
        case (.some, nil):
            return true
        case let (.some(left), .some(right)):
            for (leftID, rightID) in zip(left, right) where leftID != rightID {
                switch (leftID, rightID) {
                case let (.numeric(leftValue), .numeric(rightValue)):
                    return leftValue < rightValue
                case (.numeric, .text):
                    return true
                case (.text, .numeric):
                    return false
                case let (.text(leftValue), .text(rightValue)):
                    return leftValue < rightValue
                }
            }
            return left.count < right.count
        }
    }

    private static func coreNumber(_ value: Substring) -> Int? {
        guard !value.isEmpty,
              value.allSatisfy(\.isNumber),
              value == "0" || value.first != "0"
        else { return nil }
        return Int(value)
    }

    private static func validDotIdentifiers(_ value: Substring) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        return !parts.isEmpty && parts.allSatisfy(validIdentifier)
    }

    private static func validIdentifier(_ value: Substring) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy { scalar in
            let code = scalar.value
            return (48...57).contains(code)
                || (65...90).contains(code)
                || (97...122).contains(code)
                || code == 45
        }
    }
}
