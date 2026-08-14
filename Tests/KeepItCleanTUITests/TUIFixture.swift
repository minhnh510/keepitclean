import KeepItCleanTUI

enum TUIFixture {
    static let gib: UInt64 = 1 << 30
    static let mib: UInt64 = 1 << 20

    static func state(allowsApply: Bool = false) -> TUIState {
        TUIState(
            categories: [
                TUICategory(
                    id: "gradle",
                    title: "Gradle",
                    summary: "Versioned generated caches",
                    items: [
                        TUIItem(
                            id: "gradle-cache",
                            title: "Artifact cache",
                            path: "/Users/test/.gradle/caches/8.9",
                            allocatedBytes: 2 * gib,
                            logicalBytes: 3 * gib,
                            reclaimableBytes: gib + (512 * mib),
                            risk: .safe,
                            rebuild: .automatic,
                            activity: .inactive,
                            reason: "Generated cache with no active Gradle process.",
                            isSelectable: true,
                            isInitiallySelected: true
                        ),
                        TUIItem(
                            id: "gradle-active",
                            title: "Active daemon state",
                            path: "/Users/test/.gradle/daemon/8.9",
                            allocatedBytes: 512 * mib,
                            logicalBytes: 512 * mib,
                            reclaimableBytes: 512 * mib,
                            risk: .review,
                            rebuild: .manual,
                            activity: .active,
                            reason: "Gradle is active, so this state is blocked.",
                            isSelectable: false
                        ),
                    ]
                ),
                TUICategory(
                    id: "konan",
                    title: "Kotlin/Native",
                    summary: "Toolchains need project reference checks",
                    items: [
                        TUIItem(
                            id: "konan-toolchain",
                            title: "Kotlin/Native 2.3.21",
                            path: "/Users/test/.konan/kotlin-native-prebuilt-macos-aarch64-2.3.21",
                            allocatedBytes: 4 * gib,
                            logicalBytes: 4 * gib,
                            reclaimableBytes: 4 * gib,
                            risk: .stateful,
                            rebuild: .redownload,
                            activity: .unknown,
                            reason: "Project reference state could not be proven.",
                            isSelectable: false
                        ),
                    ]
                ),
            ],
            width: 160,
            height: 30,
            allowsApply: allowsApply
        )
    }
}
