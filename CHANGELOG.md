# Changelog

All notable changes to Junction Manager will be documented in this file.

## Unreleased

### Documentation

- Added project licensing terms under [JMCSL-1.0](LICENSE), with README licensing guidance and distribution authenticity information in SECURITY.md. No application version or behavior changed.

## [V1.0.0] - 2026-09-25

### Added

- Windows PowerShell 5.1/WPF interface with Source/Target browsing, Analyze, background operations, progress stages and logs.
- Migration between local fixed NTFS volumes using Robocopy, FinalSync, a retained backup and a verified directory junction at the original path.
- SHA-256 and alternate data stream verification, transaction journals, rollback and related-process detection with consent before closing processes.
- Read-only App Discovery using Installed Apps registry entries, running processes, executable metadata and related locations; ranked results can populate Source for a separate Analyze step.
- Clear Logs for eligible managed history and Delete Backup for an explicitly confirmed, verified migration backup.
- Application metadata, support links and About with manual Check for Updates: Check → Compare → Inform → Open official download page.

### Safety

- Canonical path, volume, overlap and reparse-point checks before migration or destructive maintenance.
- Managed log/session markers and journal/NTFS identity checks for backup deletion; unresolved recovery information is retained.
- HTTPS update metadata validation, plain-text notes and restricted browser links. No automatic release download, remote code execution, self-update or startup update request.
- Owned test sandboxes, cleanup in `finally` and removal of the sandbox parent only when empty.

### Testing

- Recorded validation on 2026-09-25: **186 automated checks** — 58 regression/WPF, 54 Discovery/maintenance/cleanup and 74 offline update checks.
- The recorded Windows PowerShell 5.1 parser review reported no errors in eight PS1 files. A separate production metadata GET returned `UpToDate` for `V1.0.0`.
- These are recorded development results, not a CI or coverage claim. The historical harnesses and test limits are linked in [TESTING.md](TESTING.md).

### Known Limitations

- Windows and local fixed NTFS volumes only; system/profile containers, WindowsApps/MSIX folders and unsupported paths are rejected.
- Process detection is not a file-lock detector or a filesystem snapshot. Applications, updaters and services should remain closed during migration.
- Rollback restores the retained pre-migration copy without merging newer Target data. Delete Backup permanently removes that rollback option.
- Elevated `/COPYALL` metadata preservation, real cross-volume copies and interactive UI/UAC behavior still require the manual checks listed in [TESTING.md](TESTING.md#manual-testing-remaining).

[V1.0.0]: https://github.com/nemoforge/Junction-Manager/releases/tag/v1.0.0
