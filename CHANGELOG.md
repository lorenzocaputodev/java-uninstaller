# Changelog

All notable changes to this project are documented in this file.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/).

## [1.1.0] - 2026-09-29

### Added
- Dry run mode: shows everything that would be removed and changes nothing.
- Backup of the environment variables and of the Java registry keys (`.reg` files) before any change.
- Support for Amazon Corretto, BellSoft Liberica and Microsoft Build of OpenJDK.
- Removal of `JDK_HOME`, `JRE_HOME` and of the `HKCU\Software\JavaSoft` key.
- Exit codes: `0` success, `1` completed with warnings, `2` fatal error.
- Unit tests and a GitHub Actions workflow (PSScriptAnalyzer, tests, dry run).

### Changed
- The confirmation prompt is now `[Y]` uninstall, `[D]` dry run, `[N]` cancel.
- The removal logic and the log now live in `uninstall-java.ps1`; `uninstall-java.bat` only handles elevation and confirmation.
- winget packages are uninstalled by exact ID.
- Programs and Features entries are matched with stricter patterns, and uninstallers time out after 10 minutes.
- Folders and registry keys are no longer deleted if a product failed to uninstall.
- The README documents exactly what is removed; the banner was redrawn.

### Fixed
- `ProgramData\Oracle` was deleted entirely instead of `ProgramData\Oracle\Java`.
- `PATH` entries of Temurin, Zulu, Corretto and Microsoft OpenJDK were not removed, while unrelated entries containing "Java" were.
- `PATH` was rewritten as plain `REG_SZ`, expanding its `%VARIABLES%`; the original value type is now preserved.
- winget removed nothing when several Java versions were installed.
- Non-MSI uninstallers could hang the script indefinitely.
- Elevation failed with apostrophes in the path and gave no feedback when denied.
- The scripts could be downloaded with LF line endings, which can break `.bat` labels.

## [1.0.0] - 2026-07-16

Initial release.

[1.1.0]: https://github.com/lorenzocaputodev/java-uninstaller/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/lorenzocaputodev/java-uninstaller/releases/tag/v1.0.0
