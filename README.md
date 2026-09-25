# Junction Manager

Junction Manager is a Windows PowerShell/WPF utility for moving an application folder to another local NTFS volume while preserving its original path through an NTFS directory junction. It validates the paths, verifies the copy and retains the original data as a backup.

**Version:** V1.0.0 · **Author:** Nemoforge (DINH DUC LOC)

## Key Features

- **Analyze before Move:** path, volume, overlap and available-space checks, with Source/Target folder browsing.
- **Verified migration:** Robocopy with `/COPYALL`, FinalSync, SHA-256 and alternate data stream (ADS) verification, followed by junction verification and transaction journaling.
- **Retained backup and rollback:** keep the pre-migration copy until explicitly deleting it; restore it without deleting Target.
- **App Discovery:** find candidate locations from Installed Apps, running processes, executable metadata and related folders.
- **Controlled maintenance:** Clear Logs preserves recovery information; Delete Backup requires managed provenance and matching directory identities.
- **Background operations and manual updates:** responsive WPF operations, related-process detection with consent, and About → Check for Updates.

## Safety Model

Migration copies and checks the data before renaming Source to a backup. It verifies the backup against Target before creating the junction; it does not delete the retained source data during migration. The original Source path is temporarily unavailable during this final verification.

Discovery is read-only. Destructive maintenance checks ownership, canonical paths and reparse points before confirmation and deletion. Close the application, updater and services before migrating: process detection is not a file-lock detector or an atomic snapshot. Keep an independent backup of important data. See [SECURITY.md](SECURITY.md) for the operation sequence and safety boundaries.

## Requirements

- Windows with **Windows PowerShell 5.1 Desktop** and WPF. The recorded test environment is described in [TESTING.md](TESTING.md#recorded-environment); no broader Windows-version test matrix is claimed.
- Administrator access: the application requests elevation at launch.
- Source and Target on **different local fixed NTFS volumes**, with sufficient free space. Target must be new or empty.
- Built-in Windows tools and .NET Framework components; no external PowerShell modules or installer are required.

## Installation and Usage

1. Download and extract a ZIP from [Releases](https://github.com/nemoforge/Junction-Manager/releases) when available. Alternatively, use **Code → Download ZIP** on the [repository](https://github.com/nemoforge/Junction-Manager).
2. Keep `script.bat`, `Junction.ps1`, `Junction.Discovery.ps1`, `Junction.Maintenance.ps1` and `Junction.Update.ps1` together. Run **script.bat** and approve UAC.
3. Use **Browse Source** or **App Discovery**, then choose the exact destination folder with **Browse Target**. The Target picker can create an empty folder.
4. Close the application, updater and services. Select **Analyze / Validate** and review the results.
5. Select **Move & Create Junction**, review the confirmation and wait for the operation to finish.
6. Test the application at its original path. Retain the backup until satisfied; use **Delete Backup** only after reviewing its permanent-deletion warning.

To launch directly from the extracted directory:

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\Junction.ps1
```

The source repository contains developer documentation and may contain tests. Tests and Markdown files are not required in a runtime ZIP. Logs and ownership markers are created at runtime; do not ship existing `MigrationLogs` or `.test-sandbox` folders as part of a release.

## App Discovery

Search by application name, process name or executable, or select an entry from **Installed Apps**. Discovery combines registry entries, process paths, executable metadata and related folder names, then ranks and deduplicates candidate locations. Scans are bounded and cancellable; classification is a hint rather than a migration safety decision.

**Use as Source** or a double-click fills Source with the selected directory, or the parent directory of a selected executable. It does not move anything. Run Analyze again before migration. Discovery does not execute discovered commands, stop processes or change permissions, including when WindowsApps cannot be read.

## Rollback and Backup

`<Source>_backup` retains the pre-migration data. **Rollback** removes the verified Source junction and restores this older directory to Source, while leaving Target intact. It **does not merge newer data from Target** into the backup.

**Delete Backup** permanently removes the retained copy and normal rollback option. Current Target data and the junction remain. Backups without the required managed history/identity are not eligible for deletion; interrupted deletion requires inspection of the retained journal.

## Check for Updates

Open **About → Check for Updates**. The release model is **Check → Compare → Inform → Open official download page**.

The checker reads HTTPS metadata only on request and compares three-component versions numerically, so `V1.10.0` is newer than `V1.9.9`. For a newer version with a valid download-page URL, **Open Download Page** opens the official page in the default browser after a separate click. Installation remains manual.

There is no automatic release download, self-update, remote code execution, startup update request or application telemetry. Errors are non-fatal and preserve the migration analysis. For URL restrictions, metadata publishing and privacy details, see [Update Security](SECURITY.md#update-security).

## Testing

The latest recorded V1.0.0 development run reports **186 automated checks**: 58 regression/WPF, 54 Discovery/maintenance/cleanup and 74 offline update checks. These are historical results, not a new run or a CI coverage claim.

The harnesses were subsequently removed from `main`; [TESTING.md](TESTING.md) links to their recorded revision and preserves the environment, sandbox paths, cleanup results and remaining manual checks. Test code is not required to run the application.

## Limitations

- Windows-only migration between local fixed NTFS volumes; UNC/network, removable and SUBST paths are rejected.
- Windows/system folders, WindowsApps/MSIX folders and system/profile containers are not supported migration locations. Unsupported reparse-point trees, encrypted/offline files and paths longer than the utility's 240-character limit are rejected.
- Applications, updaters and services should remain closed. Process detection cannot prove that no writer or file lock exists.
- SHA-256/ADS checks verify file content; they are not a guarantee of every NTFS metadata feature or application compatibility.
- Rollback restores the older backup without merging newer Target data; Delete Backup is permanent.

## License

Junction Manager is **source-available** under the [Junction Manager Community Source License 1.0 (JMCSL-1.0)](LICENSE). It is not an OSI Open Source license.

Free use is allowed for personal, educational, research, security-review, and internal organizational purposes, including internal business use. Private modifications and contribution forks are permitted under the license. Free mirrors of unmodified official releases must meet its attribution and distribution conditions.

Commercial redistribution, resale, rebranding as another product, competing distributions, and public distribution of modified builds require prior written permission from Nemoforge, subject to the contribution-fork exception and independently granted platform rights. Malicious use or distribution is prohibited; authorized security research remains permitted. No trademark rights are granted.

See [LICENSE](LICENSE) for the full terms, including contribution licensing. For permission requests, contact [support@studyhelp.space](mailto:support@studyhelp.space).

## Project Links

- [Repository](https://github.com/nemoforge/Junction-Manager)
- [Releases](https://github.com/nemoforge/Junction-Manager/releases)
- [Changelog](CHANGELOG.md)
- [Security and data safety](SECURITY.md)
- [Testing and recorded results](TESTING.md)
- [Website](https://nemoforge.github.io)
- [Support](mailto:support@studyhelp.space)

## Author

Nemoforge (DINH DUC LOC)
