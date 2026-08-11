import Darwin
import Foundation
import KeepItCleanCore

public struct PathValidationPolicy: Sendable {
    public var homePath: String
    public var allowedRoots: [String]
    public var protectedSubtrees: [String]
    public var currentUserID: UInt32

    public init(
        homePath: String,
        allowedRoots: [String]? = nil,
        protectedSubtrees: [String]? = nil,
        currentUserID: UInt32 = getuid()
    ) {
        let home = Self.canonicalSystemAlias(homePath)
        self.homePath = home
        self.allowedRoots = (allowedRoots ?? [home]).map(Self.canonicalSystemAlias)
        self.protectedSubtrees = (protectedSubtrees ?? Self.defaultProtectedSubtrees(homePath: home))
            .map(Self.canonicalSystemAlias)
        self.currentUserID = currentUserID
    }

    /// macOS exposes `/var`, `/tmp`, and `/etc` as compatibility symlinks into
    /// `/private`. Normalize only these fixed OS aliases before walking the
    /// target so a legitimate temporary fixture is not treated as a user-made
    /// symlink. All symlinks below an allowed root remain rejected.
    static func canonicalSystemAlias(_ rawPath: String) -> String {
        let path = NSString(string: rawPath).standardizingPath
        for alias in ["/var", "/tmp", "/etc"] {
            if path == alias || path.hasPrefix(alias + "/") {
                return "/private" + path
            }
        }
        return path
    }

    public static func defaultProtectedSubtrees(homePath: String) -> [String] {
        [
            "/System",
            "/Library",
            "/Applications",
            "/private/var/db",
            "\(homePath)/.ssh",
            "\(homePath)/.gnupg",
            "\(homePath)/.aws",
            "\(homePath)/.kube",
            "\(homePath)/Library/Keychains",
            "\(homePath)/Library/Mail",
            "\(homePath)/Library/Messages",
            "\(homePath)/.codex/sessions",
            "\(homePath)/.codex/archived_sessions",
            "\(homePath)/.codex/sqlite",
            "\(homePath)/.codex/memories",
            "\(homePath)/.codex/attachments",
            "\(homePath)/.codex/skills",
            "\(homePath)/.codex/rules",
            "\(homePath)/.codex/automations",
            "\(homePath)/MinhBrain",
        ]
    }
}

public struct PathValidator: Sendable {
    public let policy: PathValidationPolicy

    public init(policy: PathValidationPolicy) {
        self.policy = policy
    }

    @discardableResult
    public func validateExistingTarget(
        _ rawPath: String,
        expectedIdentity: FileIdentity? = nil
    ) throws -> FileIdentity {
        let path = try validateLexicalAndAncestors(rawPath, targetMayBeMissing: false)
        let identity = try LocalFileSystemReader.readIdentity(at: path)
        guard identity.fileKind != .symbolicLink else {
            throw KeepItCleanError.symbolicLink(path)
        }
        guard identity.ownerID == policy.currentUserID else {
            throw KeepItCleanError.ownerMismatch(path)
        }
        try rejectMountRoot(path: path, identity: identity)

        if let expectedIdentity, !expectedIdentity.matchesForMutation(identity) {
            throw KeepItCleanError.identityChanged(path)
        }
        return identity
    }

    public func validateDestination(_ rawPath: String) throws -> String {
        try validateLexicalAndAncestors(rawPath, targetMayBeMissing: true)
    }

    private func validateLexicalAndAncestors(
        _ rawPath: String,
        targetMayBeMissing: Bool
    ) throws -> String {
        guard !rawPath.isEmpty, rawPath.hasPrefix("/") else {
            throw KeepItCleanError.invalidPath(rawPath)
        }
        guard !rawPath.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
            throw KeepItCleanError.invalidPath(rawPath)
        }
        let rawComponents = rawPath.split(separator: "/", omittingEmptySubsequences: false)
        guard !rawComponents.contains(".."), !rawComponents.contains(".") else {
            throw KeepItCleanError.invalidPath(rawPath)
        }

        let path = PathValidationPolicy.canonicalSystemAlias(rawPath)
        let exactProtected = ["/", "/Users", "/Volumes", policy.homePath]
        guard !exactProtected.contains(path) else {
            throw KeepItCleanError.protectedPath(path)
        }
        guard policy.allowedRoots.contains(where: { isStrictDescendant(path, of: $0) }) else {
            throw KeepItCleanError.protectedPath(path)
        }
        guard !policy.protectedSubtrees.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) else {
            throw KeepItCleanError.protectedPath(path)
        }

        let components = NSString(string: path).pathComponents
        let allowedRoot = policy.allowedRoots
            .filter { path == $0 || path.hasPrefix($0 + "/") }
            .max(by: { $0.count < $1.count })
        let allowedDevice = try allowedRoot.map { try LocalFileSystemReader.readIdentity(at: $0).device }
        var current = "/"
        for (index, component) in components.dropFirst().enumerated() {
            current = URL(fileURLWithPath: current, isDirectory: true).appendingPathComponent(component).path
            var value = stat()
            let result = current.withCString { Darwin.lstat($0, &value) }
            let isFinal = index == components.count - 2
            if result != 0 {
                if targetMayBeMissing, isFinal, errno == ENOENT { break }
                throw KeepItCleanError.io("Unable to inspect ancestor \(current): \(String(cString: strerror(errno)))")
            }
            if value.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK) {
                throw KeepItCleanError.symbolicLink(current)
            }
            if let allowedRoot,
               current == allowedRoot || current.hasPrefix(allowedRoot + "/")
            {
                guard value.st_uid == policy.currentUserID else {
                    throw KeepItCleanError.ownerMismatch(current)
                }
                if let allowedDevice, UInt64(value.st_dev) != allowedDevice {
                    throw KeepItCleanError.mountRoot(current)
                }
            }
        }

        if targetMayBeMissing {
            let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
            let parentIdentity = try LocalFileSystemReader.readIdentity(at: parent)
            guard parentIdentity.ownerID == policy.currentUserID else {
                throw KeepItCleanError.ownerMismatch(parent)
            }
        }
        return path
    }

    private func rejectMountRoot(path: String, identity: FileIdentity) throws {
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        guard parent != path else { throw KeepItCleanError.mountRoot(path) }
        let parentIdentity = try LocalFileSystemReader.readIdentity(at: parent)
        if parentIdentity.device != identity.device {
            throw KeepItCleanError.mountRoot(path)
        }
    }

    private func isStrictDescendant(_ path: String, of root: String) -> Bool {
        path != root && path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }
}
