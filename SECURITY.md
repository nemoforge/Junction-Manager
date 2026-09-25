# Security and Data Safety

## Security Model

Junction Manager runs elevated and changes filesystem paths. Its checks are intended to stop operations when path identity, ownership or verification cannot be established. They do not provide a zero-risk guarantee, a VSS snapshot or protection against another process deliberately replacing files or directories between checks.

Keep applications, updaters and services closed during migration, and retain an independent backup of important data. An executable-path process scan cannot discover every writer or open file handle. The application requests elevation at launch, including when the user intends to use a read-only feature.

## Migration Safety

The migration engine follows this sequence:

1. **Validate and confirm.** Canonicalize Source/Target, verify distinct local fixed NTFS volumes, reject protected/overlapping paths and unsupported reparse points, check free space, and request confirmation. Related-process handling requires consent; validation runs again afterward.
2. **Copy and compare.** Robocopy copies into a new or empty Target. Inventory checks compare names, sizes, timestamps and stream sizes. FinalSync performs another copy, a Robocopy listing pass and another inventory comparison.
3. **Retain the original data.** Source is renamed to the exact `<Source>_backup` path. That path must not already exist. Source is temporarily unavailable under its original name while subsequent verification runs.
4. **Verify content and create the link.** SHA-256 checks compare the retained backup with Target, including file alternate data streams (ADS). The engine creates a junction at Source, verifies its destination and records the committed transaction.

