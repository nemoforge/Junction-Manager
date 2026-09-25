# Testing

## Automated Test Summary

The latest recorded V1.0.0 development run on **2026-09-25** reports **186 passing checks**:

| Harness | Recorded passing checks | Scope |
| --- | ---: | --- |
| `tests/Smoke.ps1` | 58 | Migration regression, WPF, worker/runspace and shell-error handling. |
| `tests/Features.ps1` | 54 | Discovery, managed logs/backups and sandbox cleanup. |
| `tests/Updates.ps1` | 74 | Offline update validation, failures and UI state. |
| **Total** | **186** | Latest recorded suite results; repeated runs are not added to this total. |

These results are preserved from the development report at [revision f46e9f1](https://github.com/nemoforge/Junction-Manager/blob/f46e9f14d73f85ef8ebb5c8256cebd0830754f93/TESTING.md). The harnesses were subsequently removed from `main`; their code remains available in Git history. This documentation-only revision did not rerun the application, harnesses or online update probe. It makes no CI, coverage percentage, benchmark or additional compatibility claim.

The recorded final parser review found **0 errors in eight PS1 files**. WPF XAML, handlers, timers and background workers were exercised without displaying the application window. Interactive checks remain separate below.

## Recorded Environment

| Item | Recorded value |
| --- | --- |
| Historical project path | `E:\code\project\app` |
| Mutation drive/filesystem | E:, NTFS |
| PowerShell | Windows PowerShell 5.1.26100.9549 |
| Elevation | Not elevated |
| Real cross-volume fixture | None |
| PSScriptAnalyzer | Not installed; not run |

These paths describe the recorded runs, not a required installation location. The report did not establish a supported Windows-version matrix.

### What the Results Establish

- **Migration regression:** Unicode/special-character paths, path validation, native Robocopy, ADS and SHA-256 verification, retained backups, junction removal without deleting Target, rollback, missing Source and unavailable Target recovery, and injected rename/junction/verification/journal failures.
- **WPF:** actual XAML loading, asynchronous Analyze, queue/timer completion, path invalidation, Use as Source, maintenance locking and Discovery cancellation controls. Website/email shell failures were injected; no browser or mail client was opened by the harness.
- **Discovery:** normalization, executable metadata, registry/candidate deduplication, unknown-EXE inference, running-process ranking, classification, related folders, access-denied/WindowsApps warnings, cancellation and Source selection. A full sandbox inventory/hash comparison found no mutation during the read-only scan, including ADS/log contents.
- **Maintenance:** committed backup provenance and NTFS identity checks, wrong/missing/junction backups, reparse children, mismatched destinations/journals, confirmation cancellation, retained Target content/ADS and functional junctions, unavailable rollback after deletion, locked-file partial deletion, and preservation of pending recovery journals. Clear Logs retained current/unresolved/unowned sessions and reported partial cleanup for a locked log.
- **Updates:** equal/newer/older versions, numeric `V1.10.0 > V1.9.9` comparison, invalid or oversized JSON/fields, missing version, product mismatch, unsafe URI/host/port/credentials/query, plain-text notes, simulated timeout/connection failure, non-fatal browser failure, double-click prevention, stale-link reset and UI restoration. Startup/opening About produced no request; successful and failed checks preserved Analyze and Source/Target state.

### Test Substitutions and Limits

The regression harness simulates a different Target volume identity **in memory** so copy, hashing, junction and rollback cases can run on one physical project drive. Production still requires distinct local fixed NTFS volumes. This does not establish real cross-volume copy behavior.

In the recorded non-elevated run, the native `/COPYALL` probe failed safely without audit privilege. Successful copy cases then used `/COPY:DAT` and omitted `/SECFIX` **only in the harness's in-memory function override**. Production flags were unchanged. Native Robocopy returned 1/0 for successful passes and 16 for the privilege probe; these were not merely mocked exit codes. Elevated ACL/owner/SACL preservation remains unverified by that run.

Harness confirmations are controlled and related-process stopping is bypassed for synthetic fixtures. Transaction failures and shell/network errors use fault injection. Update tests replace the HTTP boundary and browser launch, so they do not depend on the public Internet or create browser runtime files. The real HttpClient/handler was also instantiated offline to check that the configured timeout, response limit, redirect and credential properties were supported.

## Safety of Test Harness

All mutable fixtures are created under `<ProjectRoot>\.test-sandbox\<SessionGUID>` on the project drive. The historical `tests/Sandbox.ps1` creates a `.junction-test-sandbox` marker containing session/project/root information, a timestamp and NTFS directory identity. Individual cases use their own named/GUID directories. Host-script copies, source/target trees, backups, ADS, logs and journals remain within that session.

Cleanup runs in `finally` for ordinary test failures and exceptions. It verifies the marker, canonical containment and root identity, inventories the tree before deletion, and only removes junction objects whose destinations stay inside the sandbox. Missing/malformed ownership or unsupported/external reparse points stop cleanup with the exact path reported. Cleanup never falls back to deleting arbitrary directories.

After session removal, cleanup canonicalizes the exact `.test-sandbox` parent and rejects reparse ancestors. It removes the parent non-recursively only when completely empty, including hidden/system entries. Other sessions or unknown content are retained. Parent cleanup failure emits a warning with the path. Forced process termination or power loss cannot be assumed to execute `finally`.

The current-drive preference keeps destructive cases away from real AppData, Program Files, Windows and application backups. Read-only metadata/system queries may read other drives. A future real cross-volume test requires dedicated GUID sandboxes with ownership markers on both volumes and an explicit cleanup report.

## Reproducing the Recorded Tests

The current `main` branch does not contain the harnesses. Use a separate checkout of the [recorded source and harness revision](https://github.com/nemoforge/Junction-Manager/tree/f46e9f14d73f85ef8ebb5c8256cebd0830754f93) when reproducing the results; do not assume the paths below exist in a runtime ZIP or current source checkout.

From that revision's project directory, run:

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\tests\Smoke.ps1
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\tests\Features.ps1
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\tests\Updates.ps1
```

Preserve the reported environment and substitutions when comparing results. An elevated run follows different copy-privilege conditions; record its actual counts and outcomes rather than assuming the non-elevated total.

## Recorded Development Runs

All runs below were recorded on **2026-09-25**. The chronology and exact sandbox paths are retained as evidence of the earlier work; no new fixtures were created for this documentation pass.

### Discovery and Maintenance

The final run at this stage passed **56 regression/WPF checks** (including the original 52) and **49 feature checks**. The parser review reported 0 errors across three production and three test PS1 files. Static review found no empty catches, Discovery mutation/execute/kill operations, recursive deletion APIs or destructive Robocopy switches. New deletion calls were limited to the guarded maintenance deleter; existing junction removal remained non-recursive.

Sandbox roots, including the initial feature run that stopped because of its mock setup:

```text
E:\code\project\app\.test-sandbox\3916f4d320c04265978a2d32409c3187
E:\code\project\app\.test-sandbox\8666ef5aad5a44388bf9dbe6c62c306d
E:\code\project\app\.test-sandbox\757d22cbd4904997962c33e08548879a
E:\code\project\app\.test-sandbox\9d663b17314242818892626511cfb556
E:\code\project\app\.test-sandbox\c69c33ec4c1d42c8b76bce36c298fc17
```

Each session was verified absent after cleanup, including the failed mock run. At this earlier stage, the empty `.test-sandbox` parent remained by design and historical runtime logs were retained.

The recorded read-only machine scan inspected Uninstall registry entries, process paths, executable metadata and eight Known Folder roots: Program Files/x86, Local Programs, LocalAppData, Roaming, System32, SysWOW64 and WindowsApps. It found **390 deduplicated installed apps**; a `Zalo` query returned **4 candidates in approximately 6.6 seconds**. This is one observed run, not a performance or completeness guarantee. WindowsApps permissions were not changed. No test mutation occurred outside E:; C: was read for Discovery/system information.

### Metadata, Parent Cleanup and Packaging

This stage passed **58 regression/WPF checks** and **54 feature/cleanup checks**, totaling **112**. Parser review found 0 errors across six PS1 files. New cleanup cases retained hidden files/sibling directories, removed an empty parent, rejected the wrong parent and a reparse parent, and preserved marker guards. The first warning-capture case exposed missing common-parameter support in the helper; after that correction, Features and Smoke passed again. The failed run was cleaned in `finally`.

Sandbox roots:

```text
E:\code\project\app\.test-sandbox\fc1dbddf61cc41bbbc914a3f191d3287
E:\code\project\app\.test-sandbox\0a03208061004a998366268a871a95e1
E:\code\project\app\.test-sandbox\f855399cc92a427ab38392a075707866
E:\code\project\app\.test-sandbox\e4d34b681374445d8fbb7c0cbf58e8f7
```

Every session and the empty parent were verified removed. No fixture was written on another drive. C: was read for executable metadata and the absence of a historical journal's backup; no real backup, Source or Target was deleted by this test work.

The packaging cleanup removed `E:\code\project\app\MigrationLogs` and session `20260925_171859_76fa219a394d48338e2cf2693ad465b9` after verifying markers, directory identity, a valid final `BackupDeleted` journal, absent backup and no active application mutex owner. This was a separately reviewed cleanup of completed runtime history. Root-marker removal occurred last.

The recorded final tree at that stage contained only `.gitignore`, three production PS1 files, `script.bat`, `TESTING.md` and three test PS1 files. Enumeration included hidden/system entries and found no runtime/test folders, junctions, backup/ADS fixtures, temporary logs/journals/dumps or extra ADS on source files. The report stated **No test/runtime artifacts remain** for that historical state; it is not a claim about every subsequent checkout or application launch.

### Manual Update Checks

After adding the update checker, the recorded suite total became **58 + 54 + 74 = 186**. All eight PS1 files parsed without errors. The final sandbox below reran all 74 offline update checks after the public endpoint was configured; they still passed, including the no-startup-request case.

Sandbox roots:

```text
E:\code\project\app\.test-sandbox\64a6b642be6d44d1a5cab4750c8f9731
E:\code\project\app\.test-sandbox\eb6b62fe6e584ce09434726426543e9c
E:\code\project\app\.test-sandbox\a9ec8b12f8b346f38def6d0917e20f86
E:\code\project\app\.test-sandbox\56301bc0caa84b2ab4367b0e545035ec
```

**Cleanup verified: no test fixture remains.** This was verified at the end of the recorded runs, including removal of the empty parent. There were no cross-volume fixtures. C: was only read for system metadata. The requested `.git` repository was intentional development metadata; `E:\code\project\app\MigrationLogs` already existed at the start of that stage and was retained outside Git/package scope.

The recorded update audit found no Invoke-Expression/`iex`, DownloadFile, BITS, Expand-Archive or remote-script execution in the feature. Its new shell launch accepted only a revalidated HTTPS URI with no command arguments. Existing migration, Discovery and maintenance guards were unchanged.

### Controlled Online Probe

**Online update endpoint tested: yes**, during the recorded implementation work. After publishing `version.json`, production `Get-UpdateStatus` fetched:

```text
https://raw.githubusercontent.com/nemoforge/Junction-Manager/main/version.json
```

It returned `UpToDate` and `V1.0.0`. The endpoint was configured only after that successful probe. The probe used `-LibraryOnly` with a null Context, wrote no application log/file, downloaded no release and opened no browser. Normal HTTPS/certificate validation succeeded in that environment. Network failures were simulated in offline tests; a real invalid-certificate server and different proxy configurations were not exercised.

## Manual Testing Remaining

Use owned synthetic fixtures or a suitable test VM for mutation cases. The recorded automated results do not establish the following:

1. **Interactive launch and UI:** UAC approval/cancellation, relaunch, the native folder picker, visible resize/scroll/focus/double-click behavior, DPI layouts, and the explicit Delete Backup dialog.
2. **Elevated copy and real volumes:** `/COPYALL` preservation of ACLs, owner and SACL in owned sandboxes; actual cross-volume copying with separately owned source and target roots.
3. **Processes and real application behavior:** graceful close/force-close consent with a dedicated test application, updater/service writers, file-lock edge cases, and application compatibility after migration. Automated tests did not terminate real user processes.
4. **Interrupted operation recovery:** process termination, power loss or test-volume removal in a VM, followed by recovery after restart. Existing transaction failures were injected in controlled tests.
5. **Broader Discovery:** other installed applications, restricted MSIX/WindowsApps access, large scans and cancellation while an OS I/O call is pending.
6. **Maintenance interaction:** confirmation/cancellation, UI state refresh, session locks and fallback log roots with synthetic managed sessions/backups; do not use real application backups for an initial deletion test.
7. **External links and network environments:** successful browser/mail launch, About update-page interaction and real TLS/proxy failures. Shell failures were injected; the browser was not opened during automated tests.

## Limitations

- Same-drive native copy plus a simulated volume identity does not test real cross-volume behavior. Non-elevated `/COPY:DAT` success does not prove elevated `/COPYALL` security metadata preservation.
- Parser and headless WPF checks do not establish interactive usability, UAC behavior or support across all Windows releases.
- Migration is not VSS or a kernel transaction. It cannot prove that every writer/lock is absent or prevent an adversarial process from replacing a checked path between operations.
- Validation limits migrations to different local fixed NTFS volumes. UNC/removable/SUBST, protected Windows/WindowsApps paths, unsupported reparse trees, EFS/offline content, paths over 240 characters and `~` aliases are rejected.
- Inventory/hash work grows with file count. File and ADS verification does not establish preservation of all NTFS metadata, hard-link relationships, directory streams or sparse layout.
- Discovery has bounded time/depth/entry limits and may miss deeply nested or poorly identified applications. Its default scan budget is 15 seconds (capped at 30), 20,000 entries, 1,500 directory enumerations, three child-directory levels and 250 candidates. Selected-folder sizing has a 5-second budget and reports logical main-file size; it does not include full ADS/allocated-size accounting. An OS call can delay cancellation beyond the configured budget.
- Legacy/unowned log sessions and backups without committed identities are retained. Moving the tool/log root may make earlier provenance unavailable. Partial backup deletion requires inspection; rollback does not merge newer Target data.
- A flushed journal can still contain an incomplete final line after power loss. The application refuses destructive maintenance when recovery/ownership cannot be established rather than repairing the journal automatically.

For implementation boundaries, see [SECURITY.md](SECURITY.md). For normal operation, see [README.md](README.md).
