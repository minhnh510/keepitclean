import Foundation
import KeepItCleanCore

public enum NativeActionConfirmation: Hashable, Sendable {
    case none
    case explicit
    case typedPhrase(String)
}

/// A catalog entry wraps Core's serializable argv descriptor with the extra
/// confirmation contract required by the Rules layer. No entry contains a
/// shell, command substitution, glob, or concatenated command string.
public struct CataloguedNativeAction: Hashable, Sendable {
    public let descriptor: NativeActionDescriptor
    public let confirmation: NativeActionConfirmation
    public let isReadOnly: Bool

    public init(
        descriptor: NativeActionDescriptor,
        confirmation: NativeActionConfirmation,
        isReadOnly: Bool
    ) {
        self.descriptor = descriptor
        self.confirmation = confirmation
        self.isReadOnly = isReadOnly
    }
}

public enum NativeActionCatalog {
    public static let gradleStop = CataloguedNativeAction(
        descriptor: NativeActionDescriptor(
            id: "gradle.stop",
            title: "Stop Gradle daemons",
            summary: "Ask Gradle to stop its own background daemons before a fresh scan.",
            executable: "gradle",
            arguments: ["--stop"],
            risk: .low,
            affectedState: "Gradle daemon processes"
        ),
        confirmation: .explicit,
        isReadOnly: false
    )

    public static let cocoaPodsList = CataloguedNativeAction(
        descriptor: NativeActionDescriptor(
            id: "cocoapods.cache-list",
            title: "List CocoaPods cache",
            summary: "Ask CocoaPods to report cache entries without changing them.",
            executable: "pod",
            arguments: ["cache", "list"],
            risk: .low,
            affectedState: "CocoaPods download cache"
        ),
        confirmation: .none,
        isReadOnly: true
    )

    public static let cocoaPodsCleanAll = CataloguedNativeAction(
        descriptor: NativeActionDescriptor(
            id: "cocoapods.cache-clean-all",
            title: "Clean CocoaPods cache",
            summary: "Use CocoaPods to remove all downloaded pod cache entries.",
            executable: "pod",
            arguments: ["cache", "clean", "--all"],
            risk: .review,
            affectedState: "CocoaPods download cache; dependencies will be downloaded again"
        ),
        confirmation: .typedPhrase("CLEAN POD CACHE"),
        isReadOnly: false
    )

    public static let dockerDiskUsage = CataloguedNativeAction(
        descriptor: NativeActionDescriptor(
            id: "docker.system-df",
            title: "Inspect Docker storage",
            summary: "Ask Docker to report daemon-managed disk usage.",
            executable: "docker",
            arguments: ["system", "df", "--verbose"],
            risk: .low,
            affectedState: "Docker daemon-managed images, containers, volumes, and build cache"
        ),
        confirmation: .none,
        isReadOnly: true
    )

    public static let dockerImagePrune = CataloguedNativeAction(
        descriptor: NativeActionDescriptor(
            id: "docker.image-prune",
            title: "Prune dangling Docker images",
            summary: "Ask Docker to remove dangling images only; volumes are excluded.",
            executable: "docker",
            arguments: ["image", "prune", "--force"],
            risk: .review,
            affectedState: "Dangling Docker images; named volumes are not included"
        ),
        confirmation: .typedPhrase("PRUNE DOCKER IMAGES"),
        isReadOnly: false
    )

    public static let colimaStatus = CataloguedNativeAction(
        descriptor: NativeActionDescriptor(
            id: "colima.status",
            title: "Inspect Colima status",
            summary: "Read Colima profile state before considering any daemon-managed cleanup.",
            executable: "colima",
            arguments: ["status"],
            risk: .low,
            affectedState: "Colima profile status"
        ),
        confirmation: .none,
        isReadOnly: true
    )

    public static func colimaStop(profile: String) -> CataloguedNativeAction? {
        guard let profile = validatedIdentifier(profile) else { return nil }
        return CataloguedNativeAction(
            descriptor: NativeActionDescriptor(
                id: "colima.stop.\(profile)",
                title: "Stop Colima profile \(profile)",
                summary: "Stop the selected Colima profile before reviewing its managed data.",
                executable: "colima",
                arguments: ["stop", "--profile", profile],
                risk: .review,
                affectedState: "Running Colima profile \(profile)"
            ),
            confirmation: .typedPhrase("STOP COLIMA \(profile)"),
            isReadOnly: false
        )
    }

    public static let avdList = CataloguedNativeAction(
        descriptor: NativeActionDescriptor(
            id: "android.avd-list",
            title: "List Android virtual devices",
            summary: "Ask avdmanager to list configured AVDs without changing them.",
            executable: "avdmanager",
            arguments: ["list", "avd"],
            risk: .low,
            affectedState: "Android virtual device inventory"
        ),
        confirmation: .none,
        isReadOnly: true
    )

