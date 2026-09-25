# Ownership and identity checks precede every destructive maintenance operation.
function Get-OfficialLogRoots {
    param([string]$ScriptDirectory)
    return @((Join-Path $ScriptDirectory 'MigrationLogs'),
        (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'JunctionUtility\Logs'),
        (Join-Path ([IO.Path]::GetTempPath()) 'JunctionUtility\Logs')) | ForEach-Object { ConvertTo-LocalPath $_ } | Select-Object -Unique
}
function Read-ManagedJson {
    param([string]$Path)
    Assert-PlainAncestors ([IO.Path]::GetDirectoryName($Path))
    $entry = Get-PathEntry $Path
    if ($null -eq $entry -or $entry.PSIsContainer -or (Test-ReparseEntry $entry) -or $entry.Length -gt 65536) { throw "Invalid ownership metadata: $Path" }
    return ([IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop)
}
function Write-NewManagedJson {
    param([string]$Path, $Value)
    Assert-PlainAncestors ([IO.Path]::GetDirectoryName($Path))
    $bytes = [Text.Encoding]::UTF8.GetBytes(($Value | ConvertTo-Json -Compress))
    $file = [IO.FileStream]::new($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
    try { $file.Write($bytes, 0, $bytes.Length); $file.Flush($true) } finally { $file.Dispose() }
}
function Assert-ManagedLogRoot {
    param([string]$Root, [string]$ScriptDirectory, [string[]]$ProtectedPaths = @())
    $canonical = ConvertTo-LocalPath $Root
    if ($canonical -notin @(Get-OfficialLogRoots $ScriptDirectory)) { throw 'Log cleanup is restricted to an official Junction Manager log root.' }
    Assert-ApplicationPath $canonical
    Assert-PlainAncestors $canonical
    foreach ($path in $ProtectedPaths) {
        if (-not [string]::IsNullOrWhiteSpace($path)) {
            $protected = ConvertTo-LocalPath $path
            if ((Test-PathWithin $canonical $protected) -or (Test-PathWithin $protected $canonical)) { throw "Log root overlaps Source, Target or Backup: $protected" }
        }
    }
    $marker = Read-ManagedJson (Join-Path $canonical '.junction-log-root.json')
    if ($marker.Manager -ne 'JunctionManager' -or $marker.Schema -ne 1 -or $marker.Path -ne $canonical -or $marker.RootId -notmatch '^[a-f0-9]{32}$') { throw 'Log root ownership marker does not match its location.' }
    return $marker
}
function New-ManagedLogSession {
    param([string]$Root, [string]$ScriptDirectory)
    $rootPath = ConvertTo-LocalPath $Root
    if ($rootPath -notin @(Get-OfficialLogRoots $ScriptDirectory)) { throw 'Not an official log location.' }
    Assert-PlainAncestors $rootPath
    [void][IO.Directory]::CreateDirectory($rootPath)
    $markerPath = Join-Path $rootPath '.junction-log-root.json'
    if ($null -eq (Get-PathEntry $markerPath)) {
        # Existing legacy sessions stay unowned; this marker only identifies the official root.
        Write-NewManagedJson $markerPath ([ordered]@{ Manager = 'JunctionManager'; Schema = 1; RootId = [Guid]::NewGuid().ToString('N'); Path = $rootPath })
    }
    $marker = Assert-ManagedLogRoot $rootPath $ScriptDirectory
    $sessionId = [Guid]::NewGuid().ToString('N')
    $session = Join-Path $rootPath ((Get-Date -Format 'yyyyMMdd_HHmmss') + '_' + $sessionId)
    if ($null -ne (Get-PathEntry $session)) { throw 'Log session already exists.' }
    [void][IO.Directory]::CreateDirectory($session)
    Write-NewManagedJson (Join-Path $session '.junction-log-session.json') ([ordered]@{
        Manager = 'JunctionManager'; Schema = 1; RootId = $marker.RootId; SessionId = $sessionId; Path = $session })
    $log = Join-Path $session 'Junction.log'
    [IO.File]::WriteAllText($log, '', [Text.Encoding]::UTF8)
    return [pscustomobject]@{ Root = $rootPath; RootId = $marker.RootId; Directory = $session; File = $log }
}
function Get-DirectoryIdentity {
    param([string]$Path)
    $canonical = ConvertTo-LocalPath $Path
    Assert-PlainAncestors $canonical
    if ($null -eq (Get-PathEntry $canonical)) { throw "Directory is unavailable: $canonical" }
    $volume = Get-FixedNtfsVolume $canonical
    $fsutil = Join-Path ([Environment]::GetFolderPath('System')) 'fsutil.exe'
    $output = @(& $fsutil file queryfileid $canonical 2>&1)
    $code = $LASTEXITCODE
    $match = [regex]::Match(($output -join ' '), '0x[0-9a-fA-F]{16,32}')
    if ($code -ne 0 -or -not $match.Success) { throw "Cannot establish NTFS directory identity: $canonical" }
    return ($volume.Id + '|' + $match.Value.ToLowerInvariant())
}
function Read-TransactionJournal {
    param([string]$Path, [string]$RootId)
    Assert-PlainAncestors ([IO.Path]::GetDirectoryName($Path))
    $entry = Get-PathEntry $Path
    if ($null -eq $entry -or $entry.PSIsContainer -or (Test-ReparseEntry $entry) -or $entry.Length -gt 4MB) { throw "Invalid journal: $Path" }
    $last = $null; $first = $null
    foreach ($line in [IO.File]::ReadLines($Path, [Text.Encoding]::UTF8)) {
        if (-not $line.Trim()) { continue }
        $row = $line | ConvertFrom-Json -ErrorAction Stop
        if ($row.Manager -ne 'JunctionManager' -or $row.Schema -ne 1 -or $row.RootId -ne $RootId -or $row.Id -notmatch '^[a-f0-9]{32}$') { throw 'Journal ownership is not established.' }
        if ($entry.Name -notin @("Transaction_$($row.Id).jsonl", "Rollback_$($row.Id).jsonl") -or $row.Journal -ne $Path) { throw 'Journal location/transaction identity mismatch.' }
        foreach ($field in @('Source','Backup')) { if ((ConvertTo-LocalPath $row.$field) -ne $row.$field) { throw 'Noncanonical journal path.' } }
        if ($row.Backup -ne ($row.Source + '_backup')) { throw 'Journal backup path mismatch.' }
        if ($row.Target -and (ConvertTo-LocalPath $row.Target) -ne $row.Target) { throw 'Noncanonical journal target.' }
        [void][DateTime]::Parse($row.UpdatedUtc, [Globalization.CultureInfo]::InvariantCulture)
        if ($null -ne $first -and ($row.Id -ne $first.Id -or $row.Source -ne $first.Source -or $row.Target -ne $first.Target -or $row.Backup -ne $first.Backup)) { throw 'Journal changed transaction identity.' }
        if ($null -eq $first) { $first = $row }
        $last = $row
    }
    if ($null -eq $last) { throw 'Empty journal; recovery state is unknown.' }
    return $last
}
function Get-ManagedLogSessions {
    param([string[]]$ProtectedPaths = @())
    $root = $script:Context.LogRoot
    $owner = Assert-ManagedLogRoot $root ([IO.Path]::GetDirectoryName($script:Context.ScriptPath)) $ProtectedPaths
    foreach ($directory in @(Get-ChildItem -LiteralPath $root -Force -ErrorAction Stop)) {
        if (-not $directory.PSIsContainer) { continue }
        $session = [pscustomobject]@{ Path = $directory.FullName; Eligible = $false; Reason = ''; Files = 0; Bytes = 0L
            Journals = @(); Corrupt = $false; Owned = $false }
        try {
            Assert-PlainAncestors $directory.FullName
            $marker = Read-ManagedJson (Join-Path $directory.FullName '.junction-log-session.json')
            if ($marker.Manager -ne 'JunctionManager' -or $marker.Schema -ne 1 -or $marker.RootId -ne $owner.RootId -or
                $marker.Path -ne $directory.FullName -or $marker.SessionId -notmatch '^[a-f0-9]{32}$' -or
                $directory.Name -notmatch ('^\d{8}_\d{6}_' + [regex]::Escape($marker.SessionId) + '$')) { throw 'Session ownership mismatch.' }
            $session.Owned = $true
            $journals = [Collections.Generic.List[object]]::new()
            $unknown = $false
            foreach ($entry in @(Get-ChildItem -LiteralPath $directory.FullName -Force -ErrorAction Stop)) {
                if ($entry.PSIsContainer -or (Test-ReparseEntry $entry)) { $unknown = $true; continue }
                if ($entry.Name -notmatch '^(\.junction-log-session\.json|Junction\.log|Robocopy_[a-f0-9]{32}\.log|(Transaction|Rollback)_[a-f0-9]{32}\.jsonl)$') { $unknown = $true; continue }
                $session.Files++; $session.Bytes += $entry.Length
                if ($entry.Extension -eq '.jsonl') {
                    try { $journals.Add((Read-TransactionJournal $entry.FullName $owner.RootId)) }
                    catch { $session.Corrupt = $true; $session.Reason = $_.Exception.Message }
                }
            }
            $session.Journals = $journals.ToArray()
            $session.Eligible = -not $unknown -and -not $session.Corrupt
            if ($unknown) { $session.Reason = 'Unknown files, subfolders or reparse points retained.' }
            foreach ($journal in $session.Journals) {
                if ($journal.Stage -notin @('RolledBack','RestoredAfterFailure','StoppedBeforeRename','BackupDeleted','Committed','CommittedWithLoggingError')) {
                    $session.Eligible = $false; $session.Reason = 'Active or unresolved recovery journal retained.'
                } elseif ($null -ne (Get-PathEntry $journal.Backup)) {
                    $session.Eligible = $false; $session.Reason = 'Backup still exists; provenance/recovery journal retained.'
                }
                foreach ($path in @($journal.Source,$journal.Target,$journal.Backup)) {
                    if ($path -and ((Test-PathWithin $root $path) -or (Test-PathWithin $path $root))) { $session.Eligible = $false; $session.Reason = 'Journal data path overlaps the log root.' }
                }
            }
            if ($directory.FullName -eq $script:Context.LogDirectory) { $session.Eligible = $false; $session.Reason = 'Current session retained.' }
        } catch { $session.Eligible = $false; $session.Reason = $_.Exception.Message }
        $session
    }
}
function Get-SourceManagedHistory {
    param([string]$Source)
    $sessions = @(Get-ManagedLogSessions)
    if (@($sessions | Where-Object Corrupt).Count) { throw 'A managed journal is damaged. Destructive backup maintenance is disabled until recovery information is reviewed.' }
    return @($sessions | ForEach-Object Journals | Where-Object { $_.Source -eq $Source } | Sort-Object { [DateTime]::Parse($_.UpdatedUtc).ToUniversalTime() })
}
function Assert-BackupNotPartiallyDeleted {
    param([string]$Source)
    if ($null -ne $script:Context -and $script:Context.ContainsKey('LogRoot')) {
        $records = @(Get-SourceManagedHistory $Source)
        if ($records.Count -and $records[-1].Stage -eq 'BackupDeletePending') { throw 'Backup deletion was interrupted. The remaining backup may be incomplete; rollback is disabled. Review the retained journal.' }
    }
}
function Get-PlainTreeDeletionPlan {
    param([string]$Root)
    $rootPath = ConvertTo-LocalPath $Root
    Assert-ApplicationPath $rootPath
    Assert-PlainAncestors $rootPath
    if ($null -eq (Get-PathEntry $rootPath)) { throw 'Deletion root does not exist.' }
    $files = [Collections.Generic.List[string]]::new()
    $directories = [Collections.Generic.List[string]]::new()
    $pending = [Collections.Generic.Stack[string]]::new(); $pending.Push($rootPath)
    [long]$bytes = 0
    while ($pending.Count) {
        $directory = $pending.Pop()
        Assert-PlainAncestors $directory
        $directories.Add($directory)
        foreach ($entry in @(Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop)) {
            $path = ConvertTo-LocalPath $entry.FullName
            if (-not (Test-PathWithin $path $rootPath) -or $path -eq $rootPath) { throw 'Deletion escaped its verified root.' }
            if (Test-ReparseEntry $entry) { throw "Deletion refused: reparse point inside the tree: $path" }
            if ($entry.PSIsContainer) { $pending.Push($path) } else { $files.Add($path); $bytes += $entry.Length }
        }
    }
    return [pscustomobject]@{ Root = $rootPath; Files = $files.ToArray(); Directories = @($directories | Sort-Object Length -Descending); Bytes = $bytes }
}
function Remove-PlainTreeFromPlan {
    param($Plan, [scriptblock]$VerifyOwnership)
    # Callers supply exact backup/session provenance. No recursive deletion API is used.
    & $VerifyOwnership
    $rootMarkers = @($Plan.Files | Where-Object { [IO.Path]::GetDirectoryName($_) -eq $Plan.Root -and [IO.Path]::GetFileName($_).StartsWith('.junction-', [StringComparison]::OrdinalIgnoreCase) })
    $deleteFile = {
        param([string]$path)
        if (-not (Test-PathWithin $path $Plan.Root) -or $path -eq $Plan.Root) { throw 'File deletion escaped its root.' }
        Assert-PlainAncestors ([IO.Path]::GetDirectoryName($path))
        $entry = Get-PathEntry $path
        if ($null -eq $entry -or $entry.PSIsContainer -or (Test-ReparseEntry $entry)) { throw "File identity/type changed during deletion: $path" }
        # Only clear a read-only bit on a verified in-scope file, never ACL/ownership.
        if ($entry.Attributes -band [IO.FileAttributes]::ReadOnly) { [IO.File]::SetAttributes($path, ($entry.Attributes -band (-bnot [IO.FileAttributes]::ReadOnly))) }
        [IO.File]::Delete($path)
    }
    foreach ($path in $Plan.Files) { if ($path -notin $rootMarkers) { & $deleteFile $path } }
    foreach ($path in $Plan.Directories) {
        if ($path -eq $Plan.Root) { continue }
        if (-not (Test-PathWithin $path $Plan.Root)) { throw 'Directory deletion escaped its root.' }
        Assert-PlainAncestors $path
        [IO.Directory]::Delete($path, $false)
    }
    # Keep root ownership evidence until child deletion has succeeded.
    & $VerifyOwnership
    foreach ($path in $rootMarkers) { & $deleteFile $path }
    Assert-PlainAncestors $Plan.Root
    [IO.Directory]::Delete($Plan.Root, $false)
    if ($null -ne (Get-PathEntry $Plan.Root)) { throw "Deletion incomplete: $($Plan.Root)" }
}
function Get-ManagedBackup {
    param([string]$Source, [string]$Target)
    $sourcePath = ConvertTo-LocalPath $Source; $targetPath = ConvertTo-LocalPath $Target
    Assert-ApplicationPath $sourcePath; Assert-ApplicationPath $targetPath
    $backup = ConvertTo-LocalPath ($sourcePath + '_backup')
    Assert-ApplicationPath $backup; Assert-PlainAncestors $backup
    Assert-Junction $sourcePath $targetPath
    foreach ($pair in @(@($sourcePath,$targetPath), @($backup,$targetPath), @($backup,$sourcePath))) {
        if ((Test-PathWithin $pair[0] $pair[1]) -or (Test-PathWithin $pair[1] $pair[0])) { throw 'Backup/source/target overlap.' }
    }
    foreach ($artifact in @($script:Context.ScriptPath, $script:Context.LogRoot)) {
        if ((Test-PathWithin $artifact $backup) -or (Test-PathWithin $backup $artifact)) { throw 'Backup overlaps tool files/logs.' }
    }
    $records = @(Get-SourceManagedHistory $sourcePath)
    if (-not $records.Count) { throw 'No owned committed transaction proves this backup belongs to Junction Manager.' }
    $record = $records[-1]
    if ($record.Stage -ne 'Committed' -or $record.Source -ne $sourcePath -or $record.Target -ne $targetPath -or $record.Backup -ne $backup) { throw 'Latest journal is not a matching committed migration.' }
    $backupIdentity = Get-DirectoryIdentity $backup
    $targetIdentity = Get-DirectoryIdentity $targetPath
    if (-not $record.BackupIdentity -or $backupIdentity -ne $record.BackupIdentity -or $targetIdentity -ne $record.TargetIdentity) { throw 'Backup/Target NTFS identity differs from the committed transaction.' }
    $plan = Get-PlainTreeDeletionPlan $backup
    return [pscustomobject]@{ Source = $sourcePath; Target = $targetPath; Backup = $backup; Bytes = $plan.Bytes
        BackupIdentity = $backupIdentity; TargetIdentity = $targetIdentity; Journal = $record; Plan = $plan }
}
function Remove-ManagedBackup {
    param([string]$Source, [string]$Target)
    if ($script:Context.ContainsKey('ActiveOperation') -and $script:Context.ActiveOperation -in @('Move','Rollback')) { throw 'Maintenance cannot run during a migration/rollback transaction.' }
    $managed = Get-ManagedBackup $Source $Target
    $message = "DELETE BACKUP PERMANENTLY`r`n`r`nSource Junction: $($managed.Source)`r`nTarget: $($managed.Target)`r`nBackup to delete: $($managed.Backup)`r`nApproximate size: $('{0:N2}' -f ($managed.Bytes / 1GB)) GiB`r`n`r`nThis removes the retained pre-migration copy. Current data in Target and the Junction remain unchanged. Normal rollback will no longer be available. Test the app first.`r`n`r`nPermanently delete this exact backup?"
    if (-not (Request-OperationConfirmation $message -ConfirmLabel 'Delete Backup')) { Set-OperationStage 'Delete Backup cancelled.'; return }
    $fresh = Get-ManagedBackup $Source $Target
    if ($fresh.BackupIdentity -ne $managed.BackupIdentity -or $fresh.TargetIdentity -ne $managed.TargetIdentity -or $fresh.Journal.Id -ne $managed.Journal.Id) { throw 'Backup identity changed while confirmation was open.' }
    if (@(Get-RelatedProcesses @($fresh.Backup)).Count) { throw 'A process is running from the backup. Close it before deleting the backup.' }
    $transaction = [ordered]@{}
    foreach ($property in $fresh.Journal.PSObject.Properties) { $transaction[$property.Name] = $property.Value }
    Write-OperationLog "Backup verification passed. Deleting retained backup: $($fresh.Backup)" 'WARN'
    Save-TransactionState $transaction 'BackupDeletePending'
    try {
        Remove-PlainTreeFromPlan $fresh.Plan {
            Assert-Junction $fresh.Source $fresh.Target
            if ((Get-DirectoryIdentity $fresh.Backup) -ne $fresh.BackupIdentity -or (Get-DirectoryIdentity $fresh.Target) -ne $fresh.TargetIdentity) { throw 'Directory identity changed before deletion.' }
        }
        Assert-Junction $fresh.Source $fresh.Target
        Save-TransactionState $transaction 'BackupDeleted'
        Set-OperationStage 'Backup removed successfully. Target and Junction retained; normal rollback is no longer available.'
    } catch {
        throw "Backup deletion incomplete or completion could not be recorded: $($_.Exception.Message)`r`nInspect: $($fresh.Backup)`r`nJournal retained: $($transaction.Journal). The remaining backup must not be used for normal rollback."
    }
}
function Clear-ManagedLogs {
    param([string]$Source = '', [string]$Target = '')
    if ($script:Context.ContainsKey('ActiveOperation') -and $script:Context.ActiveOperation -in @('Move','Rollback')) { throw 'Maintenance cannot run during a migration/rollback transaction.' }
    $protected = @($Source, $Target)
    if ($Source) { $protected += ((ConvertTo-LocalPath $Source) + '_backup') }
    $sessions = @(Get-ManagedLogSessions $protected)
    $eligible = @($sessions | Where-Object Eligible)
    $retained = @($sessions | Where-Object { -not $_.Eligible })
    $bytes = 0L; $files = 0
    foreach ($session in $eligible) { $bytes += $session.Bytes; $files += $session.Files }
    Write-OperationLog "Clear Logs requested. $($eligible.Count) completed sessions eligible; $($retained.Count) current/unknown/recovery sessions retained."
    if (-not $eligible.Count) { Set-OperationStage 'No disposable historical log sessions. Current, legacy and recovery information retained.'; return }
    if (-not (Request-OperationConfirmation "Delete Junction Manager logs?`r`nRoot: $($script:Context.LogRoot)`r`nCompleted sessions: $($eligible.Count)`r`nFiles: $files`r`nApproximate size: $('{0:N2}' -f ($bytes / 1MB)) MiB`r`n`r`nCurrent/recovery and unowned logs will be retained. Delete these historical sessions?")) { Set-OperationStage 'Clear Logs cancelled.'; return }
    $failures = [Collections.Generic.List[string]]::new(); $deleted = 0
    foreach ($session in $eligible) {
        try {
            $current = @(Get-ManagedLogSessions $protected | Where-Object { $_.Path -eq $session.Path -and $_.Eligible })
            if ($current.Count -ne 1) { throw 'Session is no longer eligible.' }
            $plan = Get-PlainTreeDeletionPlan $session.Path
            Remove-PlainTreeFromPlan $plan {
                if (@(Get-ManagedLogSessions $protected | Where-Object { $_.Path -eq $session.Path -and $_.Eligible }).Count -ne 1) { throw 'Session ownership/state changed.' }
            }
            $deleted++
        } catch { $failures.Add("$($session.Path): $($_.Exception.Message)") }
    }
    Write-OperationLog "Deleted $deleted completed log sessions. $($retained.Count) current/unknown/recovery sessions retained."
    if ($failures.Count) { throw ("Cleanup incomplete. Remaining sessions:`r`n" + ($failures -join "`r`n")) }
    Set-OperationStage "Clear Logs completed: $deleted historical sessions removed; recovery/current information retained."
}
