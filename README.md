# Junction Manager

Version: **V1.0.0**

Author: **Nemoforge (DINH DUC LOC)**

Support: [nemoforge.github.io](https://nemoforge.github.io) | support@studyhelp.space

Windows PowerShell 5.1 + WPF utility to discover application folders, move a folder between local NTFS volumes, retain a backup, and create a verified junction at the original location.

## Run

Download the complete source project, extract it, and run `script.bat`, or:

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\Junction.ps1
```

Keep `Junction.ps1`, `Junction.Discovery.ps1`, `Junction.Maintenance.ps1` and `Junction.Update.ps1` together. The application requests Administrator access. No external modules or installer are required.

Choose Source and Target, run **Analyze**, and review the confirmation before **Move**. Close the application being moved, including its updater/services. Copy verification includes SHA-256 and alternate data streams; the original backup remains until you explicitly delete it. **Rollback** restores that older copy without merging later changes from Target.

App Discovery only reads information. Clear Logs retains recovery journals. Delete Backup requires managed transaction provenance, matching NTFS identities and a verified junction. See [TESTING.md](TESTING.md) for safety limits, test results and manual checks.

## Check for Updates

Open **About → Check for Updates**. Junction Manager does not update itself automatically. Checks occur only when requested by the user. If a newer version is available, **Open Download Page** opens the official page in the default browser after another click. Installation is manual.

The update checker reads public JSON using HTTPS, with an 8-second request timeout, a 16 KiB response limit and no retries or redirects. It sends no application telemetry, credentials, cookies, Source/Target paths or logs. Normal HTTPS certificate validation remains enabled. The server will still see ordinary network information such as the request IP address.

Remote notes are plain text. Versions use three numeric components with an optional `V`/`v` prefix; prerelease/build suffixes are not supported. Older published versions never offer a downgrade. HTTPS page links are limited to `nemoforge.github.io` and this repository's GitHub repository/release pages. Direct release assets, other repositories, credentials, query strings and fragments are rejected.

The checker never downloads a release, runs remote code, replaces local files, schedules checks or contacts the network at startup. A network or metadata error is non-fatal and preserves the existing migration analysis.

## Publish update metadata

`$script:AppInfo` in `Junction.ps1` is the source of truth for application metadata. `UpdateMetadataUrl` points to the public endpoint below, published and verified using the production metadata GET. Set it to an empty string to disable requests and display a setup message.

The included `version.json` is published at the root of the `main` branch in this repository. Its public URL is:

```text
https://raw.githubusercontent.com/nemoforge/Junction-Manager/main/version.json
```

If changing the endpoint, publish and verify valid public JSON before changing the single `AppInfo.UpdateMetadataUrl` value. Metadata HTTPS hosts are limited to the author's website and raw JSON under this repository. This uses static JSON, not the GitHub API or HTML scraping.

The initial metadata is:

```json
{
  "product": "Junction Manager",
  "version": "V1.0.0",
  "downloadUrl": "https://github.com/nemoforge/Junction-Manager",
  "notes": "Initial source release. Download the complete project and keep all Junction.*.ps1 files together. Updates are installed manually."
}
```

For a future release, publish the complete source/release page first, then update `version`, `downloadUrl` and `notes`. An optional `releaseNotesUrl` can point to this repository's HTTPS release/tag page. `product` is optional but must match when present; `version` is required and limited to 32 characters; `notes` is limited to 2,000 characters; each URL is limited to 2,048 characters. Keep the published metadata version aligned with the released application's `AppInfo.Version`.

## Tests and source package

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\tests\Smoke.ps1
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\tests\Features.ps1
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\tests\Updates.ps1
```

Automated update tests run offline with owned JSON fixtures and simulated transport errors. Test mutations remain under `.test-sandbox\<GUID>` and are cleaned in `finally`; the parent is removed only when empty. Runtime `MigrationLogs` is created when the application runs. Both directories are excluded from Git and should be excluded from a distributed source package. Keep source files, tests and documentation.