    public static func deleteAVD(name: String) -> CataloguedNativeAction? {
        guard let name = validatedIdentifier(name) else { return nil }
        return CataloguedNativeAction(
            descriptor: NativeActionDescriptor(
                id: "android.avd-delete.\(name)",
                title: "Delete Android virtual device \(name)",
                summary: "Ask avdmanager to delete one explicitly named AVD.",
                executable: "avdmanager",
                arguments: ["delete", "avd", "--name", name],
                risk: .high,
                affectedState: "AVD \(name), including its userdata and snapshots"
            ),
            confirmation: .typedPhrase("DELETE AVD \(name)"),
            isReadOnly: false
        )
    }

    public static let vscodeListExtensions = CataloguedNativeAction(
        descriptor: NativeActionDescriptor(
            id: "vscode.extensions-list",
            title: "List VS Code extensions",
            summary: "Ask VS Code to report installed extension IDs and versions.",
            executable: "code",
            arguments: ["--list-extensions", "--show-versions"],
            risk: .low,
            affectedState: "VS Code extension inventory"
        ),
        confirmation: .none,
        isReadOnly: true
    )

    public static func uninstallVSCodeExtension(identifier: String) -> CataloguedNativeAction? {
        guard let identifier = validatedExtensionIdentifier(identifier) else { return nil }
        return CataloguedNativeAction(
            descriptor: NativeActionDescriptor(
                id: "vscode.extension-uninstall.\(identifier)",
                title: "Uninstall full VS Code extension \(identifier)",
                summary: "Ask VS Code to uninstall the exact extension ID as a whole; this is not version-specific.",
                executable: "code",
                arguments: ["--uninstall-extension", identifier],
                risk: .high,
                affectedState: "All installed versions/files for VS Code extension \(identifier), including the newest"
            ),
            confirmation: .typedPhrase("UNINSTALL EXTENSION \(identifier)"),
            isReadOnly: false
        )
    }

    public static let allStatic: [CataloguedNativeAction] = [
        gradleStop,
        cocoaPodsList,
        cocoaPodsCleanAll,
        dockerDiskUsage,
        dockerImagePrune,
        colimaStatus,
        avdList,
        vscodeListExtensions,
    ]

    public static let allowedExecutables: Set<String> = [
        "avdmanager",
        "code",
        "colima",
        "docker",
        "gradle",
        "pod",
    ]

    public static func isAllowlisted(_ descriptor: NativeActionDescriptor) -> Bool {
        guard allowedExecutables.contains(descriptor.executable),
              descriptor.arguments.allSatisfy({ argument in
            !argument.contains("\0")
                && !argument.contains("\n")
                && !argument.contains("\r")
              })
        else { return false }

        if allStatic.contains(where: {
            $0.descriptor.id == descriptor.id
                && $0.descriptor.executable == descriptor.executable
                && $0.descriptor.arguments == descriptor.arguments
        }) {
            return true
        }

        switch descriptor.executable {
        case "colima":
            guard descriptor.arguments.count == 3,
                  descriptor.arguments[0...1].elementsEqual(["stop", "--profile"]),
                  let profile = validatedIdentifier(descriptor.arguments[2])
            else { return false }
            return descriptor.id == "colima.stop.\(profile)"
        case "avdmanager":
            guard descriptor.arguments.count == 4,
                  descriptor.arguments[0...2].elementsEqual(["delete", "avd", "--name"]),
                  let name = validatedIdentifier(descriptor.arguments[3])
            else { return false }
            return descriptor.id == "android.avd-delete.\(name)"
        case "code":
            guard descriptor.arguments.count == 2,
                  descriptor.arguments[0] == "--uninstall-extension",
                  let identifier = validatedExtensionIdentifier(descriptor.arguments[1])
            else { return false }
            return descriptor.id == "vscode.extension-uninstall.\(identifier)"
        default:
            return false
        }
    }

    private static func validatedIdentifier(_ value: String) -> String? {
        guard !value.isEmpty, value.count <= 128 else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        return value.unicodeScalars.allSatisfy(allowed.contains) ? value : nil
    }

    static func validatedExtensionIdentifier(_ value: String) -> String? {
        guard !value.isEmpty, value.count <= 128 else { return nil }
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 2,
              components.allSatisfy({ component in
                  guard let first = component.unicodeScalars.first,
                        Self.isASCIIAlphanumeric(first)
                  else { return false }
                  return component.unicodeScalars.allSatisfy { scalar in
                      Self.isASCIIAlphanumeric(scalar) || scalar.value == 45 || scalar.value == 95
                  }
              })
        else { return nil }
        return value
    }

    private static func isASCIIAlphanumeric(_ scalar: UnicodeScalar) -> Bool {
        let value = scalar.value
        return (48...57).contains(value)
            || (65...90).contains(value)
            || (97...122).contains(value)
    }
}