Production Robocopy flags include `/COPYALL /DCOPY:DAT /SECFIX /TIMFIX /XJ /SL`, with bounded retries. The engine does not use `/MIR`, `/PURGE`, `/MOVE` or `/MOV`. Copy exit codes 0–7 are accepted; the final `/L` verification pass must return 0. Metadata-copy flags do not establish that every NTFS metadata feature has been validated by tests; see [test limitations](TESTING.md#limitations).

The migration does not delete the retained source copy. On failure after renaming but before commitment, it attempts to restore the backup to Source; Target is retained. Recovery can itself fail, so inspect the reported paths and journal before retrying or deleting anything.

### Journals and Rollback

Transaction journals are append-only JSONL and are flushed around namespace changes. They record operations and recovery state; a power loss can still leave an incomplete final record. Corrupt or unresolved journals prevent destructive maintenance where ownership or recovery cannot be established.

Rollback verifies and removes only the junction object, then renames the backup back to Source. Target is retained. New data written to Target after migration is **not** merged into the older backup. Recovery also supports a missing Source when its backup remains, subject to validation.

The retained backup is a copy of the pre-switch source tree, not an atomic filesystem snapshot. A partially deleted backup is not suitable for normal rollback.

## Destructive Operations

Migration, rollback and maintenance share a single background worker. Clear Logs and Delete Backup are disabled while another operation is active, and their engine entry points reject maintenance during Move/Rollback.

### Clear Logs

Clear Logs operates only on the active official log root: `MigrationLogs` beside the script, or the existing LocalAppData/TEMP fallback locations under `JunctionUtility\Logs`. Canonical paths, managed root/session markers and Source/Target/Backup overlap checks limit the deletion scope. The UI confirms the session/file count and approximate size before deletion.

It retains the current session, pending or corrupt journals, history whose backup still exists, and legacy/unowned sessions. Unknown files, subdirectories or reparse points also prevent a session from being treated as disposable. Ownership and eligibility are checked again after confirmation. Locked files produce a partial-cleanup report rather than an aggressive fallback.

### Delete Backup

A `_backup` suffix alone does not establish ownership. The application does not search the machine for matching folders. Deletion requires the exact analyzed Source/Target/Backup paths, a matching latest `Committed` transaction in managed history, and:

- A Source junction that points to the expected, available Target.
- A real backup directory with supported paths, no unsafe overlap and no reparse-point children.
- Backup and Target NTFS directory identities matching the journal.
- Explicit **Delete Backup** confirmation, followed by repeated identity checks and a check for processes running from the backup.

The confirmation explains that this permanently removes the retained pre-migration copy and normal rollback. Current Target data and the Source junction remain. There is no merge, recycle-bin recovery or automatic resume of partial deletion.

Deletion inventories the verified tree first, refuses reparse points, deletes checked files individually and removes empty directories non-recursively. `BackupDeletePending` is recorded before deletion and `BackupDeleted` after success. If deletion or its completion record fails, the journal is retained and a remaining partial backup is blocked from normal rollback.

Identity checks do not imply a fresh content comparison with Target: the running application may legitimately have changed Target since migration. Backups lacking managed provenance or committed NTFS identities are not eligible for this delete action.

## App Discovery

Discovery reads Installed Apps registry entries, process paths, executable version metadata and bounded directory information. It does not run discovered executables or uninstall commands, stop processes/services, write registry values, change permissions or modify application files.

Discovery messages stay in the UI/memory during the read-only operation; the application creates its log session separately at startup. Candidate classification and ranking are hints. Selecting a candidate only fills Source and invalidates earlier analysis; Analyze is still required before Move.

Scans use Known Folder roots and finite time, depth and entry budgets. They do not follow reparse points. Access-denied results, including WindowsApps, produce warnings rather than permission changes. Windows/system and WindowsApps paths remain blocked by migration validation.

## Update Security

The update model is **Check → Compare → Inform → Open official download page**. Only the user's **Check for Updates** action starts the request. Startup and opening About do not request metadata; there is no timer-based update check, scheduler or background auto-update.

- The checker performs a public HTTPS GET with normal certificate validation, an 8-second configured timeout and a 16 KiB response buffer. It disables redirects, retries, cookies and default credentials. It does not weaken global TLS or certificate policy.
- Remote JSON is untrusted. The root must be an object; `version` is required and bounded; `product` must match when present. Notes are bounded plain text, never XAML/HTML. Unknown fields do not become local paths, configuration or commands.
- Versions are compared numerically after an optional `V`/`v` prefix is removed. Only three-component stable versions are accepted; older metadata never offers a downgrade.
- Metadata URLs are limited to HTTPS JSON on `nemoforge.github.io` or raw JSON under this repository on `raw.githubusercontent.com`. Browser links are limited to the author's website or this repository's GitHub repository/release pages. URI validation rejects credentials, query strings, fragments, non-default ports and unsupported paths. Direct GitHub release-asset URLs are not accepted as download pages.
- Browser links are validated again and opened only after a separate user click. The checker never downloads a release, executes remote code or replaces application files. Request/browser errors are non-fatal and do not change the existing migration analysis.

There is no application telemetry or analytics. The request does not include usernames, hostnames, installed apps, Source/Target paths, logs or machine-identifying query parameters. The hosting server still receives ordinary network information such as the request IP address. Update logs contain short status messages, not full HTTP bodies.

HTTPS and URL restrictions are not release signing or artifact hash verification. V1.0.0 has no automatic installation mechanism and does not authenticate downloaded release artifacts on the user's behalf.

### Publishing Metadata

Application metadata and the endpoint are defined once in `$script:AppInfo` in `Junction.ps1`. The configured endpoint serves the repository's [version.json](version.json):

```text
https://raw.githubusercontent.com/nemoforge/Junction-Manager/main/version.json
```

For a future release, publish the complete source/release page before updating that JSON. Its schema is:

| Field | Requirement |
| --- | --- |
| `product` | Optional; must equal `Junction Manager` when present. |
| `version` | Required string, at most 32 characters; for example `V1.0.0`. |
| `downloadUrl` | Optional validated HTTPS page URL, at most 2,048 characters. |
| `releaseNotesUrl` | Optional URL with the same page validation and length limit. |
| `notes` | Optional plain-text string, at most 2,000 characters. |

Keep metadata aligned with the application version being released. The current download URL opens the repository page. Missing optional URLs leave their corresponding buttons unavailable. An empty configured endpoint produces a setup message without a request; changing the endpoint requires a maintainer code change and verification of the new public JSON location.

## Test Safety

The [historical harnesses](TESTING.md#reproducing-the-recorded-tests) isolate mutations under `<ProjectRoot>\.test-sandbox\<GUID>`. An ownership marker records the session, project path and root identity. Cleanup checks that marker and containment, inventories the tree, removes only in-sandbox junction objects and refuses external or unsupported reparse targets.

Cleanup runs in `finally` for ordinary assertion failures and exceptions, then verifies session removal. It removes the parent only if completely empty, including hidden/system entries. An unexpected sibling is retained; parent cleanup errors report a warning. Forced process termination or power loss still requires inspection rather than an assumption that `finally` ran.

Tests use synthetic application data, backups and logs. They do not use real app data for destructive cases. Update tests replace the network boundary and browser launch so automated runs do not fetch public metadata or open a browser. The recorded tests use the project drive; any future cross-volume test requires separately owned sandboxes on both volumes.

## Distribution Authenticity

Prefer downloads from the [official GitHub Releases page](https://github.com/nemoforge/Junction-Manager/releases). Only releases published by Nemoforge through the [official repository](https://github.com/nemoforge/Junction-Manager), the [official website](https://nemoforge.github.io), or a publication domain explicitly designated there by Nemoforge are official Junction Manager releases.

Modified third-party builds and contribution forks are not official releases. A permitted mirror may distribute an unchanged official release, but must identify itself as an unofficial mirror, retain the notices and LICENSE, and link to the original source. Neither public source availability nor a familiar project name establishes Nemoforge's endorsement. See [LICENSE](LICENSE) for distribution and branding terms.

Report suspected malicious redistribution, deceptive update packages, or impersonation to [support@studyhelp.space](mailto:support@studyhelp.space), with the relevant URL and observed behavior. These publication rules do not add release signing or artifact verification to the application; the technical update boundaries above still apply.

## Reporting Security Issues

Report security or data-loss issues privately to [support@studyhelp.space](mailto:support@studyhelp.space). Include the application version, relevant environment, expected/observed behavior and minimal reproduction steps where possible. Redact personal paths, credentials and sensitive file contents before sharing logs.

Avoid posting sensitive vulnerability details in a public issue before the report has been reviewed. No response-time or remediation SLA is specified.
