# Privacy

KeepItClean runs locally and has no telemetry or analytics. Scan results, paths, plans, and operation history remain on the Mac.

Project artifact discovery reads directory names and known manifest names; Maven deep scans inspect provenance filenames such as `_remote.repositories` and `maven-metadata-local.xml`. v0.1 does not index source code and keeps toolchain stores report-only when reference state is incomplete.

JSON output can contain local paths. Review it before sharing in an issue or public log.
