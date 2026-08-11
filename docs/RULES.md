# Rule catalog and non-targets

Rules emit evidence-backed candidates. A directory name alone is never sufficient evidence.

| Adapter | Reviewable targets | Explicit non-targets |
|---|---|---|
| Gradle | old `.tmp`, version-scoped transforms and build cache | live daemon state, wrapper/dependency stores, credentials and arbitrary `~/.gradle` siblings; wrapper versions remain report-only in v0.1 |
| LLDB | known module and remote-platform caches while debuggers are inactive | `.lldbinit`, history, scripts, plugins |
| Kotlin/Native | exact compilation cache leaf; downloaded distributions/dependencies are report-only in v0.1 | every distribution/dependency without project-reference proof; architecture is never inferred unused from host CPU alone |
| Codex | exact cache/staging leaves with conservative age rules | sessions, archived sessions, SQLite, memories, credentials, config, skills, attachments, generated user assets and worktree state |
| Android | cache leaves and explicit native actions | ADB keys, keystores, AVD userdata, SD cards and whole AVDs without a native-action plan |
| Colima/Docker | read-only allocation report and exact native Docker prune or Colima stop plans | VM disks, images, containers and volumes through raw filesystem deletion |
| CocoaPods | exact download caches through `pod cache` native actions | all repo indexes, private repos and project source |
| Maven | artifacts proven remote/re-downloadable | `maven-metadata-local.xml`, locally installed/published artifacts and unknown repositories |
| Xcode | individual DerivedData children after active-state checks | Archives, signing data, simulators and current device support |
| VS Code | manifest-verified older directories are reported when a newer semantic version of the same exact extension ID exists | newest/single-version extensions, raw directory deletion, settings, profiles, credentials and extension data; the official CLI can uninstall only the extension as a whole, so old-version findings stay report-only |
| Downloads | old installer/archive files explicitly selected by the user | documents, media and arbitrary Downloads content |
| Projects | exact generated directories below configured roots | repository/worktree roots, `.git`, source, ignored private state and unknown build output |
| Generic cache | known owner adapters or a valid `CACHEDIR.TAG` leaf | blanket `.cache` cleanup and active model/runtime caches |

## Default selection

v0.1 auto-selects nothing. An inactive, user-owned, exact cache leaf may be selected during TUI review only after its age/process checks pass. Recent, high-rebuild-cost, stateful, native, Codex, Downloads, and reference-dependent findings remain unselected or blocked.

## Native actions

Native actions are isolated from Trash operations. Each declares a fixed executable, argv list, per-action process policy, risk explanation, affected state, and confirmation contract. Inspection actions are read-only; state-changing actions are non-undoable. v0.1 exposes these as reviewable plans but production `native-action run` fails closed before process launch because Darwin has no descriptor-bound `exec`; tests use an injected fake runner only. The [official VS Code CLI](https://code.visualstudio.com/docs/configure/command-line#_working-with-extensions) accepts a full extension ID for uninstall, not a version-specific uninstall; KeepItClean therefore keeps superseded-version findings report-only and exposes full-extension uninstall as a separate high-risk plan.
