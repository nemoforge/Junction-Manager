#Requires -Version 5.1
<#
Windows PowerShell 5.1 / WPF. Run directly or use script.bat.
Dot-source with -LibraryOnly to load functions without elevation or a window.
Maintenance deletes only owned, verified trees without recursive deletion APIs.
#>
[CmdletBinding()]
param([switch]$LibraryOnly)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:Context = $null
$script:AppInfo = [pscustomobject]@{
    Name = 'Junction Manager'
    Author = 'Nemoforge (DINH DUC LOC)'
    Version = 'V1.0.0'
    Website = 'nemoforge.github.io'
    SupportEmail = 'support@studyhelp.space'
    RepositoryUrl = 'https://github.com/nemoforge/Junction-Manager'
    # Public JSON published in the repository and verified with the production GET.
    UpdateMetadataUrl = 'https://raw.githubusercontent.com/nemoforge/Junction-Manager/main/version.json'
}

function Write-OperationLog {
    param([string]$Message, [ValidateSet('INFO','WARN','ERROR')][string]$Level = 'INFO')
    $line = '[{0}] {1} {2}' -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message
    if ($null -ne $script:Context) {
        $script:Context.Queue.Enqueue([pscustomobject]@{ Kind = 'Log'; Text = $line })
        if (-not ($script:Context.ContainsKey('ReadOnlyOperation') -and $script:Context.ReadOnlyOperation)) {
            [IO.File]::AppendAllText($script:Context.LogFile, $line + [Environment]::NewLine, [Text.Encoding]::UTF8)
        }
    } else { Write-Verbose $line }
}
function Set-OperationStage {
    param([string]$Text)
    Write-OperationLog $Text
    if ($null -ne $script:Context) { $script:Context.Queue.Enqueue([pscustomobject]@{ Kind = 'Status'; Text = $Text }) }
}
function Request-OperationConfirmation {
    param([string]$Text, [string]$ConfirmLabel = '')
    if ($null -eq $script:Context) { throw 'Interactive confirmation is required.' }
    $script:Context.Answer = $null
    $script:Context.Queue.Enqueue([pscustomobject]@{ Kind = 'Confirm'; Text = $Text; Label = $ConfirmLabel })
    while ($null -eq $script:Context.Answer) { Start-Sleep -Milliseconds 100 }
    return [bool]$script:Context.Answer
}
function ConvertTo-LocalPath {
    param([Parameter(Mandatory)][string]$Path)
    $value = $Path.Trim().Replace('/', '\')
    if ($value.Length -lt 3 -or $value[1] -ne ':' -or $value[2] -ne '\' -or -not [char]::IsLetter($value[0])) {
        throw 'Use an absolute local path, for example D:\Apps\MyApp. UNC and device paths are not supported.'
    }
    foreach ($part in $value.Substring(3).Split('\', [StringSplitOptions]::RemoveEmptyEntries)) {
        if ($part -eq '.' -or $part -eq '..') { continue }
        if ($part.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0 -or $part.EndsWith('.') -or $part.EndsWith(' ') -or $part.Contains('~')) {
            throw "Unsupported path component '$part'. Use full folder names without short (8.3) aliases or trailing dots/spaces."
        }
        $stem = $part.Split('.')[0].ToUpperInvariant()
        if ($stem -in @('CON','PRN','AUX','NUL','CONIN$','CONOUT$') -or $stem -match '^(COM|LPT)[0-9¹²³]$') { throw "Reserved Windows name: $part" }
    }
    $full = [IO.Path]::GetFullPath($value)
    if ($full.Length -gt 3) { $full = $full.TrimEnd('\') }
    if ($full.Length -gt 240) { throw 'Paths longer than 240 characters are not supported by this PowerShell 5.1 utility.' }
    return $full
}
function Test-PathWithin {
    param([string]$Path, [string]$Parent)
    return $Path.Equals($Parent, [StringComparison]::OrdinalIgnoreCase) -or $Path.StartsWith($Parent.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)
}
function Get-PathEntry {
    param([string]$Path)
    # Get-Item also sees dangling junctions; only a genuinely missing entry is ignored.
    try { return Get-Item -LiteralPath $Path -Force -ErrorAction Stop }
    catch [System.Management.Automation.ItemNotFoundException] { return $null }
}
function Test-ReparseEntry {
    param($Entry)
    return ($Entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
}
function Assert-PlainAncestors {
    param([string]$Path, [switch]$AllowLeafReparse)
    $cursor = $Path
    while ($cursor) {
        $entry = Get-PathEntry $cursor
        if ($null -ne $entry) {
            if (-not $entry.PSIsContainer) { throw "A path component is a file: $cursor" }
            if ((Test-ReparseEntry $entry) -and -not ($AllowLeafReparse -and $cursor -eq $Path)) { throw "Reparse points in path components are not supported: $cursor" }
        }
        $cursor = [IO.Path]::GetDirectoryName($cursor)
    }
}
function Get-FixedNtfsVolume {
    param([string]$Path)
    $letter = [IO.Path]::GetPathRoot($Path).Substring(0,2)
    $drive = [IO.DriveInfo]::new($letter)
    if (-not $drive.IsReady -or $drive.DriveType -ne [IO.DriveType]::Fixed) { throw "Drive $letter must be an available local fixed drive." }
    # Unlike DriveInfo alone, this rejects SUBST aliases and mapped drives.
    $volumes = @(Get-CimInstance -ClassName Win32_Volume -Filter "DriveLetter = '$letter'" -ErrorAction Stop)
    if ($volumes.Count -ne 1 -or $volumes[0].DriveType -ne 3 -or $volumes[0].FileSystem -ne 'NTFS') {
        throw "Drive $letter must be a directly mounted NTFS volume (no SUBST, network or removable drives)."
    }
    return [pscustomobject]@{ Letter = $letter; FileSystem = $drive.DriveFormat; Free = $drive.AvailableFreeSpace
        Id = $volumes[0].DeviceID; AllocationUnit = [Math]::Max(65536L, [long]$volumes[0].BlockSize) }
}
function Assert-ApplicationPath {
    param([string]$Path)
    if ($Path.Length -eq 3) { throw 'A drive root cannot be moved or used as Target.' }
    $windows = [Environment]::GetFolderPath('Windows')
    if (Test-PathWithin $Path $windows) { throw 'Windows system folders cannot be moved or used as Target.' }
    foreach ($programRoot in @([Environment]::GetFolderPath('ProgramFiles'), [Environment]::GetFolderPath('ProgramFilesX86'))) {
        if ($programRoot -and (Test-PathWithin $Path (Join-Path $programRoot 'WindowsApps'))) { throw 'Packaged/MSIX folders are not supported for migration.' }
    }
    $protected = @($windows, [Environment]::GetFolderPath('UserProfile'), [Environment]::GetFolderPath('ProgramFiles'),
        [Environment]::GetFolderPath('ProgramFilesX86'), [Environment]::GetFolderPath('CommonApplicationData'),
        [Environment]::GetFolderPath('LocalApplicationData'), [Environment]::GetFolderPath('ApplicationData'), (Join-Path $env:SystemDrive 'Users'))
    foreach ($folder in $protected) {
        if ($folder -and (Test-PathWithin $folder $Path)) { throw "Choose an individual application folder, not a system/profile container: $Path" }
    }
    if ($Path.Substring(3).Split('\')[0] -in @('System Volume Information', '$Recycle.Bin', 'Recovery', 'Boot', 'WindowsApps', 'MSOCache')) { throw "Protected volume folder: $Path" }
}
function Get-TreeSnapshot {
    param([string]$Root, [switch]$Hash, [string[]]$ProjectedRoots = @())
    Assert-PlainAncestors $Root
    $rootEntry = Get-PathEntry $Root
    if ($null -eq $rootEntry) { throw "Folder is unavailable: $Root" }
    if (($rootEntry.Attributes -band ([IO.FileAttributes]::Encrypted -bor [IO.FileAttributes]::Offline)) -ne 0) { throw "Encrypted or offline folder is not supported: $Root" }
    $records = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::OrdinalIgnoreCase)
    $pending = [Collections.Generic.Stack[string]]::new()
    $pending.Push($Root)
    [long]$bytes = 0; [long]$files = 0; [long]$directories = 0; [long]$streams = 0
    $heartbeat = [Diagnostics.Stopwatch]::StartNew()
    while ($pending.Count -gt 0) {
        $directory = $pending.Pop()
        Assert-PlainAncestors $directory
        foreach ($entry in @(Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop)) {
            $relative = $entry.FullName.Substring($Root.Length + 1)
            foreach ($base in @($Root) + $ProjectedRoots) { [void](ConvertTo-LocalPath ($base + '\' + $relative)) }
            if (Test-ReparseEntry $entry) { throw "Source/Target contains a reparse point. Nothing will be silently skipped: $($entry.FullName)" }
            if (($entry.Attributes -band ([IO.FileAttributes]::Encrypted -bor [IO.FileAttributes]::Offline)) -ne 0) { throw "Encrypted or offline content is not supported: $($entry.FullName)" }
            if ($records.ContainsKey($relative)) { throw "Case-sensitive name collision is not supported: $relative" }
            if ($entry.PSIsContainer) {
                $directories++; $records.Add($relative, 'D'); $pending.Push($entry.FullName)
            } else {
                $files++
                $parts = [Collections.Generic.List[string]]::new()
                $beforeLength = $entry.Length; $beforeTime = $entry.LastWriteTimeUtc.Ticks
                foreach ($stream in @(Get-Item -LiteralPath $entry.FullName -Stream '*' -Force -ErrorAction Stop | Sort-Object Stream)) {
                    $bytes += $stream.Length
                    $streams++
                    $digest = ''
                    if ($Hash) {
                        $streamPath = $entry.FullName
                        if ($stream.Stream -ne ':$DATA') { $streamPath += ':' + $stream.Stream }
                        $handle = $null
                        $sha = [Security.Cryptography.SHA256]::Create()
                        try {
                            # Deny writers/deletion while reading each stream. This is not a VSS snapshot.
                            if ($stream.Stream -eq ':$DATA') {
                                $handle = [IO.File]::Open($streamPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
                                $digest = [BitConverter]::ToString($sha.ComputeHash($handle)).Replace('-', '')
                            } else {
                                # .NET Framework File.Open rejects ADS syntax. The filesystem provider
                                # reads named streams in bounded chunks, without loading a whole stream.
                                Get-Content -LiteralPath $entry.FullName -Stream $stream.Stream -Encoding Byte -ReadCount 65536 -Force -ErrorAction Stop | ForEach-Object {
                                    $chunk = [byte[]]$_
                                    [void]$sha.TransformBlock($chunk, 0, $chunk.Length, $chunk, 0)
                                }
                                [void]$sha.TransformFinalBlock([byte[]]@(), 0, 0)
                                $digest = [BitConverter]::ToString($sha.Hash).Replace('-', '')
                            }
                        } finally {
                            if ($null -ne $handle) { $handle.Dispose() }
                            $sha.Dispose()
                        }
                    }
                    $parts.Add(('{0}:{1}:{2}' -f $stream.Stream, $stream.Length, $digest))
                }
                $entry.Refresh()
                if (-not $entry.Exists -or $entry.Length -ne $beforeLength -or $entry.LastWriteTimeUtc.Ticks -ne $beforeTime) { throw "File changed during verification. Close the application and retry: $($entry.FullName)" }
                $records.Add($relative, ('F|{0}|{1}|{2}' -f $beforeLength, $beforeTime, ($parts -join '|')))
            }
            if ($heartbeat.Elapsed.TotalSeconds -ge 3) {
                Set-OperationStage ("Scanning {0}: {1:N0} files, {2:N2} GiB{3}" -f $Root, $files, ($bytes / 1GB), $(if ($Hash) { ', SHA-256' } else { '' }))
                $heartbeat.Restart()
            }
        }
    }
    return [pscustomobject]@{ Records = $records; Bytes = $bytes; Files = $files; Directories = $directories; Streams = $streams }
}
function Assert-SnapshotsEqual {
    param($Expected, $Actual)
    if ($Expected.Records.Count -ne $Actual.Records.Count) { throw 'Verification failed: different file/directory counts. Both copies have been retained.' }
    foreach ($name in $Expected.Records.Keys) {
        if (-not $Actual.Records.ContainsKey($name) -or $Expected.Records[$name] -cne $Actual.Records[$name]) { throw "Verification failed: missing, changed or mismatched content: $name. Both copies have been retained." }
    }
}
function Get-JunctionDestination {
    param([string]$Source)
    $entry = Get-PathEntry $Source
    if ($null -eq $entry -or -not $entry.PSIsContainer -or -not (Test-ReparseEntry $entry) -or $entry.LinkType -ne 'Junction') { throw "Expected a directory junction at: $Source" }
    $targets = @($entry.Target)
    if ($targets.Count -ne 1 -or [string]::IsNullOrWhiteSpace($targets[0])) { throw "Cannot read the junction destination: $Source" }
    return ConvertTo-LocalPath $targets[0]
}
function Assert-Junction {
    param([string]$Source, [string]$Target, [switch]$AllowUnavailableTarget)
    Assert-PlainAncestors $Source -AllowLeafReparse
    $actual = Get-JunctionDestination $Source
    if (-not $actual.Equals($Target, [StringComparison]::OrdinalIgnoreCase)) { throw "Junction points to '$actual', expected '$Target'." }
    if (-not $AllowUnavailableTarget) {
        Assert-PlainAncestors $Target
        if ($null -eq (Get-PathEntry $Target) -or -not [IO.Directory]::Exists($Source)) { throw 'Junction target is unavailable.' }
    }
}
function Remove-JunctionOnly {
    param([string]$Source, [string]$Target)
    # Never substitute Remove-Item -Recurse here, even on newer PowerShell.
    Assert-Junction $Source $Target -AllowUnavailableTarget
    [IO.Directory]::Delete($Source, $false)
    if ($null -ne (Get-PathEntry $Source)) { throw "Junction was not removed: $Source" }
}
function Get-RecoveryInfo {
    param([string]$Source)
    $sourcePath = ConvertTo-LocalPath $Source
    Assert-ApplicationPath $sourcePath
    Assert-PlainAncestors $sourcePath -AllowLeafReparse
    [void](Get-FixedNtfsVolume $sourcePath)
    $backup = ConvertTo-LocalPath ($sourcePath + '_backup')
    Assert-PlainAncestors $backup
    if ($null -eq (Get-PathEntry $backup)) { throw "No backup exists at: $backup" }
    Assert-BackupNotPartiallyDeleted $sourcePath
    $sourceEntry = Get-PathEntry $sourcePath
    $target = ''
    if ($null -ne $sourceEntry) {
        $target = Get-JunctionDestination $sourcePath
        if ((Test-PathWithin $target $sourcePath) -or (Test-PathWithin $sourcePath $target) -or (Test-PathWithin $target $backup) -or (Test-PathWithin $backup $target)) { throw 'Unsafe or overlapping junction destination.' }
    }
    return [pscustomobject]@{ Source = $sourcePath; Backup = $backup; Target = $target; MissingSource = ($null -eq $sourceEntry) }
}
function Get-MoveAnalysis {
    param([string]$Source, [string]$Target)
    $errors = [Collections.Generic.List[string]]::new()
    $warnings = [Collections.Generic.List[string]]::new()
    $result = [pscustomobject]@{
        Source = $Source; Target = $Target; Backup = ''; Size = $null; Files = $null
        TargetDrive = ''; FileSystem = ''; Free = $null; Required = $null
        SourceReparse = $null; TargetExists = $null; Valid = $false
        Errors = $errors; Warnings = $warnings; Recovery = $null; ManagedBackup = $null; BackupDeletionReason = ''
    }
    $entry = $null; $volume = $null
    try {
        $result.Source = ConvertTo-LocalPath $Source
        $result.Backup = ConvertTo-LocalPath ($result.Source + '_backup')
        $entry = Get-PathEntry $result.Source
        if ($null -ne $entry) { $result.SourceReparse = Test-ReparseEntry $entry }
        try { $result.Recovery = Get-RecoveryInfo $result.Source }
        catch { $warnings.Add('Rollback unavailable: ' + $_.Exception.Message) }
    } catch { $errors.Add($_.Exception.Message) }
    try {
        $result.Target = ConvertTo-LocalPath $Target
        $volume = Get-FixedNtfsVolume $result.Target
        $result.TargetDrive = $volume.Letter; $result.FileSystem = $volume.FileSystem; $result.Free = $volume.Free
        $result.TargetExists = $null -ne (Get-PathEntry $result.Target)
    } catch { $errors.Add($_.Exception.Message) }
    if ($result.SourceReparse -and $null -ne $script:Context -and $script:Context.ContainsKey('LogRoot')) {
        try { $result.ManagedBackup = Get-ManagedBackup $result.Source $result.Target }
        catch { $result.BackupDeletionReason = $_.Exception.Message }
    }
    try {
        if ($errors.Count) { throw 'Correct the path/drive errors before validation can continue.' }
        Assert-ApplicationPath $result.Source
        Assert-ApplicationPath $result.Target
        Assert-PlainAncestors $result.Source
        Assert-PlainAncestors $result.Target
        if ((Test-PathWithin $result.Source $result.Target) -or (Test-PathWithin $result.Target $result.Source)) { throw 'Source and Target must be different, non-overlapping folders.' }
        if ((Test-PathWithin $result.Backup $result.Target) -or (Test-PathWithin $result.Target $result.Backup)) { throw 'Target must not overlap the backup path.' }
        $sourceVolume = Get-FixedNtfsVolume $result.Source
        if ($sourceVolume.Id -eq $volume.Id) { throw 'Choose a Target on another NTFS volume.' }
        if ($null -eq $entry) { throw 'Source folder does not exist.' }
        if (-not $entry.PSIsContainer) { throw 'Source is a file; choose a folder.' }
        if ($result.SourceReparse) { throw 'Source is already a reparse point. Analyze/Rollback are available; Move is blocked.' }
        if ($null -ne $script:Context) {
            if ($script:Context.ContainsKey('LogRoot')) {
                foreach ($dataPath in @($result.Source, $result.Target, $result.Backup)) {
                    if ((Test-PathWithin $dataPath $script:Context.LogRoot) -or (Test-PathWithin $script:Context.LogRoot $dataPath)) { throw 'Migration data must not overlap the managed log root.' }
                }
            }
            foreach ($artifact in @($script:Context.ScriptPath, $script:Context.LogFile)) {
                if ((Test-PathWithin $artifact $result.Source) -or (Test-PathWithin $artifact $result.Target)) { throw 'The script/logs must be outside Source and Target.' }
            }
        }
        if ($result.TargetExists -and @(Get-ChildItem -LiteralPath $result.Target -Force -ErrorAction Stop | Select-Object -First 1).Count) { $errors.Add('Target folder already contains files. To avoid mixing old and new data, choose an empty folder.') }
        if ($null -ne (Get-PathEntry $result.Backup)) { $errors.Add('The backup path already exists. It will never be overwritten.') }
        Set-OperationStage 'Calculating source size and checking all entries...'
        $snapshot = Get-TreeSnapshot $result.Source -ProjectedRoots @($result.Target, $result.Backup)
        $result.Size = $snapshot.Bytes; $result.Files = $snapshot.Files
        $result.Required = [long]($snapshot.Bytes + (($snapshot.Files + $snapshot.Streams + $snapshot.Directories + 1) * $volume.AllocationUnit) + [Math]::Max(64MB, $snapshot.Bytes * 0.05))
        if ($result.Free -lt $result.Required) { throw 'Target has insufficient free space (including allocation overhead and safety reserve).' }
        $warnings.Add('Close the app, its updater and related services. Executable-path detection cannot find every file lock or writer.')
        $warnings.Add('Analyze is read-only. Permission to create Target is finally checked during Move, before Source is renamed.')
        $warnings.Add('Backup stays on the original drive until you explicitly delete it after testing the app.')
        $result.Valid = $errors.Count -eq 0
    } catch { $errors.Add($_.Exception.Message) }
    return $result
}
function Format-Analysis {
    param($Analysis)
    $size = if ($null -eq $Analysis.Size) { 'Unavailable (see validation messages)' } else { '{0:N2} GiB / {1:N0} bytes; {2:N0} files' -f ($Analysis.Size / 1GB), $Analysis.Size, $Analysis.Files }
    $free = if ($null -eq $Analysis.Free) { 'Unavailable' } else { '{0:N2} GiB' -f ($Analysis.Free / 1GB) }
    $text = "Source: $($Analysis.Source)`r`nTarget: $($Analysis.Target)`r`nBackup: $($Analysis.Backup)`r`nSize: $size`r`nTarget drive: $($Analysis.TargetDrive)  Filesystem: $($Analysis.FileSystem)`r`nFree: $free`r`nSource ReparsePoint: $($Analysis.SourceReparse)`r`nTarget exists: $($Analysis.TargetExists)"
    foreach ($message in $Analysis.Errors) { $text += "`r`nERROR: $message" }
    foreach ($message in $Analysis.Warnings) { $text += "`r`nWARNING: $message" }
    if ($null -ne $Analysis.Recovery) { $text += "`r`nRollback is available. It restores the backup and keeps Target." }
    if ($null -ne $Analysis.ManagedBackup) { $text += "`r`nDelete Backup is available after you have tested the app. It permanently disables normal rollback." }
    elseif ($Analysis.BackupDeletionReason) { $text += "`r`nDelete Backup unavailable: $($Analysis.BackupDeletionReason)" }
    return $text
}

function Get-RelatedProcesses {
    param([string[]]$Roots)
    $unreadable = 0
    foreach ($process in @(Get-Process -ErrorAction Stop)) {
        try {
            $path = $process.Path
            if (-not $path) { $unreadable++; continue }
            foreach ($root in $Roots) {
                if ($root -and (Test-PathWithin $path $root)) {
                    [pscustomobject]@{ Id = $process.Id; Name = $process.ProcessName; Path = $path
                        StartTicks = $process.StartTime.ToUniversalTime().Ticks
                        Protected = ($process.Id -eq $PID -or $process.SessionId -eq 0 -or
                            (Test-PathWithin $path ([Environment]::GetFolderPath('Windows'))) -or
                            $process.ProcessName -in @('System','Registry','Idle','smss','csrss','wininit','services','lsass','winlogon','svchost','dwm','fontdrvhost')) }
                    break
                }
            }
        } catch {
            $unreadable++
            Write-Verbose ("Process inspection failed for PID {0}: {1}" -f $process.Id, $_.Exception.Message)
        } finally { $process.Dispose() }
    }
    if ($unreadable) { Write-OperationLog "$unreadable processes could not be fully inspected. This scan is not a file-lock detector." 'WARN' }
}
function Get-MatchingProcess {
    param($Identity)
    try { $process = Get-Process -Id $Identity.Id -ErrorAction Stop }
    catch [Microsoft.PowerShell.Commands.ProcessCommandException] { return $null }
    # Cache a native handle before checking identity, so Kill cannot reopen a reused PID.
    [void]$process.Handle
    if ($process.StartTime.ToUniversalTime().Ticks -ne $Identity.StartTicks -or $process.Path -ne $Identity.Path) { $process.Dispose(); return $null }
    if ($Identity.Protected -or $process.SessionId -eq 0 -or $process.Id -eq $PID) { $process.Dispose(); throw 'Refusing to stop a protected process.' }
    return $process
}
function Stop-RelatedProcessesWithConsent {
    param([string[]]$Roots)
    $related = @(Get-RelatedProcesses $Roots)
    if (-not $related.Count) { return }
    $listing = ($related | ForEach-Object { '{0} (PID {1}) - {2}' -f $_.Name, $_.Id, $_.Path }) -join "`r`n"
    Write-OperationLog ("Related processes:`r`n" + $listing) 'WARN'
    if (@($related | Where-Object Protected).Count) { throw 'A related process is protected or runs in session 0. Close the application/service yourself, then retry.' }
    if (-not (Request-OperationConfirmation "These applications are running:`r`n$listing`r`n`r`nAsk them to close gracefully? Save your work first.")) { throw 'Cancelled: no processes were stopped.' }
    foreach ($identity in $related) {
        $process = Get-MatchingProcess $identity
        if ($null -ne $process) {
            try { $sent = $process.CloseMainWindow(); Write-OperationLog "Close request for PID $($identity.Id): $sent" }
            finally { $process.Dispose() }
        }
    }
    Start-Sleep -Seconds 5
    $survivors = @()
    foreach ($identity in $related) {
        $process = Get-MatchingProcess $identity
        if ($null -ne $process) { $survivors += $identity; $process.Dispose() }
    }
    if ($survivors.Count) {
        $names = ($survivors | ForEach-Object { "$($_.Name) (PID $($_.Id))" }) -join ', '
        if (-not (Request-OperationConfirmation "Still running: $names`r`nForce-stop these specific processes? Unsaved work may be lost.")) { throw 'Cancelled: applications are still running.' }
        foreach ($identity in $survivors) {
            $process = Get-MatchingProcess $identity
            if ($null -ne $process) {
                try {
                    $process.Kill()
                    if (-not $process.WaitForExit(5000)) { throw "Process did not exit: $($identity.Id)" }
                    Write-OperationLog "Force-stopped PID $($identity.Id) with permission." 'WARN'
                } finally { $process.Dispose() }
            }
        }
    }
    if (@(Get-RelatedProcesses $Roots).Count) { throw 'A related process is still running or restarted. Close it and retry.' }
}
function Save-TransactionState {
    param($Transaction, [string]$Stage)
    $Transaction.Stage = $Stage
    $Transaction.UpdatedUtc = [DateTime]::UtcNow.ToString('o')
    if ($script:Context.ContainsKey('LogRootId')) {
        $Transaction['Manager'] = 'JunctionManager'; $Transaction['Schema'] = 1; $Transaction['RootId'] = $script:Context.LogRootId
    }
    # Append-only journal, flushed before/after namespace changes.
    $json = ($Transaction | ConvertTo-Json -Compress) + [Environment]::NewLine
    $data = [Text.Encoding]::UTF8.GetBytes($json)
    $file = [IO.FileStream]::new($Transaction.Journal, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::Read)
    try { $file.Write($data, 0, $data.Length); $file.Flush($true) } finally { $file.Dispose() }
    Set-OperationStage "Transaction: $Stage"
}
function Invoke-RobocopyPass {
    param([string]$Source, [string]$Target, [string]$LogDirectory, [switch]$VerifyOnly)
    Assert-PlainAncestors $Source
    Assert-PlainAncestors $Target
    $log = Join-Path $LogDirectory ('Robocopy_' + [Guid]::NewGuid().ToString('N') + '.log')
    $arguments = @($Source, $Target, '/E', '/COPYALL', '/DCOPY:DAT', '/SECFIX', '/TIMFIX', '/XJ', '/SL', '/R:2', '/W:2', '/NP', '/NFL', '/NDL', "/UNILOG:$log")
    if ($VerifyOnly) { $arguments += '/L' }
    # Passed straight to CreateProcess, never cmd.exe; normalized paths cannot contain quotes.
    $commandLine = ($arguments | ForEach-Object { '"' + $_ + '"' }) -join ' '
    $exe = Join-Path ([Environment]::GetFolderPath('System')) 'robocopy.exe'
    Write-OperationLog ('"' + $exe + '" ' + $commandLine)
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $exe; $start.Arguments = $commandLine
    $start.UseShellExecute = $false; $start.CreateNoWindow = $true
    $start.WorkingDirectory = [Environment]::GetFolderPath('System')
    $process = [Diagnostics.Process]::new(); $process.StartInfo = $start
    $reader = $null; $started = $false
    $watch = [Diagnostics.Stopwatch]::StartNew()
    try {
        $started = $process.Start()
        if (-not $started) { throw 'Could not start robocopy.' }
        do {
            if ($null -eq $reader -and [IO.File]::Exists($log)) {
                $file = [IO.File]::Open($log, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
                $reader = [IO.StreamReader]::new($file, [Text.Encoding]::Unicode, $true)
            }
            if ($null -ne $reader) {
                while ($null -ne ($line = $reader.ReadLine())) {
                    if (-not [string]::IsNullOrWhiteSpace($line)) { Write-OperationLog ('ROBOCOPY ' + $line.Trim()) }
                }
            }
            if ($watch.Elapsed.TotalSeconds -ge 5) { Set-OperationStage 'Robocopy is running. Detailed output is being written to the log...'; $watch.Restart() }
            $finished = $process.WaitForExit(200)
        } while (-not $finished)
        if ($null -ne $reader) {
            $tail = $reader.ReadToEnd()
            if (-not [string]::IsNullOrWhiteSpace($tail)) { Write-OperationLog ('ROBOCOPY ' + $tail.Trim()) }
        }
        $exitCode = $process.ExitCode
        if ($null -eq $reader -and [IO.File]::Exists($log)) {
            # Very small copies can finish before the first poll opens the log.
            $tail = [IO.File]::ReadAllText($log, [Text.Encoding]::Unicode)
            if (-not [string]::IsNullOrWhiteSpace($tail)) { Write-OperationLog ('ROBOCOPY ' + $tail.Trim()) }
        }
        Write-OperationLog "Robocopy exit code: $exitCode; log: $log"
        if ($exitCode -lt 0 -or $exitCode -ge 8) { throw "Robocopy failed (exit $exitCode). Source/backup and Target are retained. See $log" }
        if ($VerifyOnly -and $exitCode -ne 0) { throw "Robocopy verification found differences (code $exitCode is not a fatal copy code). Close writers and retry." }
    } finally {
        if ($started -and -not $process.HasExited) { $process.Kill(); $process.WaitForExit() }
        if ($null -ne $reader) { $reader.Dispose() }
        $process.Dispose()
    }
}
function New-VerifiedJunction {
    param([string]$Source, [string]$Target)
    Assert-PlainAncestors $Source
    Assert-PlainAncestors $Target
    if ($null -ne (Get-PathEntry $Source)) { throw "Source path was recreated by another process: $Source" }
    # In Windows PowerShell 5.1, Target is wildcard-resolved even though Path is
    # a literal new item name. Escape brackets/backticks in the destination.
    New-Item -ItemType Junction -Path $Source -Target ([Management.Automation.WildcardPattern]::Escape($Target)) -ErrorAction Stop | Out-Null
    Assert-Junction $Source $Target
}
function Restore-BackupDirectory {
    param([string]$Source, [string]$Backup)
    if ($Backup -ne ($Source + '_backup')) { throw 'Unexpected backup path.' }
    Assert-PlainAncestors $Source
    Assert-PlainAncestors $Backup
    if ($null -ne (Get-PathEntry $Source)) { throw 'Source is occupied. No existing data will be overwritten.' }
    if ($null -eq (Get-PathEntry $Backup)) { throw "Backup is unavailable: $Backup" }
    [IO.Directory]::Move($Backup, $Source)
    if ($null -eq (Get-PathEntry $Source) -or $null -ne (Get-PathEntry $Backup)) { throw 'Backup restoration could not be verified.' }
}
function Invoke-MoveTransaction {
    param([string]$Source, [string]$Target)
    $analysis = Get-MoveAnalysis $Source $Target
    if (-not $analysis.Valid) { throw ($analysis.Errors -join "`r`n") }
    if (-not (Request-OperationConfirmation ((Format-Analysis $analysis) + "`r`n`r`nCopy, keep backup, then create the junction?"))) { Set-OperationStage 'Cancelled. No files changed.'; return }
    Stop-RelatedProcessesWithConsent @($analysis.Source)
    $analysis = Get-MoveAnalysis $analysis.Source $analysis.Target
    if (-not $analysis.Valid) { throw ($analysis.Errors -join "`r`n") }
    $transaction = [ordered]@{ Id = [Guid]::NewGuid().ToString('N'); Source = $analysis.Source; Target = $analysis.Target
        Backup = $analysis.Backup; Stage = 'Validated'; UpdatedUtc = ''; Journal = '' }
    $transaction.Journal = Join-Path $script:Context.LogDirectory ('Transaction_' + $transaction.Id + '.jsonl')
    $renamed = $false; $verified = $false
    try {
        Save-TransactionState $transaction 'Validated'
        Assert-PlainAncestors $analysis.Target
        [void][IO.Directory]::CreateDirectory($analysis.Target)
        Assert-PlainAncestors $analysis.Target
        if (@(Get-ChildItem -LiteralPath $analysis.Target -Force -ErrorAction Stop | Select-Object -First 1).Count) { throw 'Target is no longer empty.' }
        Save-TransactionState $transaction 'Copying'
        Invoke-RobocopyPass $analysis.Source $analysis.Target $script:Context.LogDirectory
        Set-OperationStage 'Verifying copied names, sizes, timestamps and stream sizes...'
        $sourceSnapshot = Get-TreeSnapshot $analysis.Source -ProjectedRoots @($analysis.Backup, $analysis.Target)
        $targetSnapshot = Get-TreeSnapshot $analysis.Target
        Assert-SnapshotsEqual $sourceSnapshot $targetSnapshot
        Save-TransactionState $transaction 'FinalSync'
        Invoke-RobocopyPass $analysis.Source $analysis.Target $script:Context.LogDirectory
        Invoke-RobocopyPass $analysis.Source $analysis.Target $script:Context.LogDirectory -VerifyOnly
        $sourceSnapshot = Get-TreeSnapshot $analysis.Source -ProjectedRoots @($analysis.Backup)
        $targetSnapshot = Get-TreeSnapshot $analysis.Target
        Assert-SnapshotsEqual $sourceSnapshot $targetSnapshot
        if (@(Get-RelatedProcesses @($analysis.Source, $analysis.Target)).Count) { throw 'A related process started during copy. Close it and retry.' }
        Save-TransactionState $transaction 'RenamePending'
        Assert-PlainAncestors $analysis.Source
        Assert-PlainAncestors $analysis.Backup
        if ($null -ne (Get-PathEntry $analysis.Backup)) { throw 'Backup now exists; refusing to overwrite it.' }
        [IO.Directory]::Move($analysis.Source, $analysis.Backup)
        $renamed = $true
        Save-TransactionState $transaction 'BackupCreated'
        Set-OperationStage 'Verifying SHA-256 of backup and Target, including alternate file streams...'
        $backupSnapshot = Get-TreeSnapshot $analysis.Backup -Hash
        $targetSnapshot = Get-TreeSnapshot $analysis.Target -Hash
        Assert-SnapshotsEqual $backupSnapshot $targetSnapshot
        Assert-SnapshotsEqual (Get-TreeSnapshot $analysis.Backup) (Get-TreeSnapshot $analysis.Target)
        try {
            $transaction['BackupIdentity'] = Get-DirectoryIdentity $analysis.Backup
            $transaction['TargetIdentity'] = Get-DirectoryIdentity $analysis.Target
        } catch {
            # Migration remains usable; inability to establish ownership disables Delete Backup.
            $transaction['BackupIdentity'] = ''; $transaction['TargetIdentity'] = ''
            Write-OperationLog "Delete Backup will be unavailable: $($_.Exception.Message)" 'WARN'
        }
        Save-TransactionState $transaction 'JunctionPending'
        New-VerifiedJunction $analysis.Source $analysis.Target
        Save-TransactionState $transaction 'Committed'
        $verified = $true
        Set-OperationStage "Success. Backup retained: $($analysis.Backup). Test the app before using Delete Backup."
    } catch {
        $originalError = $_.Exception.Message
        # Recovery must still run when logging itself failed.
        $recoveryMessage = 'Source was not renamed. Target may contain a partial copy; it was retained.'
        $recoveryStage = 'StoppedBeforeRename'
        if ($renamed -and -not $verified) {
            try {
                if ($null -ne (Get-PathEntry $analysis.Source)) { Remove-JunctionOnly $analysis.Source $analysis.Target }
                Restore-BackupDirectory $analysis.Source $analysis.Backup
                $recoveryMessage = 'Backup was restored to Source. Target was retained.'
                $recoveryStage = 'RestoredAfterFailure'
            } catch { $recoveryMessage = "AUTOMATIC RECOVERY FAILED: $($_.Exception.Message). Backup: $($analysis.Backup). Target: $($analysis.Target). Do not delete either copy."; $recoveryStage = 'RecoveryRequired' }
        } elseif ($verified) { $recoveryMessage = 'Junction was verified and committed. Backup and Target remain available.'; $recoveryStage = 'CommittedWithLoggingError' }
        $transaction['Failure'] = $originalError
        $transaction['Recovery'] = $recoveryMessage
        try { Save-TransactionState $transaction $recoveryStage; Write-OperationLog $recoveryMessage 'WARN' }
        catch { $recoveryMessage += " Logging also failed: $($_.Exception.Message)" }
        throw "$originalError`r`n$recoveryMessage"
    }
}
function Invoke-RollbackTransaction {
    param([string]$Source)
    $recovery = Get-RecoveryInfo $Source
    $message = "Restore backup:`r`n$($recovery.Backup)`r`nTo Source:`r`n$($recovery.Source)`r`n`r`nTarget will be kept. Changes made in Target after migration will NOT be merged into the older backup. Close the app first. Continue?"
    if (-not (Request-OperationConfirmation $message)) { Set-OperationStage 'Rollback cancelled.'; return }
    Stop-RelatedProcessesWithConsent @($recovery.Source, $recovery.Target, $recovery.Backup)
    $recovery = Get-RecoveryInfo $Source
    $transaction = [ordered]@{ Id = [Guid]::NewGuid().ToString('N'); Source = $recovery.Source; Target = $recovery.Target
        Backup = $recovery.Backup; Stage = ''; UpdatedUtc = ''; Journal = '' }
    $transaction.Journal = Join-Path $script:Context.LogDirectory ('Rollback_' + $transaction.Id + '.jsonl')
    Save-TransactionState $transaction 'RollbackPending'
    $removed = $false; $restored = $false
    try {
        if (-not $recovery.MissingSource) { Remove-JunctionOnly $recovery.Source $recovery.Target; $removed = $true }
        Restore-BackupDirectory $recovery.Source $recovery.Backup
        $restored = $true
        Save-TransactionState $transaction 'RolledBack'
        Set-OperationStage 'Rollback completed. Backup restored to Source; Target was kept.'
    } catch {
        $failure = $_.Exception.Message
        if ($removed -and -not $restored -and $null -eq (Get-PathEntry $recovery.Source)) {
            try { New-VerifiedJunction $recovery.Source $recovery.Target; $failure += ' Original junction was recreated; backup is still available.' }
            catch { $failure += " Could not recreate the junction: $($_.Exception.Message). Restore $($recovery.Backup) manually or retry Rollback." }
        }
        if ($restored) { $failure += ' Backup restoration succeeded, but writing its completion log failed.' }
        throw $failure
    }
}

function Initialize-LogDirectory {
    param([string]$ScriptDirectory)
    $candidates = @(Get-OfficialLogRoots $ScriptDirectory)
    $failures = [Collections.Generic.List[string]]::new()
    foreach ($candidate in $candidates) {
        try {
            $session = New-ManagedLogSession $candidate $ScriptDirectory
            foreach ($failure in $failures) { [IO.File]::AppendAllText($session.File, "Log fallback: $failure`r`n", [Text.Encoding]::UTF8) }
            return $session
        } catch { $failures.Add("$candidate : $($_.Exception.Message)") }
    }
    throw ('Cannot create a writable log directory: ' + ($failures -join '; '))
}
function Show-ExplicitConfirmation {
    param($Owner, [string]$Text, [string]$ConfirmLabel)
    $dialog = [Windows.Window]::new()
    $dialog.Title = $ConfirmLabel; $dialog.Owner = $Owner; $dialog.Width = 650; $dialog.Height = 460
    $dialog.WindowStartupLocation = 'CenterOwner'; $dialog.ResizeMode = 'NoResize'
    $panel = [Windows.Controls.DockPanel]::new(); $panel.Margin = '20'
    $buttons = [Windows.Controls.StackPanel]::new(); $buttons.Orientation = 'Horizontal'; $buttons.HorizontalAlignment = 'Right'
    [Windows.Controls.DockPanel]::SetDock($buttons, 'Bottom')
    $cancel = [Windows.Controls.Button]::new(); $cancel.Content = 'Cancel'; $cancel.IsCancel = $true; $cancel.Padding = '16,8'; $cancel.Margin = '8,12,0,0'
    $confirm = [Windows.Controls.Button]::new(); $confirm.Content = $ConfirmLabel; $confirm.Padding = '16,8'; $confirm.Margin = '8,12,0,0'
    $confirm.Add_Click({ $dialog.DialogResult = $true })
    [void]$buttons.Children.Add($cancel); [void]$buttons.Children.Add($confirm); [void]$panel.Children.Add($buttons)
    $content = [Windows.Controls.TextBox]::new(); $content.Text = $Text; $content.IsReadOnly = $true
    $content.TextWrapping = 'Wrap'; $content.VerticalScrollBarVisibility = 'Auto'; $content.BorderThickness = '0'; $content.Padding = '8'
    [void]$panel.Children.Add($content); $dialog.Content = $panel
    return $dialog.ShowDialog() -eq $true
}
function Start-JunctionWindow {
    param([string]$ScriptPath)
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms
    $log = Initialize-LogDirectory ([IO.Path]::GetDirectoryName($ScriptPath))
    $script:Context = [hashtable]::Synchronized(@{
        ScriptPath = $ScriptPath; LogDirectory = $log.Directory; LogFile = $log.File; LogRoot = $log.Root; LogRootId = $log.RootId
        Queue = [Collections.Concurrent.ConcurrentQueue[object]]::new(); Answer = $null; CancelDiscovery = $false; ReadOnlyOperation = $false
    })
    [xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="1080" Height="860" MinWidth="880" MinHeight="720" WindowStartupLocation="CenterScreen" Background="#F3F5F7" FontFamily="Segoe UI" FontSize="13">
  <Window.Resources>
    <Style TargetType="Button"><Setter Property="Padding" Value="14,8"/><Setter Property="Margin" Value="0,0,8,0"/><Setter Property="MinHeight" Value="34"/></Style>
    <Style TargetType="TextBox"><Setter Property="Padding" Value="8"/><Setter Property="VerticalContentAlignment" Value="Center"/></Style>
  </Window.Resources>
  <Grid Margin="24">
    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/><RowDefinition Height="150"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
    <StackPanel Grid.Row="0" Margin="0,0,0,16"><TextBlock x:Name="AppHeading" FontSize="25" FontWeight="SemiBold"/><TextBlock Text="Find an app folder, copy it to another drive, keep a backup, and link the original location." Foreground="#526170" Margin="0,5,0,0"/></StackPanel>
    <TabControl x:Name="MainTabs" Grid.Row="1" Padding="12">
      <TabItem Header="Migration" x:Name="MigrationTab"><Grid>
        <Grid.RowDefinitions><RowDefinition Height="0"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
    <Grid Grid.Row="1" Margin="0,0,0,12"><Grid.ColumnDefinitions><ColumnDefinition Width="100"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions><TextBlock Text="Source Folder" VerticalAlignment="Center"/><TextBox x:Name="SourceBox" Grid.Column="1"/><Button x:Name="BrowseSource" Grid.Column="2" Content="Browse Source" Margin="10,0,0,0"/></Grid>
    <Grid Grid.Row="2" Margin="0,0,0,16"><Grid.ColumnDefinitions><ColumnDefinition Width="100"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions><TextBlock Text="Target Folder" VerticalAlignment="Center"/><TextBox x:Name="TargetBox" Grid.Column="1"/><Button x:Name="BrowseTarget" Grid.Column="2" Content="Browse Target" Margin="10,0,0,0"/></Grid>
    <WrapPanel Grid.Row="3" Margin="0,0,0,12"><Button x:Name="AnalyzeButton" Content="Analyze / Validate"/><Button x:Name="MoveButton" Content="Move &amp; Create Junction" IsEnabled="False"/><Button x:Name="RollbackButton" Content="Rollback" IsEnabled="False"/><Button x:Name="OpenTarget" Content="Open Target" IsEnabled="False"/></WrapPanel>
    <TextBlock Grid.Row="4" Text="Analysis" FontWeight="SemiBold" Margin="0,0,0,6"/>
    <TextBox x:Name="AnalysisBox" Grid.Row="5" IsReadOnly="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" Background="White" Text="Choose Source and the exact destination folder, then select Analyze. Browse Target can create an empty folder."/>
        <StackPanel Grid.Row="6" Margin="0,12,0,0"><TextBlock Text="Maintenance" FontWeight="SemiBold" Margin="0,0,0,8"/><WrapPanel><Button x:Name="OpenLogs" Content="Open Logs"/><Button x:Name="ClearLogs" Content="Clear Logs"/><Button x:Name="DeleteBackup" Content="Delete Backup" IsEnabled="False"/></WrapPanel></StackPanel>
      </Grid></TabItem>
      <TabItem Header="App Discovery"><Grid>
        <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
        <Grid Grid.Row="0" Margin="0,0,0,10"><Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions><TextBlock Text="App Name / Process / EXE" VerticalAlignment="Center" Margin="0,0,10,0"/><TextBox x:Name="DiscoveryQuery" Grid.Column="1"/><Button x:Name="ScanButton" Grid.Column="2" Content="Scan" Margin="10,0,8,0"/><Button x:Name="CancelScan" Grid.Column="3" Content="Cancel Scan" IsEnabled="False"/></Grid>
        <Grid Grid.Row="1" Margin="0,0,0,10"><Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions><Button x:Name="LoadApps" Content="Installed Apps"/><ComboBox x:Name="InstalledApps" Grid.Column="1" IsEditable="True" IsTextSearchEnabled="True" DisplayMemberPath="DisplayName" TextSearch.TextPath="DisplayName" VerticalContentAlignment="Center"/><Button x:Name="ScanLocations" Grid.Column="2" Content="Scan Locations" Margin="10,0,0,0"/></Grid>
        <DataGrid x:Name="CandidatesGrid" Grid.Row="2" AutoGenerateColumns="False" IsReadOnly="True" CanUserAddRows="False" SelectionMode="Single" EnableRowVirtualization="True" HorizontalScrollBarVisibility="Auto"><DataGrid.Columns>
          <DataGridTextColumn Header="Type" Binding="{Binding Type}" Width="95"/><DataGridTextColumn Header="Name" Binding="{Binding Name}" Width="140"/><DataGridTextColumn Header="Path" Binding="{Binding Path}" Width="280"/><DataGridCheckBoxColumn Header="Running" Binding="{Binding Running}" Width="65"/><DataGridTextColumn Header="Size" Binding="{Binding Size}" Width="120"/><DataGridTextColumn Header="Publisher" Binding="{Binding Publisher}" Width="130"/><DataGridTextColumn Header="Reason" Binding="{Binding Reason}" Width="350"/>
        </DataGrid.Columns></DataGrid>
        <StackPanel Grid.Row="3" Margin="0,10,0,0"><WrapPanel><Button x:Name="UseSource" Content="Use as Source" IsEnabled="False"/><Button x:Name="CandidateSize" Content="Calculate Selected Size" IsEnabled="False"/></WrapPanel><TextBlock Text="Discovery only reads information. Selecting a result fills Source; Analyze is still required." TextWrapping="Wrap" Foreground="#526170" Margin="0,8,0,0"/></StackPanel>
      </Grid></TabItem>
    </TabControl>
    <StackPanel Grid.Row="2" Margin="0,12,0,8"><ProgressBar x:Name="Progress" Height="5" Minimum="0" Maximum="100"/><TextBlock x:Name="Status" Text="Ready" TextWrapping="Wrap" Margin="0,7,0,0"/></StackPanel>
    <TextBox x:Name="LogBox" Grid.Row="3" IsReadOnly="True" FontFamily="Consolas" FontSize="12" Background="#17212B" Foreground="#E1E8EF" AcceptsReturn="True" TextWrapping="NoWrap" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"/>
    <DockPanel Grid.Row="4" Margin="0,12,0,0">
      <Button x:Name="ExitButton" DockPanel.Dock="Right" Content="Exit" Margin="12,0,0,0" VerticalAlignment="Center"/>
      <Button x:Name="AboutButton" DockPanel.Dock="Right" Content="About" Margin="12,0,0,0" VerticalAlignment="Center"/>
      <StackPanel VerticalAlignment="Center">
        <TextBlock x:Name="AppIdentity" FontSize="12" Foreground="#526170"/>
        <TextBlock FontSize="11" Margin="0,3,0,0"><Hyperlink x:Name="WebsiteLink"><Run x:Name="WebsiteText"/></Hyperlink><Run Text="  •  "/><Hyperlink x:Name="EmailLink"><Run x:Name="EmailText"/></Hyperlink></TextBlock>
        <TextBlock x:Name="LogLocation" FontSize="10" Foreground="#526170" TextTrimming="CharacterEllipsis" Margin="0,3,0,0"/>
      </StackPanel>
    </DockPanel>
  </Grid>
</Window>
'@
    $reader = [Xml.XmlNodeReader]::new($xaml)
    try { $script:Window = [Windows.Markup.XamlReader]::Load($reader) } finally { $reader.Close() }
    $script:Ui = @{}
    foreach ($name in @('SourceBox','TargetBox','BrowseSource','BrowseTarget','AnalyzeButton','MoveButton','RollbackButton','OpenTarget','AnalysisBox','Progress','Status','LogBox','ExitButton','LogLocation',
        'MainTabs','MigrationTab','DiscoveryQuery','ScanButton','CancelScan','LoadApps','InstalledApps','ScanLocations','CandidatesGrid','UseSource','CandidateSize','OpenLogs','ClearLogs','DeleteBackup',
        'AppHeading','AppIdentity','WebsiteLink','WebsiteText','EmailLink','EmailText','AboutButton')) { $script:Ui[$name] = $script:Window.FindName($name) }
    $appTitle = '{0} {1}' -f $script:AppInfo.Name, $script:AppInfo.Version
    $script:Window.Title = $appTitle
    $script:Ui.AppHeading.Text = $script:AppInfo.Name
    $script:Ui.AppIdentity.Text = '{0}  •  {1}' -f $appTitle, $script:AppInfo.Author
    $script:Ui.WebsiteText.Text = $script:AppInfo.Website
    $script:Ui.EmailText.Text = $script:AppInfo.SupportEmail
    $script:Ui.WebsiteLink.ToolTip = 'https://' + $script:AppInfo.Website
    $script:Ui.EmailLink.ToolTip = 'mailto:' + $script:AppInfo.SupportEmail
    $script:Busy = $false; $script:LastAnalysis = $null
    $script:Worker = $null; $script:WorkerRunspace = $null; $script:WorkerAsync = $null
    $script:Operation = ''
    $script:About = $null
    $script:Ui.LogLocation.Text = 'Logs: ' + $log.Directory
    $script:Ui.LogLocation.ToolTip = $script:Ui.LogLocation.Text
    function Open-SupportLink {
        param([ValidateSet('Website','SupportEmail')][string]$Kind)
        try {
            # Only application-owned metadata reaches the shell, with no command
            # interpreter or arguments and no discovery/user-provided URL.
            $uri = if ($Kind -eq 'Website') { 'https://' + $script:AppInfo.Website } else { 'mailto:' + $script:AppInfo.SupportEmail }
            $startInfo = [Diagnostics.ProcessStartInfo]::new()
            $startInfo.FileName = $uri
            $startInfo.UseShellExecute = $true
            [void][Diagnostics.Process]::Start($startInfo)
        } catch { $script:Ui.Status.Text = 'Unable to open support link: ' + $_.Exception.Message }
    }
    $script:Ui.WebsiteLink.Add_Click({ Open-SupportLink 'Website' })
    $script:Ui.EmailLink.Add_Click({ Open-SupportLink 'SupportEmail' })
    function Update-Buttons {
        foreach ($name in @('SourceBox','TargetBox','BrowseSource','BrowseTarget','AnalyzeButton','ExitButton','DiscoveryQuery','ScanButton','LoadApps','InstalledApps','ScanLocations','OpenLogs','ClearLogs')) { $script:Ui[$name].IsEnabled = -not $script:Busy }
        $script:Ui.MoveButton.IsEnabled = -not $script:Busy -and $null -ne $script:LastAnalysis -and $script:LastAnalysis.Valid
        $script:Ui.RollbackButton.IsEnabled = -not $script:Busy -and $null -ne $script:LastAnalysis -and $null -ne $script:LastAnalysis.Recovery
        $script:Ui.OpenTarget.IsEnabled = -not $script:Busy -and $null -ne $script:LastAnalysis -and $script:LastAnalysis.TargetExists -eq $true
        $script:Ui.Progress.IsIndeterminate = $script:Busy
        $script:Ui.DeleteBackup.IsEnabled = -not $script:Busy -and $null -ne $script:LastAnalysis -and $null -ne $script:LastAnalysis.ManagedBackup
        $script:Ui.CancelScan.IsEnabled = $script:Busy -and $script:Operation -in @('Discovery','InstalledApps','CandidateSize')
        $script:Ui.UseSource.IsEnabled = -not $script:Busy -and $null -ne $script:Ui.CandidatesGrid.SelectedItem
        $script:Ui.CandidateSize.IsEnabled = $script:Ui.UseSource.IsEnabled
        $script:Ui.AboutButton.IsEnabled = -not $script:Busy
        if ($null -ne $script:About) {
            $script:About.CheckButton.IsEnabled = -not $script:Busy
            $canOpenUpdate = -not $script:Busy -and $null -ne $script:About.Result -and $script:About.Result.State -eq 'UpdateAvailable'
            $script:About.DownloadButton.IsEnabled = $canOpenUpdate -and [bool]$script:About.Result.DownloadUrl
            $script:About.NotesButton.IsEnabled = $canOpenUpdate -and [bool]$script:About.Result.ReleaseNotesUrl
        }
    }
    function Start-UiOperation {
        param([string]$Operation, $Options = $null)
        if ($script:Busy) { return }
        $script:Busy = $true; $script:Operation = $Operation
        $script:Context.ActiveOperation = $Operation
        $script:Context.CancelDiscovery = $false
        $script:Context.ReadOnlyOperation = $Operation -in @('Discovery','InstalledApps','CandidateSize')
        if (-not $script:Context.ReadOnlyOperation -and $Operation -ne 'CheckUpdates') { $script:LastAnalysis = $null }
        Update-Buttons
        $script:Ui.Status.Text = "$Operation in progress..."
        try {
            $script:WorkerRunspace = [RunspaceFactory]::CreateRunspace()
            $script:WorkerRunspace.ApartmentState = 'MTA'
            $script:WorkerRunspace.Open()
            $script:Worker = [PowerShell]::Create()
            $script:Worker.Runspace = $script:WorkerRunspace
            $workerCode = {
                param($scriptPath, $sharedContext, $operation, $source, $target, $options)
                . $scriptPath -LibraryOnly
                $script:Context = $sharedContext
                try {
                    switch ($operation) {
                        'Analyze' {
                            $analysis = Get-MoveAnalysis $source $target
                            Write-OperationLog (Format-Analysis $analysis)
                            $sharedContext.Queue.Enqueue([pscustomobject]@{ Kind = 'Analysis'; Data = $analysis })
                            Set-OperationStage $(if ($analysis.Valid) { 'Validation passed. Ready to move.' } else { 'Validation requires attention. See analysis.' })
                        }
                        'Move' {
                            Invoke-MoveTransaction $source $target
                        }
                        'Rollback' {
                            Invoke-RollbackTransaction $source
                        }
                        'Discovery' {
                            [void](Find-AppLocations $options.Query $options.App)
                            Set-OperationStage $(if ($sharedContext.CancelDiscovery) { 'Discovery cancelled; partial results retained.' } else { 'Discovery finished. Select a candidate or refine the search.' })
                        }
                        'InstalledApps' {
                            $apps = @(Get-InstalledApplication)
                            $sharedContext.Queue.Enqueue([pscustomobject]@{ Kind = 'InstalledApps'; Data = $apps })
                            Set-OperationStage "$($apps.Count) installed applications read. Select one and Scan Locations."
                        }
                        'CandidateSize' {
                            $size = Get-CandidateFolderSize (Get-CandidateSourcePath $options.Candidate)
                            $sharedContext.Queue.Enqueue([pscustomobject]@{ Kind = 'CandidateSize'; Path = $options.Candidate.Path; Size = $size })
                            Set-OperationStage 'Selected candidate size check finished.'
                        }
                        'ClearLogs' { Clear-ManagedLogs $source $target }
                        'DeleteBackup' { Remove-ManagedBackup $source $target }
                        'CheckUpdates' {
                            $result = Get-UpdateStatus -Endpoint $options.Endpoint -CurrentVersion $options.CurrentVersion
                            $sharedContext.Queue.Enqueue([pscustomobject]@{ Kind = 'UpdateStatus'; Data = $result })
                        }
                    }
                } catch {
                    if ($operation -eq 'CheckUpdates') {
                        $sharedContext.Queue.Enqueue([pscustomobject]@{ Kind = 'UpdateStatus'; Data = (New-UpdateResult 'Unavailable' 'Unable to check for updates. Please try again later.') })
                        return
                    }
                    $detail = $_.Exception.Message
                    try { Write-OperationLog ($detail + "`r`n" + $_.ScriptStackTrace) 'ERROR' }
                    catch { $detail += "`r`nLogging failed: $($_.Exception.Message)" }
                    $sharedContext.Queue.Enqueue([pscustomobject]@{ Kind = 'Failure'; Text = $detail })
                } finally {
                    if ($operation -in @('Move','Rollback','ClearLogs','DeleteBackup')) {
                        try { $sharedContext.Queue.Enqueue([pscustomobject]@{ Kind = 'Analysis'; Data = (Get-MoveAnalysis $source $target) }) }
                        catch { $sharedContext.Queue.Enqueue([pscustomobject]@{ Kind = 'Log'; Text = 'State refresh failed: ' + $_.Exception.Message }) }
                    }
                }
            }
            [void]$script:Worker.AddScript($workerCode.ToString()).AddArgument($ScriptPath).AddArgument($script:Context).AddArgument($Operation).AddArgument($script:Ui.SourceBox.Text).AddArgument($script:Ui.TargetBox.Text).AddArgument($Options)
            $script:WorkerAsync = $script:Worker.BeginInvoke()
        } catch {
            if ($null -ne $script:Worker) { $script:Worker.Dispose(); $script:Worker = $null }
            if ($null -ne $script:WorkerRunspace) { $script:WorkerRunspace.Dispose(); $script:WorkerRunspace = $null }
            $script:Busy = $false
            $script:Context.ActiveOperation = ''; $script:Context.ReadOnlyOperation = $false
            Update-Buttons
            if ($Operation -eq 'CheckUpdates' -and $null -ne $script:About) { $script:About.Status.Text = 'Unable to check for updates. Please try again later.' }
            else { [void][Windows.MessageBox]::Show($script:Window, $_.Exception.Message, 'Unable to start operation', 'OK', 'Error') }
        }
    }
    function Show-AboutWindow {
        if ($script:Busy) { return }
        if ($null -ne $script:About) { [void]$script:About.Window.Activate(); return }
        $script:About = New-UpdateAboutWindow $script:Window
        $script:About.CheckButton.Add_Click({
            if ($script:Busy) { return }
            $script:About.Result = $null
            $script:About.Status.Text = 'Checking for updates...'
            $script:About.Notes.Text = ''
            Start-UiOperation 'CheckUpdates' @{ Endpoint = $script:AppInfo.UpdateMetadataUrl; CurrentVersion = $script:AppInfo.Version }
        })
        $script:About.DownloadButton.Add_Click({
            if (-not $script:Busy -and $null -ne $script:About.Result -and $script:About.Result.State -eq 'UpdateAvailable') {
                $script:About.Status.Text = Open-TrustedUpdateUri $script:About.Result.DownloadUrl
            }
        })
        $script:About.NotesButton.Add_Click({
            if (-not $script:Busy -and $null -ne $script:About.Result -and $script:About.Result.State -eq 'UpdateAvailable') {
                $script:About.Status.Text = Open-TrustedUpdateUri $script:About.Result.ReleaseNotesUrl
            }
        })
        $script:About.Window.Add_Closing({
            param($sender, $eventArgs)
            if ($script:Busy -and $script:Operation -eq 'CheckUpdates') { $eventArgs.Cancel = $true }
        })
        $script:About.Window.Add_Closed({ $script:About = $null })
        Update-Buttons
        $script:About.Window.Show()
    }
    $script:Ui.AboutButton.Add_Click({ Show-AboutWindow })
    function Select-UiFolder {
        param([bool]$ForTarget)
        $picker = [Windows.Forms.FolderBrowserDialog]::new()
        try {
            $picker.Description = $(if ($ForTarget) { 'Choose the exact Target folder on another drive. You can create a new empty folder here.' } else { 'Choose the current application folder.' })
            $picker.ShowNewFolderButton = $ForTarget
            if ($picker.ShowDialog() -eq [Windows.Forms.DialogResult]::OK) {
                if ($ForTarget) { $script:Ui.TargetBox.Text = $picker.SelectedPath } else {
                    $selected = $picker.SelectedPath
                    # An interrupted operation may leave only the backup selectable in Explorer.
                    if ($selected.EndsWith('_backup', [StringComparison]::OrdinalIgnoreCase)) {
                        $original = $selected.Substring(0, $selected.Length - '_backup'.Length)
                        if ($null -eq (Get-PathEntry $original)) { $selected = $original }
                    }
                    $script:Ui.SourceBox.Text = $selected
                }
            }
        } finally { $picker.Dispose() }
    }
    $script:Ui.SourceBox.Add_TextChanged({ $script:LastAnalysis = $null; Update-Buttons })
    $script:Ui.TargetBox.Add_TextChanged({ $script:LastAnalysis = $null; Update-Buttons })
    $script:Ui.BrowseSource.Add_Click({ Select-UiFolder $false })
    $script:Ui.BrowseTarget.Add_Click({ Select-UiFolder $true })
    $script:Ui.AnalyzeButton.Add_Click({ Start-UiOperation 'Analyze' })
    $script:Ui.MoveButton.Add_Click({ Start-UiOperation 'Move' })
    $script:Ui.RollbackButton.Add_Click({ Start-UiOperation 'Rollback' })
    $script:Ui.DeleteBackup.Add_Click({ Start-UiOperation 'DeleteBackup' })
    $script:Ui.ClearLogs.Add_Click({ Start-UiOperation 'ClearLogs' })
    $script:Ui.ScanButton.Add_Click({ Start-UiOperation 'Discovery' @{ Query = $script:Ui.DiscoveryQuery.Text; App = $null } })
    $script:Ui.LoadApps.Add_Click({ Start-UiOperation 'InstalledApps' })
    $script:Ui.ScanLocations.Add_Click({
        if ($null -ne $script:Ui.InstalledApps.SelectedItem) { Start-UiOperation 'Discovery' @{ Query = ''; App = $script:Ui.InstalledApps.SelectedItem } }
        else { $script:Ui.Status.Text = 'Load and select an Installed App first.' }
    })
    $script:Ui.CancelScan.Add_Click({ $script:Context.CancelDiscovery = $true; $script:Ui.Status.Text = 'Cancelling discovery...' })
    $script:Ui.CandidateSize.Add_Click({ if ($null -ne $script:Ui.CandidatesGrid.SelectedItem) { Start-UiOperation 'CandidateSize' @{ Candidate = $script:Ui.CandidatesGrid.SelectedItem } } })
    function Use-SelectedSource {
        if ($script:Busy -or $null -eq $script:Ui.CandidatesGrid.SelectedItem) { return }
        try {
            $script:Ui.SourceBox.Text = Get-CandidateSourcePath $script:Ui.CandidatesGrid.SelectedItem
            $script:LastAnalysis = $null
            Update-Buttons
            $script:Ui.MainTabs.SelectedItem = $script:Ui.MigrationTab
            $script:Ui.Status.Text = 'Source selected. Analyze is required before moving.'
        } catch { $script:Ui.Status.Text = $_.Exception.Message }
    }
    $script:Ui.UseSource.Add_Click({ Use-SelectedSource })
    $script:Ui.CandidatesGrid.Add_MouseDoubleClick({ Use-SelectedSource })
    $script:Ui.CandidatesGrid.Add_SelectionChanged({ Update-Buttons })
    $script:Ui.OpenLogs.Add_Click({
        try {
            [void](Assert-ManagedLogRoot $script:Context.LogRoot ([IO.Path]::GetDirectoryName($script:Context.ScriptPath)))
            Start-Process -FilePath (Join-Path ([Environment]::GetFolderPath('Windows')) 'explorer.exe') -ArgumentList ('"' + $script:Context.LogRoot + '"') -ErrorAction Stop | Out-Null
        } catch { $script:Ui.Status.Text = $_.Exception.Message }
    })
    $script:Ui.OpenTarget.Add_Click({
        try {
            $path = ConvertTo-LocalPath $script:Ui.TargetBox.Text
            Assert-PlainAncestors $path
            if (-not [IO.Directory]::Exists($path)) { throw 'Target is unavailable.' }
            Start-Process -FilePath (Join-Path ([Environment]::GetFolderPath('Windows')) 'explorer.exe') -ArgumentList ('"' + $path + '"') -ErrorAction Stop | Out-Null
        } catch { [void][Windows.MessageBox]::Show($script:Window, $_.Exception.Message, 'Open Target', 'OK', 'Error') }
    })
    $script:Ui.ExitButton.Add_Click({ $script:Window.Close() })
    $script:Window.Add_Closing({
        param($sender, $eventArgs)
        if ($script:Busy) { $eventArgs.Cancel = $true; $script:Ui.Status.Text = 'Wait for the current operation to finish. Closing now could interrupt recovery.' }
    })
    $timer = [Windows.Threading.DispatcherTimer]::new()
    $timer.Interval = [TimeSpan]::FromMilliseconds(150)
    $timer.Add_Tick({
        $message = $null; $count = 0
        while ($count -lt 100 -and $script:Context.Queue.TryDequeue([ref]$message)) {
            $count++
            switch ($message.Kind) {
                'Log' {
                    $script:Ui.LogBox.AppendText($message.Text + "`r`n")
                    if ($script:Ui.LogBox.Text.Length -gt 200000) { $script:Ui.LogBox.Text = $script:Ui.LogBox.Text.Substring(100000) }
                    $script:Ui.LogBox.ScrollToEnd()
                }
                'Status' { $script:Ui.Status.Text = $message.Text }
                'Analysis' { $script:LastAnalysis = $message.Data; $script:Ui.AnalysisBox.Text = Format-Analysis $message.Data }
                'UpdateStatus' {
                    if ($null -ne $script:About) {
                        $script:About.Result = $message.Data
                        $script:About.Status.Text = $message.Data.Message
                        $script:About.Notes.Text = $message.Data.Notes
                    }
                    $script:Ui.Status.Text = $message.Data.Message
                }
                'Candidates' { $script:Ui.CandidatesGrid.ItemsSource = @($message.Data) }
                'InstalledApps' { $script:Ui.InstalledApps.ItemsSource = @($message.Data) }
                'CandidateSize' {
                    foreach ($row in $script:Ui.CandidatesGrid.ItemsSource) { if ($row.Path -eq $message.Path) { $row.Size = $message.Size } }
                    $script:Ui.CandidatesGrid.Items.Refresh()
                }
                'Confirm' {
                    if ($message.Label) { $script:Context.Answer = Show-ExplicitConfirmation $script:Window $message.Text $message.Label }
                    else {
                        $answer = [Windows.MessageBox]::Show($script:Window, $message.Text, 'Confirm operation', 'YesNo', 'Warning', 'No')
                        $script:Context.Answer = $answer -eq [Windows.MessageBoxResult]::Yes
                    }
                }
                'Failure' {
                    $script:Ui.Status.Text = 'Operation stopped. Review the error and Analyze again before retrying.'
                    [void][Windows.MessageBox]::Show($script:Window, $message.Text, 'Operation stopped', 'OK', 'Error')
                }
            }
        }
        if ($script:Busy -and $null -ne $script:WorkerAsync -and $script:WorkerAsync.IsCompleted -and $script:Context.Queue.IsEmpty) {
            try {
                [void]$script:Worker.EndInvoke($script:WorkerAsync)
                if ($script:Worker.HadErrors) { throw ($script:Worker.Streams.Error | Out-String) }
            } catch {
                if ($script:Operation -eq 'CheckUpdates' -and $null -ne $script:About) { $script:About.Status.Text = 'Unable to check for updates. Please try again later.' }
                else { [void][Windows.MessageBox]::Show($script:Window, $_.Exception.Message, 'Worker error', 'OK', 'Error') }
            }
            finally {
                $script:Worker.Dispose(); $script:WorkerRunspace.Dispose()
                $script:Worker = $null; $script:WorkerRunspace = $null; $script:WorkerAsync = $null
                $script:Busy = $false
                $script:Context.ActiveOperation = ''
                $script:Context.ReadOnlyOperation = $false
                Update-Buttons
            }
        }
    })
    Write-OperationLog ('{0} by {1}' -f $appTitle, $script:AppInfo.Author)
    Write-OperationLog 'Ready. Discovery is read-only. Analyze is required before Move. Maintenance retains recovery information.'
    $timer.Start()
    try { [void]$script:Window.ShowDialog() }
    finally { $timer.Stop() }
}

. (Join-Path $PSScriptRoot 'Junction.Discovery.ps1')
. (Join-Path $PSScriptRoot 'Junction.Maintenance.ps1')
. (Join-Path $PSScriptRoot 'Junction.Update.ps1')

if ($LibraryOnly) { return }
try {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'This utility requires Windows.' }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try { $isAdmin = [Security.Principal.WindowsPrincipal]::new($identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
    finally { $identity.Dispose() }
    $needsSta = [Threading.Thread]::CurrentThread.ApartmentState -ne 'STA'
    $needsDesktop = $PSVersionTable.PSEdition -ne 'Desktop' -or ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess)
    if (-not $isAdmin -or $needsSta -or $needsDesktop) {
        $systemDirectory = [Environment]::GetFolderPath('System')
        if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) { $systemDirectory = Join-Path $env:WINDIR 'Sysnative' }
        $powershell = Join-Path $systemDirectory 'WindowsPowerShell\v1.0\powershell.exe'
        $startParameters = @{ FilePath = $powershell; ArgumentList = ('-NoProfile -STA -ExecutionPolicy Bypass -File "' + $PSCommandPath + '"'); WindowStyle = 'Hidden'; ErrorAction = 'Stop' }
        if (-not $isAdmin) { $startParameters.Verb = 'RunAs' }
        try { Start-Process @startParameters | Out-Null }
        catch { throw "Unable to relaunch (UAC may have been cancelled): $($_.Exception.Message)" }
        return
    }
    $mutex = [Threading.Mutex]::new($false, 'Global\JunctionUtility_Migration_v3')
    $ownsMutex = $false
    try {
        try { $ownsMutex = $mutex.WaitOne(0) }
        catch [Threading.AbandonedMutexException] { $ownsMutex = $true; Write-Warning 'Previous instance stopped unexpectedly. Analyze paths to inspect recovery options.' }
        if (-not $ownsMutex) { throw 'Another Junction Utility instance is already running.' }
        Start-JunctionWindow $PSCommandPath
    } finally {
        if ($ownsMutex) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
} catch {
    Add-Type -AssemblyName PresentationFramework
    [void][Windows.MessageBox]::Show($_.Exception.Message, 'Junction Utility', 'OK', 'Error')
    exit 1
}
