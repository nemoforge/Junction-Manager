#Requires -Version 5.1
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
. (Join-Path $repo 'Junction.ps1') -LibraryOnly
. (Join-Path $PSScriptRoot 'Sandbox.ps1')
$sandbox = New-TestSandbox $repo
Write-Output "Mutation sandbox: $($sandbox.Root)"
$script:passed = 0
function Assert-Test { param([bool]$Condition, [string]$Name); if (-not $Condition) { throw "FAIL: $Name" }; $script:passed++; Write-Output "PASS: $Name" }
function Assert-Throws { param([scriptblock]$Action, [string]$Name); $threw = $false; try { & $Action | Out-Null } catch { $threw = $true }; Assert-Test $threw $Name }
function New-CaseRoot {
    param([string]$Name)
    $path = Join-Path $sandbox.Root ($Name + '-' + [Guid]::NewGuid().ToString('N'))
    Assert-TestMutationPath $sandbox $path
    [void][IO.Directory]::CreateDirectory($path)
    return $path
}
function Set-TestContext {
    param([string]$CaseRoot)
    $hostDirectory = Join-Path $CaseRoot 'Host'
    $session = New-ManagedLogSession (Join-Path $hostDirectory 'MigrationLogs') $hostDirectory
    $script:Context = [hashtable]::Synchronized(@{ ScriptPath = (Join-Path $hostDirectory 'Junction.ps1'); LogRoot = $session.Root; LogRootId = $session.RootId
        LogDirectory = $session.Directory; LogFile = $session.File; Queue = [Collections.Concurrent.ConcurrentQueue[object]]::new()
        Answer = $null; CancelDiscovery = $false; ReadOnlyOperation = $false; ActiveOperation = '' })
}
function New-FakeCommittedMigration {
    param([string]$Name)
    $root = New-CaseRoot $Name
    Set-TestContext $root
    $source = Join-Path $root 'App'; $backup = $source + '_backup'; $target = Join-Path $root 'Target'
    foreach ($path in @($backup,$target)) {
        [void][IO.Directory]::CreateDirectory($path)
        [IO.File]::WriteAllText((Join-Path $path 'keep.txt'), 'owned fixture content')
    }
    New-VerifiedJunction $source $target
    $id = [Guid]::NewGuid().ToString('N')
    $record = [ordered]@{ Id = $id; Source = $source; Target = $target; Backup = $backup; Stage = ''; UpdatedUtc = ''
        Journal = (Join-Path $script:Context.LogDirectory "Transaction_$id.jsonl")
        BackupIdentity = (Get-DirectoryIdentity $backup); TargetIdentity = (Get-DirectoryIdentity $target) }
    Save-TransactionState $record 'Committed'
    return [pscustomobject]@{ Root = $root; Source = $source; Target = $target; Backup = $backup; Record = $record }
}
$originals = @{}
foreach ($name in @('Get-DiscoveryRoots','Get-DiscoveryProcesses','Get-InstalledApplication','Get-ExecutableMetadata','Assert-PlainAncestors','Request-OperationConfirmation')) {
    $originals[$name] = (Get-Item -LiteralPath ('Function:\' + $name)).ScriptBlock
}
try {
    # Discovery uses synthetic directories/metadata and never runs the copied EXE.
    $discoveryRoot = New-CaseRoot 'Discovery'
    Set-TestContext $discoveryRoot
    $dataRoot = Join-Path $discoveryRoot 'Local'; $programRoot = Join-Path $dataRoot 'Programs'
    $systemRoot = Join-Path $discoveryRoot 'System32'; $deniedRoot = Join-Path $discoveryRoot 'WindowsApps'
    $product = Join-Path $programRoot 'Vendor\SomeProduct'
    $data = Join-Path $dataRoot 'AcmeStudioData'; $updater = Join-Path $dataRoot 'acme-updater'
    foreach ($path in @($programRoot,$dataRoot,$systemRoot,$deniedRoot,$product,$data,$updater)) { [void][IO.Directory]::CreateDirectory($path) }
    $exe = Join-Path $product 'dageg.exe'
    [IO.File]::WriteAllText($exe, 'not executed; synthetic executable metadata is injected')
    [IO.File]::WriteAllText((Join-Path $systemRoot 'dageg.exe'), 'not executed')
    $app = [pscustomobject]@{ DisplayName = 'Acme Studio'; DisplayVersion = '1'; Publisher = 'Example Vendor'
        InstallLocation = $product; DisplayIcon = $exe; UninstallString = 'UNTRUSTED -- never run' }
    function Get-DiscoveryRoots { @(
        [pscustomobject]@{ Path = $programRoot; Kind = 'Install' }, [pscustomobject]@{ Path = $dataRoot; Kind = 'Data' },
        [pscustomobject]@{ Path = $systemRoot; Kind = 'System' }, [pscustomobject]@{ Path = $deniedRoot; Kind = 'Packaged App' }) }
    function Get-InstalledApplication { $app; $app }
    function Get-DiscoveryProcesses { [pscustomobject]@{ Name = 'dageg'; Path = $exe; Id = 999999 } }
    function Get-ExecutableMetadata {
        param([string]$Path)
        [pscustomobject]@{ ProductName = 'Acme Studio'; FileDescription = 'Acme Studio editor'; CompanyName = 'Example Vendor'; InternalName = 'AcmeStudio'; OriginalFilename = 'dageg.exe'; FileVersion = '1' }
    }
    $script:InjectDiscoveryDenied = $false
    function Assert-PlainAncestors {
        param([string]$Path, [switch]$AllowLeafReparse)
        if ($script:InjectDiscoveryDenied -and $Path -eq $deniedRoot) { throw [UnauthorizedAccessException]::new('Injected denied WindowsApps root') }
        & $originals['Assert-PlainAncestors'] $Path -AllowLeafReparse:$AllowLeafReparse
    }
    Assert-Test (@(Get-AppSearchTokens ' FoO.exe ') -contains 'foo') 'EXE normalization'
    Assert-Test (@(Get-AppSearchTokens 'Acme-Studio_Name') -contains 'acme studio name') 'Separator/case normalization'
    Assert-Test (@(Get-AppSearchTokens @('bin','cache','updater')).Count -eq 0) 'Generic parent tokens excluded'
    Assert-Test (@(Merge-InstalledApplications @($app,$app)).Count -eq 1) 'Installed app deduplication'
    $realMetadata = & $originals['Get-ExecutableMetadata'] (Join-Path ([Environment]::GetFolderPath('System')) 'notepad.exe')
    Assert-Test ($null -ne $realMetadata -and [bool]$realMetadata.ProductName) 'Native executable metadata can be read without executing it'
    $script:Context.ReadOnlyOperation = $true
    $before = Get-TreeSnapshot $sandbox.Root -Hash
    $priorState = [pscustomobject]@{ Valid = $true; Source = 'unchanged migration state' }
    $script:LastAnalysis = $priorState
    $script:InjectDiscoveryDenied = $true
    $results = @(Find-AppLocations 'dageg.exe')
    $script:InjectDiscoveryDenied = $false
    Assert-Test (@($results | Where-Object Path -eq $exe).Count -eq 1) 'Candidates deduplicate executable paths'
    Assert-Test ($results[0].Path -eq $exe -and $results[0].Running) 'Running executable ranks first'
    Assert-Test (@($results | Where-Object Path -eq $data).Count -eq 1) 'Unknown EXE infers canonical product and related data folder'
    Assert-Test (@($results | Where-Object { $_.Path -eq $product -and $_.Type -eq 'Install' }).Count -eq 1) 'Specific Local Programs root overrides broad Data classification'
    Assert-Test (@($results | Where-Object { $_.Path -eq $updater -and $_.Type -eq 'Updater' }).Count -eq 1) 'Related prefix / updater classification'
    Assert-Test (@($results | Where-Object { $_.Type -eq 'System' -and $_.Reason -like '*not recommended*' }).Count -eq 1) 'System executable receives warning'
    Assert-Test (@($script:Context.Queue.ToArray() | Where-Object { $_.Kind -eq 'Log' -and $_.Text -like '*WindowsApps could not*' }).Count -gt 0) 'Denied WindowsApps warns and continues'
    Assert-Test ((Get-CandidateSourcePath ($results | Where-Object Path -eq $exe)) -eq $product) 'EXE selection maps to parent Source'
    Assert-Test ((Get-CandidateSourcePath ($results | Where-Object Path -eq $data)) -eq $data) 'Directory selection maps to itself'
    Assert-Test ([object]::ReferenceEquals($script:LastAnalysis,$priorState)) 'Discovery preserves migration analysis state'
    Assert-SnapshotsEqual $before (Get-TreeSnapshot $sandbox.Root -Hash)
    Assert-Test $true 'Discovery mutation count zero: entire sandbox/ADS/log content unchanged'
    Assert-Test ((Get-CandidateFolderSize $systemRoot) -like 'Unknown*') 'Scan/system roots are not recursively sized'
    $script:Context.CancelDiscovery = $true
    $cancelled = @(Find-AppLocations 'Acme Studio')
    Assert-Test ($cancelled.Count -eq 0) 'Discovery cancellation checked before filesystem scan'
    $script:Context.CancelDiscovery = $false; $script:Context.ReadOnlyOperation = $false
    foreach ($name in @('Get-DiscoveryRoots','Get-DiscoveryProcesses','Get-InstalledApplication','Get-ExecutableMetadata','Assert-PlainAncestors')) { Set-Item -LiteralPath ('Function:\' + $name) -Value $originals[$name] }

    $script:ConfirmDelete = $true; $script:ConfirmationLabel = ''
    function Request-OperationConfirmation { param([string]$Text, [string]$ConfirmLabel = ''); $script:ConfirmationLabel = $ConfirmLabel; return $script:ConfirmDelete }
    $valid = New-FakeCommittedMigration 'ValidBackup'
    $managed = Get-ManagedBackup $valid.Source $valid.Target
    Assert-Test ($managed.Backup -eq $valid.Backup) 'Exact committed backup identified from managed journal + NTFS IDs'
    $script:ConfirmDelete = $false
    Remove-ManagedBackup $valid.Source $valid.Target
    Assert-Test ([IO.File]::Exists((Join-Path $valid.Backup 'keep.txt'))) 'Cancel Delete Backup leaves data untouched'
    Assert-Test ($script:ConfirmationLabel -eq 'Delete Backup') 'Destructive confirmation uses explicit Delete Backup label'
    $targetBefore = Get-TreeSnapshot $valid.Target -Hash
    $script:ConfirmDelete = $true
    Remove-ManagedBackup $valid.Source $valid.Target
    Assert-Test ($null -eq (Get-PathEntry $valid.Backup)) 'Successful backup deletion removes only backup'
    Assert-Junction $valid.Source $valid.Target
    Assert-Test $true 'Junction remains functional after deleting backup'
    Assert-SnapshotsEqual $targetBefore (Get-TreeSnapshot $valid.Target -Hash)
    Assert-Test $true 'Target content and ADS remain untouched'
    Assert-Throws { Get-RecoveryInfo $valid.Source } 'Normal rollback unavailable after backup deletion'
    Assert-Throws { Get-ManagedBackup $valid.Source $valid.Target } 'Missing backup cannot be deleted'
    $plain = New-FakeCommittedMigration 'PlainSource'
    Remove-JunctionOnly $plain.Source $plain.Target
    [void][IO.Directory]::CreateDirectory($plain.Source)
    Assert-Throws { Get-ManagedBackup $plain.Source $plain.Target } 'Source must be a junction'
    $wrong = New-FakeCommittedMigration 'WrongTarget'
    $other = Join-Path $wrong.Root 'Other'; [void][IO.Directory]::CreateDirectory($other)
    Remove-JunctionOnly $wrong.Source $wrong.Target; New-VerifiedJunction $wrong.Source $other
    Assert-Throws { Get-ManagedBackup $wrong.Source $wrong.Target } 'Wrong junction destination rejected'
    $linked = New-FakeCommittedMigration 'LinkedBackup'
    [IO.Directory]::Move($linked.Backup, ($linked.Backup + '-saved'))
    New-VerifiedJunction $linked.Backup $linked.Target
    Assert-Throws { Get-ManagedBackup $linked.Source $linked.Target } 'Backup itself cannot be a junction'
    $child = New-FakeCommittedMigration 'BackupChildLink'
    New-VerifiedJunction (Join-Path $child.Backup 'child') $child.Target
    Assert-Throws { Get-ManagedBackup $child.Source $child.Target } 'Backup containing a reparse child cannot be deleted'
    $replaced = New-FakeCommittedMigration 'ReplacedBackup'
    [IO.Directory]::Move($replaced.Backup, ($replaced.Backup + '-saved'))
    [void][IO.Directory]::CreateDirectory($replaced.Backup)
    Assert-Throws { Get-ManagedBackup $replaced.Source $replaced.Target } 'Same path with a different NTFS identity is rejected'
    $mismatch = New-FakeCommittedMigration 'JournalMismatch'
    $mismatch.Record.Target = Join-Path $mismatch.Root 'MismatchedTarget'
    Save-TransactionState $mismatch.Record 'Committed'
    Assert-Throws { Get-ManagedBackup $mismatch.Source $mismatch.Target } 'Journal identity mismatch disables deletion'
    $locked = New-FakeCommittedMigration 'LockedBackup'
    $handle = [IO.File]::Open((Join-Path $locked.Backup 'keep.txt'), [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try { Assert-Throws { Remove-ManagedBackup $locked.Source $locked.Target } 'Locked backup reports incomplete deletion' }
    finally { $handle.Dispose() }
    Assert-Throws { Get-RecoveryInfo $locked.Source } 'Interrupted backup deletion cannot restore a partial backup'
    Assert-Test (@(Get-ManagedLogSessions | Where-Object { $_.Eligible }).Count -eq 0) 'Pending backup deletion journal is retained'
    $script:Context.ActiveOperation = 'Move'
    Assert-Throws { Clear-ManagedLogs } 'Clear Logs blocked during Move'
    Assert-Throws { Remove-ManagedBackup $locked.Source $locked.Target } 'Delete Backup blocked during Move'
    $script:Context.ActiveOperation = ''

    $logCase = New-CaseRoot 'Logs'; Set-TestContext $logCase
    $officialRoot = $script:Context.LogRoot; $hostDirectory = [IO.Path]::GetDirectoryName($script:Context.ScriptPath)
    Assert-Throws { Assert-ManagedLogRoot $logCase $hostDirectory } 'Arbitrary log directory rejected'
    Assert-Throws { Assert-ManagedLogRoot ([IO.Path]::GetPathRoot($logCase)) $hostDirectory } 'Drive root rejected for log cleanup'
    Assert-Throws { Get-ManagedLogSessions @($officialRoot) } 'Source/Target overlap blocks Clear Logs'
    $completed = New-ManagedLogSession $officialRoot $hostDirectory
    [IO.File]::WriteAllText((Join-Path $completed.Directory ('Robocopy_' + [Guid]::NewGuid().ToString('N') + '.log')), 'synthetic log')
    $unresolved = New-ManagedLogSession $officialRoot $hostDirectory
    $id = [Guid]::NewGuid().ToString('N'); $unresolvedSource = Join-Path $logCase 'UnresolvedSource'
    $record = [ordered]@{ Id=$id; Source=$unresolvedSource; Target=(Join-Path $logCase 'UnresolvedTarget'); Backup=($unresolvedSource+'_backup'); Stage=''; UpdatedUtc=''; Journal=(Join-Path $unresolved.Directory "Transaction_$id.jsonl") }
    Save-TransactionState $record 'RenamePending'
    $unknown = New-ManagedLogSession $officialRoot $hostDirectory
    [IO.File]::WriteAllText((Join-Path $unknown.Directory 'unowned.txt'), 'must retain')
    $lockedSession = New-ManagedLogSession $officialRoot $hostDirectory
    $handle = [IO.File]::Open($lockedSession.File, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try { Assert-Throws { Clear-ManagedLogs } 'Locked log produces partial-cleanup report' }
    finally { $handle.Dispose() }
    Assert-Test (-not [IO.Directory]::Exists($completed.Directory)) 'Completed historical session deleted'
    Assert-Test ([IO.Directory]::Exists($script:Context.LogDirectory)) 'Current session retained'
    Assert-Test ([IO.File]::Exists($record.Journal)) 'Unresolved recovery journal retained'
    Assert-Test ([IO.File]::Exists((Join-Path $unknown.Directory 'unowned.txt'))) 'Unowned content retained'
    Clear-ManagedLogs
    Assert-Test (-not [IO.Directory]::Exists($lockedSession.Directory)) 'Previously locked historical session can be cleared after release'
    Assert-Throws { Assert-TestMutationPath $sandbox ([Environment]::GetFolderPath('UserProfile')) } 'Test mutation outside sandbox rejected'

    # Exercise parent cleanup inside a synthetic project, entirely below this
    # session's ownership boundary. Unknown siblings must survive untouched.
    $parentCase = New-CaseRoot 'ParentCleanup'
    $testParent = Join-Path $parentCase '.test-sandbox'
    [void][IO.Directory]::CreateDirectory($testParent)
    $hiddenFile = Join-Path $testParent 'retain.txt'
    [IO.File]::WriteAllText($hiddenFile, 'unknown hidden content')
    [IO.File]::SetAttributes($hiddenFile, [IO.FileAttributes]::Hidden)
    Remove-EmptyTestSandboxParent $parentCase $testParent
    Assert-Test ([IO.File]::ReadAllText($hiddenFile) -eq 'unknown hidden content') 'Parent cleanup retains hidden files'
    $retainedFile = Join-Path $parentCase 'retain.txt'
    Assert-TestMutationPath $sandbox $hiddenFile; Assert-TestMutationPath $sandbox $retainedFile
    [IO.File]::Move($hiddenFile, $retainedFile)
    $siblingFolder = Join-Path $testParent 'OtherSession'
    [void][IO.Directory]::CreateDirectory($siblingFolder)
    Remove-EmptyTestSandboxParent $parentCase $testParent
    Assert-Test ([IO.Directory]::Exists($siblingFolder)) 'Parent cleanup retains sibling directories'
    $retainedFolder = Join-Path $parentCase 'OtherSession'
    Assert-TestMutationPath $sandbox $siblingFolder; Assert-TestMutationPath $sandbox $retainedFolder
    [IO.Directory]::Move($siblingFolder, $retainedFolder)
    Remove-EmptyTestSandboxParent $parentCase $testParent
    Assert-Test ($null -eq (Get-PathEntry $testParent)) 'Empty canonical sandbox parent is removed'
    Remove-EmptyTestSandboxParent $parentCase $retainedFolder -WarningVariable parentWarnings -WarningAction SilentlyContinue
    Assert-Test ([IO.Directory]::Exists($retainedFolder) -and ($parentWarnings -join ' ').Contains($retainedFolder)) 'Wrong parent path is retained with an exact-path warning'
    New-VerifiedJunction $testParent $retainedFolder
    Remove-EmptyTestSandboxParent $parentCase $testParent -WarningVariable parentWarnings -WarningAction SilentlyContinue
    Assert-Test ((Test-ReparseEntry (Get-PathEntry $testParent)) -and [IO.Directory]::Exists($retainedFolder) -and ($parentWarnings -join ' ').Contains($testParent)) 'Reparse parent is refused with a warning; destination stays intact'
    Remove-JunctionOnly $testParent $retainedFolder

    $markerPath = Join-Path $sandbox.Root '.junction-test-sandbox'
    $markerText = [IO.File]::ReadAllText($markerPath)
    try {
        [IO.File]::WriteAllText($markerPath, '{"SessionId":"wrong"}')
        Assert-Throws { Remove-TestSandboxSafely $sandbox } 'Malformed/wrong ownership marker aborts cleanup'
        Assert-Test ([IO.Directory]::Exists($logCase)) 'Failed ownership check deletes nothing'
    } finally { [IO.File]::WriteAllText($markerPath, $markerText, [Text.Encoding]::UTF8) }
    Write-Output "Completed $script:passed feature checks."
} finally {
    foreach ($name in $originals.Keys) { Set-Item -LiteralPath ('Function:\' + $name) -Value $originals[$name] }
    try {
        Remove-TestSandboxSafely $sandbox
        Write-Output 'Cleanup verified: no test fixture remains.'
    } catch {
        Write-Output ("Cleanup incomplete:`r`n" + $sandbox.Root + "`r`n" + $_.Exception.Message)
        throw
    }
}
