#Requires -Version 5.1
# Run: powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Smoke.ps1
# Every mutation stays in an owned project-drive sandbox, cleaned in finally.
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$scriptPath = Join-Path $repo 'Junction.ps1'
. $scriptPath -LibraryOnly
. (Join-Path $PSScriptRoot 'Sandbox.ps1')
$sandbox = New-TestSandbox $repo
Write-Output "Mutation sandbox: $($sandbox.Root)"
$originalVolume = ${function:Get-FixedNtfsVolume}
try {
$fixture = $sandbox.Root
$hostFolder = Join-Path $fixture 'Host'
[void][IO.Directory]::CreateDirectory($hostFolder)
foreach ($file in @('Junction.ps1','Junction.Discovery.ps1','Junction.Maintenance.ps1','Junction.Update.ps1')) {
    Copy-Item -LiteralPath (Join-Path $repo $file) -Destination (Join-Path $hostFolder $file) -ErrorAction Stop
}
$scriptPath = Join-Path $hostFolder 'Junction.ps1'
$log = New-ManagedLogSession (Join-Path $hostFolder 'MigrationLogs') $hostFolder
$script:Context = [hashtable]::Synchronized(@{ ScriptPath = $scriptPath; LogRoot = $log.Root; LogRootId = $log.RootId; LogDirectory = $log.Directory; LogFile = $log.File; Queue = [Collections.Concurrent.ConcurrentQueue[object]]::new(); Answer = $null; CancelDiscovery = $false; ReadOnlyOperation = $false })
# Only volume identity is simulated to exercise the existing cross-volume gate on
# one physical drive. Production validation and copy flags are not changed on disk.
function Get-FixedNtfsVolume {
    param([string]$Path)
    $volume = & $originalVolume $Path
    if ([IO.Path]::GetFileName($Path).StartsWith('Target', [StringComparison]::OrdinalIgnoreCase)) { $volume.Id += '|simulated-target-volume' }
    return $volume
}
$script:passed = 0
function Assert-Test { param([bool]$Condition, [string]$Name); if (-not $Condition) { throw "FAIL: $Name" }; $script:passed++; Write-Output "PASS: $Name" }
function Assert-Throws { param([scriptblock]$Action, [string]$Name); $threw = $false; try { & $Action | Out-Null } catch { $threw = $true }; Assert-Test $threw $Name }
function New-FixturePair {
    param([string]$Name)
    $caseRoot = Join-Path $fixture ($Name + '-' + [Guid]::NewGuid().ToString('N'))
    Assert-TestMutationPath $sandbox $caseRoot
    $source = Join-Path $caseRoot 'Source Tiếng Việt [a] (b) & %'
    $target = Join-Path $caseRoot 'Target [x] (y)'
    [void][IO.Directory]::CreateDirectory($source)
    [void][IO.Directory]::CreateDirectory((Join-Path $source 'empty [dir]'))
    $file = Join-Path $source 'payload [1].txt'
    [IO.File]::WriteAllText($file, 'original content')
    Set-Content -LiteralPath $file -Stream 'extra' -Value 'alternate stream' -NoNewline
    [IO.File]::SetAttributes($file, ([IO.FileAttributes]::Hidden -bor [IO.FileAttributes]::System))
    return [pscustomobject]@{ Source = $source; Target = $target; File = $file; Backup = ($source + '_backup') }
}
$tokens = $null; $parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)
Assert-Test ($parseErrors.Count -eq 0) 'PowerShell 5.1 parser'
Add-Type -AssemblyName PresentationFramework
$xaml = $ast.Find({ param($node) $node -is [Management.Automation.Language.StringConstantExpressionAst] -and $node.Value.StartsWith('<Window ') }, $true)
$reader = [Xml.XmlNodeReader]::new([xml]$xaml.Value)
try { $window = [Windows.Markup.XamlReader]::Load($reader); Assert-Test ($null -ne $window.FindName('MoveButton')) 'WPF XAML loads'; $window.Close() } finally { $reader.Close() }
Assert-Test ((ConvertTo-LocalPath 'E:\App\..\App2\') -eq 'E:\App2') 'Path normalization'
Assert-Test (-not (Test-PathWithin 'E:\Application2' 'E:\Application')) 'Sibling prefix is not a descendant'
foreach ($bad in @('\\server\share', 'E:relative', '\\?\E:\App', 'E:\App\NUL', 'E:\App\bad.', 'E:\PROGRA~1')) { Assert-Throws { ConvertTo-LocalPath $bad } "Reject path: $bad" }
$pair = New-FixturePair 'Normal'
$before = Get-TreeSnapshot $pair.Source -Hash
$analysis = Get-MoveAnalysis $pair.Source $pair.Target
Assert-Test $analysis.Valid ('Analyze valid pair (volume identity simulated): ' + ($analysis.Errors -join '; '))
Assert-Test ($before.Bytes -eq 32) 'Source size includes alternate streams'
Assert-Test (-not [IO.Directory]::Exists($pair.Target)) 'Analyze does not create Target'
Assert-SnapshotsEqual $before (Get-TreeSnapshot $pair.Source -Hash)
Assert-Test $true 'Analyze leaves Source content unchanged'
[void][IO.Directory]::CreateDirectory($pair.Target)
Assert-Test (Get-MoveAnalysis $pair.Source $pair.Target).Valid 'Empty existing Target allowed'
[IO.File]::WriteAllText((Join-Path $pair.Target 'unrelated'), 'retain')
Assert-Test (-not (Get-MoveAnalysis $pair.Source $pair.Target).Valid) 'Nonempty Target refused'
foreach ($target in @($pair.Source, ($pair.Source + '\nested'), $fixture)) { Assert-Test (-not (Get-MoveAnalysis $pair.Source $target).Valid) "Overlap refused: $target" }
Assert-Test (-not (Get-MoveAnalysis ($pair.Source + '-missing') $pair.Target).Valid) 'Missing Source refused'
Assert-Test (-not (Get-MoveAnalysis $pair.File $pair.Target).Valid) 'File Source refused'
$link = Join-Path $fixture 'Link [x]'
New-VerifiedJunction $link $pair.Target
Assert-Junction $link $pair.Target
Assert-Throws { Remove-JunctionOnly $link $pair.Source } 'Wrong junction destination cannot be removed'
Remove-JunctionOnly $link $pair.Target
Assert-Test ([IO.File]::Exists((Join-Path $pair.Target 'unrelated'))) 'Junction-only removal retains Target content'
$childLink = Join-Path $pair.Source 'child link'
New-VerifiedJunction $childLink $pair.Target
Assert-Throws { Get-TreeSnapshot $pair.Source } 'Nested reparse point rejected'
Remove-JunctionOnly $childLink $pair.Target

# Save real definitions. The non-elevated harness uses DAT instead of COPYALL;
# production COPYALL/elevation must be manually tested. Everything else is native.
$nativeRobo = ${function:Invoke-RobocopyPass}
$nativeConfirm = ${function:Request-OperationConfirmation}
$nativeJunction = ${function:New-VerifiedJunction}
$nativeVolume = ${function:Get-FixedNtfsVolume}
$nativeState = ${function:Save-TransactionState}
$nativeProcesses = ${function:Stop-RelatedProcessesWithConsent}
$nativeMove = ${function:Invoke-MoveTransaction}
try {
    $probe = New-FixturePair 'CopyallProbe'
    [void][IO.Directory]::CreateDirectory($probe.Target)
    $isAdmin = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        Assert-Throws { Invoke-RobocopyPass $probe.Source $probe.Target $script:Context.LogDirectory } 'Native COPYALL fails safely without audit privilege'
        Set-Item -LiteralPath Function:\Invoke-RobocopyPass -Value ([scriptblock]::Create($nativeRobo.ToString().Replace("'/COPYALL'", "'/COPY:DAT'").Replace("'/SECFIX', ", '')))
    }
    function Request-OperationConfirmation { param([string]$Text); return $true }
    # Fixtures contain no executables; no real process is stopped by these tests.
    function Stop-RelatedProcessesWithConsent { param([string[]]$Roots) }
    $success = New-FixturePair 'Success'
    Invoke-MoveTransaction $success.Source $success.Target
    Assert-Junction $success.Source $success.Target
    Assert-SnapshotsEqual (Get-TreeSnapshot $success.Backup -Hash) (Get-TreeSnapshot $success.Target -Hash)
    Assert-Test $true 'Native same-drive copy + simulated volume identity + ADS hashes + backup + verified junction'
    Assert-Test (Get-MoveAnalysis $success.Source $success.Target).Recovery.Source.Equals($success.Source) 'Analyze junction enables rollback'
    [IO.File]::WriteAllText((Join-Path $success.Target 'post-migration-change'), 'new content retained')
    Invoke-RollbackTransaction $success.Source
    Assert-Test ([IO.File]::Exists((Join-Path $success.Target 'post-migration-change'))) 'Rollback retains post-migration Target data'
    Assert-Test (-not (Test-ReparseEntry (Get-PathEntry $success.Source))) 'Rollback restores a real Source directory'
    $existingBackup = New-FixturePair 'ExistingBackup'
    [void][IO.Directory]::CreateDirectory($existingBackup.Backup)
    Assert-Test (-not (Get-MoveAnalysis $existingBackup.Source $existingBackup.Target).Valid) 'Existing backup refused'
    $missing = New-FixturePair 'InterruptedAfterRename'
    [IO.Directory]::Move($missing.Source, $missing.Backup)
    Assert-Test (Get-RecoveryInfo $missing.Source).MissingSource 'Interrupted rename recovery detected'
    Invoke-RollbackTransaction $missing.Source
    Assert-Test ([IO.File]::Exists($missing.File)) 'Recovery restores missing Source'
    $broken = New-FixturePair 'UnavailableTarget'
    [void][IO.Directory]::CreateDirectory($broken.Target)
    [IO.Directory]::Move($broken.Source, $broken.Backup)
    New-VerifiedJunction $broken.Source $broken.Target
    # Only an empty test target is removed, non-recursively, to make a dangling link.
    [IO.Directory]::Delete($broken.Target, $false)
    Invoke-RollbackTransaction $broken.Source
    Assert-Test ([IO.File]::Exists($broken.File)) 'Rollback restores backup with unavailable junction target'
    $renameFailure = New-FixturePair 'RenameFailure'
    Set-Item -LiteralPath Function:\Invoke-MoveTransaction -Value ([scriptblock]::Create($nativeMove.ToString().Replace('[IO.Directory]::Move($analysis.Source, $analysis.Backup)', "throw 'Injected rename failure'")))
    Assert-Throws { Invoke-MoveTransaction $renameFailure.Source $renameFailure.Target } 'Rename failure reported'
    Assert-Test ([IO.File]::Exists($renameFailure.File) -and -not [IO.Directory]::Exists($renameFailure.Backup)) 'Rename failure leaves Source in place'
    Set-Item -LiteralPath Function:\Invoke-MoveTransaction -Value $nativeMove
    foreach ($failureMode in @('Create', 'Verify')) {
        $failed = New-FixturePair ('Fail' + $failureMode)
        if ($failureMode -eq 'Create') {
            function New-VerifiedJunction { param($Source, $Target); throw 'Injected creation failure' }
        } else {
            function New-VerifiedJunction { param($Source, $Target); & $nativeJunction $Source $Target; throw 'Injected verification failure' }
        }
        Assert-Throws { Invoke-MoveTransaction $failed.Source $failed.Target } "$failureMode failure reported"
        Assert-Test ([IO.File]::Exists($failed.File) -and -not (Test-ReparseEntry (Get-PathEntry $failed.Source))) "$failureMode failure restores original Source"
        Assert-Test ([IO.File]::Exists((Join-Path $failed.Target 'payload [1].txt'))) "$failureMode failure retains Target"
        Set-Item -LiteralPath Function:\New-VerifiedJunction -Value $nativeJunction
    }
    $cancelled = New-FixturePair 'Cancel'
    function Request-OperationConfirmation { param([string]$Text); return $false }
    Invoke-MoveTransaction $cancelled.Source $cancelled.Target
    Assert-Test (-not [IO.Directory]::Exists($cancelled.Target)) 'Cancel confirmation makes no Target'
    function Request-OperationConfirmation { param([string]$Text); return $true }
    $noSpace = New-FixturePair 'NoSpace'
    function Get-FixedNtfsVolume { param($Path); $v = & $nativeVolume $Path; $v.Free = 0; return $v }
    Assert-Test (-not (Get-MoveAnalysis $noSpace.Source $noSpace.Target).Valid) 'Simulated insufficient space refused'
    Set-Item -LiteralPath Function:\Get-FixedNtfsVolume -Value $nativeVolume
    $logFailure = New-FixturePair 'JournalFailure'
    function Save-TransactionState { param($Transaction, $Stage); if ($Stage -eq 'BackupCreated') { throw 'Injected journal failure' }; & $nativeState $Transaction $Stage }
    Assert-Throws { Invoke-MoveTransaction $logFailure.Source $logFailure.Target } 'Journal failure reported'
    Assert-Test ([IO.File]::Exists($logFailure.File)) 'Recovery still runs when journaling fails after rename'
} finally {
    Set-Item -LiteralPath Function:\Invoke-RobocopyPass -Value $nativeRobo
    Set-Item -LiteralPath Function:\Request-OperationConfirmation -Value $nativeConfirm
    Set-Item -LiteralPath Function:\New-VerifiedJunction -Value $nativeJunction
    Set-Item -LiteralPath Function:\Get-FixedNtfsVolume -Value $nativeVolume
    Set-Item -LiteralPath Function:\Save-TransactionState -Value $nativeState
    Set-Item -LiteralPath Function:\Stop-RelatedProcessesWithConsent -Value $nativeProcesses
    Set-Item -LiteralPath Function:\Invoke-MoveTransaction -Value $nativeMove
}

# Exercise the actual GUI worker script in an independent runspace, without a window/UAC.
$workerAssignment = $ast.Find({ param($node) $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$workerCode' }, $true)
$workerText = $workerAssignment.Right.Extent.Text
$workerText = $workerText.Substring(1, $workerText.Length - 2)
$runspace = [RunspaceFactory]::CreateRunspace(); $runspace.Open()
$worker = [PowerShell]::Create(); $worker.Runspace = $runspace
try {
    [void]$worker.AddScript($workerText).AddArgument($scriptPath).AddArgument($script:Context).AddArgument('Analyze').AddArgument($pair.Source).AddArgument($pair.Target)
    $async = $worker.BeginInvoke()
    if (-not $async.AsyncWaitHandle.WaitOne(30000)) { $worker.Stop(); throw 'Worker timed out' }
    [void]$worker.EndInvoke($async)
    Assert-Test (-not $worker.HadErrors) ('Background worker executes: ' + ($worker.Streams.Error | Out-String))
    $messages = $script:Context.Queue.ToArray()
    Assert-Test (@($messages | Where-Object Kind -eq 'Analysis').Count -gt 0) 'Worker shares analysis result with UI queue'
} finally { $worker.Dispose(); $runspace.Dispose() }

# Run the actual WPF handlers/timer without displaying a window. Only replace
# ShowDialog with a DispatcherFrame; the event wiring and worker remain intact.
# Support shell launches are replaced with an association failure; tests never
# open a browser/mail client or create their runtime files outside the sandbox.
$headless = ${function:Start-JunctionWindow}.ToString().Replace('try { [void]$script:Window.ShowDialog() }', @'
try {
    $script:Ui.WebsiteLink.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Documents.Hyperlink]::ClickEvent))
    Assert-Test ($script:Ui.Status.Text -like '*Injected shell association failure*') 'Website shell failure is caught without closing WPF'
    $script:Ui.EmailLink.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Documents.Hyperlink]::ClickEvent))
    Assert-Test ($script:Ui.Status.Text -like '*Injected shell association failure*') 'Email shell failure is caught without closing WPF'
    $script:Ui.SourceBox.Text = $pair.Source
    $script:Ui.TargetBox.Text = $pair.Target
    $script:Ui.AnalyzeButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
    Assert-Test $script:Busy 'WPF Analyze starts asynchronously'
    Assert-Test (-not $script:Ui.MoveButton.IsEnabled) 'WPF Move disabled during work'
    $frame = [Windows.Threading.DispatcherFrame]::new()
    $timeout = [Diagnostics.Stopwatch]::StartNew()
    $frameTimer = [Windows.Threading.DispatcherTimer]::new()
    $frameTimer.Interval = [TimeSpan]::FromMilliseconds(100)
    $frameTimer.Add_Tick({ if (-not $script:Busy -or $timeout.Elapsed.TotalSeconds -gt 20) { $frame.Continue = $false } })
    $frameTimer.Start()
    try { [Windows.Threading.Dispatcher]::PushFrame($frame) } finally { $frameTimer.Stop() }
    Assert-Test (-not $script:Busy) 'WPF timer receives completed worker'
    Assert-Test ($null -ne $script:LastAnalysis) 'WPF analysis panel receives result'
    $script:Ui.CandidatesGrid.ItemsSource = @([pscustomobject]@{ Type='Install'; Name='Fixture'; Path=$pair.Source; Running=$false; Size='Unknown'; Publisher=''; Reason='Synthetic'; IsDirectory=$true })
    $script:Ui.CandidatesGrid.SelectedIndex = 0
    Assert-Test $script:Ui.UseSource.IsEnabled 'WPF candidate selection enables Use as Source'
    $script:Ui.UseSource.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
    Assert-Test ($script:Ui.SourceBox.Text -eq $pair.Source -and $null -eq $script:LastAnalysis) 'WPF candidate selection populates Source and invalidates Analyze'
    $script:Busy = $true; $script:Operation = 'Move'; Update-Buttons
    Assert-Test (-not $script:Ui.ClearLogs.IsEnabled -and -not $script:Ui.DeleteBackup.IsEnabled -and -not $script:Ui.CancelScan.IsEnabled) 'WPF maintenance disabled during migration'
    $script:Operation = 'Discovery'; Update-Buttons
    Assert-Test $script:Ui.CancelScan.IsEnabled 'WPF Cancel Scan enabled only for read-only work'
    $script:Busy = $false; Update-Buttons
    $script:Ui.TargetBox.Text = $pair.Target + '-changed'
    Assert-Test ($null -eq $script:LastAnalysis -and -not $script:Ui.MoveButton.IsEnabled) 'Editing paths invalidates WPF validation'
    $script:Window.Close()
}
'@).Replace('[void][Diagnostics.Process]::Start($startInfo)', "throw 'Injected shell association failure'")
& ([scriptblock]::Create($headless)) $scriptPath
Write-Output "Completed $script:passed regression checks."

} finally {
    Set-Item -LiteralPath Function:\Get-FixedNtfsVolume -Value $originalVolume
    try {
        Remove-TestSandboxSafely $sandbox
        Write-Output 'Cleanup verified: no test fixture remains.'
    } catch {
        Write-Output ("Cleanup incomplete:`r`n" + $sandbox.Root + "`r`n" + $_.Exception.Message)
        throw
    }
}
