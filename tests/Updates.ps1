#Requires -Version 5.1
# Offline only: replace the HTTP boundary and all browser launches in memory or
# in the owned host copy. No request is sent even when production is configured.
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
$nativeGet = ${function:Invoke-UpdateMetadataGet}
$nativeOpen = ${function:Open-TrustedUpdateUri}
try {
    $script:requestCount = 0
    $script:responseMode = 'Json'
    $fixtureJson = Join-Path $sandbox.Root 'version.json'
    $fakeEndpoint = 'https://nemoforge.github.io/version.json'
    function Set-RemoteFixture {
        param($Version, [hashtable]$Extra = @{})
        $data = @{ product = $script:AppInfo.Name; version = $Version; downloadUrl = $script:AppInfo.RepositoryUrl; notes = 'Plain text release notes.' }
        foreach ($key in $Extra.Keys) { $data[$key] = $Extra[$key] }
        [IO.File]::WriteAllText($fixtureJson, ($data | ConvertTo-Json -Compress), [Text.Encoding]::UTF8)
    }
    function Invoke-UpdateMetadataGet {
        param([Uri]$Uri)
        $script:requestCount++
        if ($script:responseMode -eq 'Timeout') { throw [TimeoutException]::new('Synthetic timeout') }
        if ($script:responseMode -eq 'Connection') { throw [Net.WebException]::new('Synthetic connection failure') }
        return [IO.File]::ReadAllText($fixtureJson, [Text.Encoding]::UTF8)
    }
    foreach ($case in @(
        @('1.0.0','V1.0.0','UpToDate'), @('V1.0.0','1.0.1','UpdateAvailable'),
        @('1.0.0','V1.1.0','UpdateAvailable'), @('1.0.0','2.0.0','UpdateAvailable'),
        @('V1.9.9','V1.10.0','UpdateAvailable'), @('V2.0.0','V1.9.9','Ahead'))) {
        Set-RemoteFixture $case[1]
        $result = Get-UpdateStatus -Endpoint $fakeEndpoint -CurrentVersion $case[0]
        Assert-Test ($result.State -eq $case[2]) ("Version {0} -> {1}: {2}" -f $case)
        if ($case[2] -eq 'Ahead') { Assert-Test (-not $result.DownloadUrl -and -not $result.ReleaseNotesUrl) 'Older release never offers downgrade links' }
    }
    Assert-Test ((Compare-AppVersion 'v1.9.9' 'V1.10.0') -gt 0) 'Numeric comparison normalizes both V/v prefixes'
    foreach ($badVersion in @('banana','1.0','1.0.0-beta','1.0.0.0','01.0.0',('9' * 33),42,@('1.0.0'))) {
        Assert-Throws { ConvertTo-AppVersion $badVersion } ('Reject invalid version: ' + ($badVersion -join ','))
    }
    foreach ($badJson in @('{broken','{}','{"product":"Junction Manager"}','[]','[{"version":"1.0.0"}]','null','"1.0.0"','{"version":5}','{"version":"bad"}')) {
        [IO.File]::WriteAllText($fixtureJson, $badJson)
        Assert-Test ((Get-UpdateStatus $fakeEndpoint).State -eq 'Invalid') ('Reject invalid metadata: ' + $badJson)
    }
    foreach ($invalidFields in @(
        @{product='Different app'}, @{notes=('x' * 2001)}, @{notes=@{ command='ignored' }},
        @{downloadUrl='http://nemoforge.github.io/'}, @{downloadUrl='file:///C:/evil.ps1'},
        @{downloadUrl='https://attacker.example/'}, @{releaseNotesUrl='javascript:alert(1)'},
        @{downloadUrl=('https://nemoforge.github.io/' + ('x' * 2048))})) {
        Set-RemoteFixture '1.0.1' $invalidFields
        Assert-Test ((Get-UpdateStatus $fakeEndpoint).State -eq 'Invalid') ('Reject unsafe field: ' + ($invalidFields.Keys -join ','))
    }
    [IO.File]::WriteAllText($fixtureJson, ('{"version":"1.0.1","extra":"' + ('x' * 16384) + '"}'))
    Assert-Test ((Get-UpdateStatus $fakeEndpoint).State -eq 'Invalid') 'Oversized response rejected'
    Set-RemoteFixture '1.0.1' @{notes='<Button Click="run">$(command)</Button>';Source='C:\DoNotUse';LogRoot='C:\DoNotUse'}
    $result = Get-UpdateStatus $fakeEndpoint
    Assert-Test ($result.Notes -ceq '<Button Click="run">$(command)</Button>' -and 'Source' -notin @($result.PSObject.Properties.Name)) 'Remote notes remain literal text and unknown path fields are ignored'
    [IO.File]::WriteAllText($fixtureJson, '{"version":"1.0.1"}')
    $result = Get-UpdateStatus $fakeEndpoint
    Assert-Test ($result.State -eq 'UpdateAvailable' -and -not $result.DownloadUrl) 'Optional product/links/notes may be absent'
    foreach ($uri in @($script:AppInfo.RepositoryUrl, ($script:AppInfo.RepositoryUrl + '/releases/latest'), 'https://nemoforge.github.io/')) {
        Assert-Test ((ConvertTo-TrustedUpdateUri $uri).Scheme -eq 'https') ('Official HTTPS page accepted: ' + $uri)
    }
    foreach ($uri in @('http://nemoforge.github.io/', 'file:///C:/evil.ps1', 'ftp://nemoforge.github.io/', 'javascript:alert(1)',
        'https://nemoforge.github.io.attacker.example/', 'https://attacker@nemoforge.github.io/', 'https://nemoforge.github.io:444/',
        'https://nemoforge.github.io/?user=x', 'https://nemoforge.github.io/evil.ps1', 'https://github.com/other/repo',
        ($script:AppInfo.RepositoryUrl + '/releases/download/v1/app.exe'), 'https://nemoforge.github.io/%2Fevil', 'https://nemoforge.github.io/ bad')) {
        Assert-Throws { ConvertTo-TrustedUpdateUri $uri } ('Reject unsafe page: ' + $uri)
    }
    Assert-Test ((ConvertTo-TrustedUpdateUri 'https://raw.githubusercontent.com/nemoforge/Junction-Manager/main/version.json' 'Metadata').Scheme -eq 'https') 'Repository raw JSON allowed for metadata only'
    Assert-Throws { ConvertTo-TrustedUpdateUri 'https://raw.githubusercontent.com/other/repo/main/version.json' 'Metadata' } 'Other repository metadata rejected'
    Assert-Throws { ConvertTo-TrustedUpdateUri 'https://raw.githubusercontent.com/nemoforge/Junction-Manager/main/version.json' 'Page' } 'Raw metadata cannot be launched as a download page'
    $beforeRequests = $script:requestCount
    Assert-Test ((Get-UpdateStatus -Endpoint '').State -eq 'NotConfigured') 'Unconfigured endpoint explains setup'
    Assert-Test ((Get-UpdateStatus -Endpoint 'http://nemoforge.github.io/version.json').State -eq 'Invalid') 'Insecure endpoint is invalid'
    Assert-Test ($script:requestCount -eq $beforeRequests) 'Invalid/unconfigured endpoints make no HTTP request'
    foreach ($mode in @('Timeout','Connection')) {
        $script:responseMode = $mode
        Assert-Test ((Get-UpdateStatus $fakeEndpoint).State -eq 'Unavailable') ("$mode failure is non-fatal")
    }
    $script:responseMode = 'Json'; Set-RemoteFixture '1.0.1'
    $snapshot = Get-TreeSnapshot $sandbox.Root -Hash
    [void](Get-UpdateStatus $fakeEndpoint)
    Assert-SnapshotsEqual $snapshot (Get-TreeSnapshot $sandbox.Root -Hash)
    Assert-Test $true 'Update logic reads fixture without filesystem mutation'
    Set-Item -LiteralPath Function:\Open-TrustedUpdateUri -Value ([scriptblock]::Create($nativeOpen.ToString().Replace('[void][Diagnostics.Process]::Start($startInfo)', "throw 'Synthetic browser association failure'")))
    Assert-Test ((Open-TrustedUpdateUri $script:AppInfo.RepositoryUrl) -like 'Unable*') 'Browser association failure is non-fatal'
    Assert-Test ((Open-TrustedUpdateUri 'file:///C:/evil.ps1') -like 'Unable*') 'Browser boundary revalidates untrusted URLs'

    # The real worker loads only a sandbox copy with an offline HTTP override.
    $hostFolder = Join-Path $sandbox.Root 'Host'
    [void][IO.Directory]::CreateDirectory($hostFolder)
    foreach ($name in @('Junction.ps1','Junction.Discovery.ps1','Junction.Maintenance.ps1','Junction.Update.ps1')) {
        Copy-Item -LiteralPath (Join-Path $repo $name) -Destination (Join-Path $hostFolder $name) -ErrorAction Stop
    }
    $offlineOverride = @'

function Invoke-UpdateMetadataGet {
    param([Uri]$Uri)
    $script:Context.TestRequests++
    if ($script:Context.TestMode -eq 'Timeout') { throw [TimeoutException]::new('Synthetic timeout') }
    return $script:Context.TestJson
}
'@
    [IO.File]::AppendAllText((Join-Path $hostFolder 'Junction.Update.ps1'), $offlineOverride, [Text.Encoding]::UTF8)
    $uiTest = @'
try {
    $script:Context.TestRequests = 0
    $script:Context.TestMode = 'Timeout'
    $script:Context.TestJson = '{"version":"1.0.1","downloadUrl":"https://github.com/nemoforge/Junction-Manager","releaseNotesUrl":"https://github.com/nemoforge/Junction-Manager/releases","notes":"<Button>literal</Button>"}'
    $script:AppInfo.UpdateMetadataUrl = 'https://nemoforge.github.io/version.json'
    $script:Ui.SourceBox.Text = Join-Path $sandbox.Root 'Source'
    $script:Ui.TargetBox.Text = Join-Path $sandbox.Root 'Target'
    $preservedAnalysis = [pscustomobject]@{ Valid=$false; Recovery=$null; TargetExists=$false; ManagedBackup=$null }
    $script:LastAnalysis = $preservedAnalysis
    $script:Ui.AboutButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
    Assert-Test ($script:Context.TestRequests -eq 0 -and -not $script:Busy) 'Startup and opening About make no network request'
    function Wait-UiCompletion {
        $frame = [Windows.Threading.DispatcherFrame]::new()
        $timeout = [Diagnostics.Stopwatch]::StartNew()
        $pulse = [Windows.Threading.DispatcherTimer]::new()
        $pulse.Interval = [TimeSpan]::FromMilliseconds(50)
        $pulse.Add_Tick({ if (-not $script:Busy -or $timeout.Elapsed.TotalSeconds -gt 15) { $frame.Continue = $false } })
        $pulse.Start()
        try { [Windows.Threading.Dispatcher]::PushFrame($frame) } finally { $pulse.Stop() }
        if ($script:Busy) { throw 'Update worker timed out in offline UI test.' }
    }
    $script:About.CheckButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
    Assert-Test ($script:Busy -and -not $script:About.CheckButton.IsEnabled) 'Check starts in background and disables repeated requests'
    $script:About.CheckButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
    Wait-UiCompletion
    Assert-Test ($script:Context.TestRequests -eq 1) 'Double-click triggers only one HTTP request'
    Assert-Test ($script:About.CheckButton.IsEnabled -and $script:About.Result.State -eq 'Unavailable') 'UI state restored after timeout'
    Assert-Test ([object]::ReferenceEquals($preservedAnalysis,$script:LastAnalysis) -and $script:Ui.SourceBox.Text -eq (Join-Path $sandbox.Root 'Source') -and $script:Ui.TargetBox.Text -eq (Join-Path $sandbox.Root 'Target')) 'Update failure preserves Analyze and Source/Target state'
    $script:Context.TestMode = 'Json'
    $script:About.CheckButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
    Wait-UiCompletion
    Assert-Test ($script:About.Result.State -eq 'UpdateAvailable' -and $script:About.DownloadButton.IsEnabled -and $script:About.NotesButton.IsEnabled) 'New release enables page links after completion'
    Assert-Test ($script:About.Notes.Text -ceq '<Button>literal</Button>') 'WPF shows remote notes as plain text'
    Assert-Test ([object]::ReferenceEquals($preservedAnalysis,$script:LastAnalysis)) 'Successful update check preserves Analyze state'
    $script:Context.TestJson = '{"version":"0.9.0","downloadUrl":"https://github.com/nemoforge/Junction-Manager"}'
    $script:About.CheckButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
    Assert-Test (-not $script:About.DownloadButton.IsEnabled) 'Starting a new check clears stale download link'
    Wait-UiCompletion
    Assert-Test ($script:About.Result.State -eq 'Ahead' -and -not $script:About.DownloadButton.IsEnabled) 'Older metadata offers no downgrade through UI'
    $script:Busy = $true; $script:Operation = 'Move'; Update-Buttons
    Assert-Test (-not $script:About.CheckButton.IsEnabled) 'Update check disabled while migration runs'
    $script:Busy = $false; $script:Operation = ''; Update-Buttons
    $script:About.Window.Close()
    $script:Window.Close()
}
'@
    $headless = ${function:Start-JunctionWindow}.ToString().Replace('try { [void]$script:Window.ShowDialog() }', $uiTest).Replace('$script:About.Window.Show()', '$null = $script:About.Window')
    & ([scriptblock]::Create($headless)) (Join-Path $hostFolder 'Junction.ps1')
    Write-Output "Completed $script:passed offline update checks."
} finally {
    Set-Item -LiteralPath Function:\Invoke-UpdateMetadataGet -Value $nativeGet
    Set-Item -LiteralPath Function:\Open-TrustedUpdateUri -Value $nativeOpen
    try {
        Remove-TestSandboxSafely $sandbox
        Write-Output 'Cleanup verified: no test fixture remains.'
    } catch {
        Write-Output ("Cleanup incomplete:`r`n" + $sandbox.Root + "`r`n" + $_.Exception.Message)
        throw
    }
}
