# Read-only discovery. No commands from the registry or discovered executables are run.
function Write-DiscoveryMessage {
    param([string]$Text, [string]$Level = 'INFO')
    $line = '[{0}] {1} {2}' -f (Get-Date -Format 'HH:mm:ss'), $Level, $Text
    if ($null -ne $script:Context) {
        $script:Context.Queue.Enqueue([pscustomobject]@{ Kind = 'Log'; Text = $line })
    } else { Write-Verbose $line }
}
function Test-DiscoveryCancelled {
    return $null -ne $script:Context -and $script:Context.ContainsKey('CancelDiscovery') -and $script:Context.CancelDiscovery
}
function Get-AppSearchTokens {
    param([string[]]$Text)
    $generic = @('bin','x64','x86','win64','current','latest','app','program','programs','data','cache','temp','update','updater',
        'exe','inc','ltd','llc','corporation','company','software','technologies','application','setup','installer','uninstall')
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($value in $Text) {
        if ([string]::IsNullOrWhiteSpace($value)) { continue }
        $normal = ($value.Trim() -replace '(?i)\.exe$', '' -replace '[\s_.-]+', ' ').ToLowerInvariant()
        foreach ($token in @($normal) + @($normal.Split(' '))) {
            if ($token.Length -ge 3 -and $token -notin $generic -and $token -match '\p{L}' -and $seen.Add($token)) { $token }
        }
    }
}
function ConvertFrom-DisplayIcon {
    param([string]$Value)
    # Extract a path only; never evaluate an UninstallString or icon command.
    if ($Value -match '^\s*"([^"]+\.exe)"' -or $Value -match '^\s*(.+?\.exe)(?:\s*,\s*-?\d+)?\s*$') {
        try { return ConvertTo-LocalPath ([Environment]::ExpandEnvironmentVariables($Matches[1])) }
        catch { Write-Verbose "Unusable DisplayIcon path: $($_.Exception.Message)" }
    }
    return ''
}
function Merge-InstalledApplications {
    param([object[]]$Applications)
    $map = @{}
    foreach ($app in $Applications) {
        if ([string]::IsNullOrWhiteSpace($app.DisplayName)) { continue }
        $key = ('{0}|{1}|{2}' -f $app.DisplayName.Trim(), $app.DisplayVersion, $app.Publisher).ToLowerInvariant()
        if (-not $map.ContainsKey($key) -or (-not $map[$key].InstallLocation -and $app.InstallLocation)) { $map[$key] = $app }
    }
    return @($map.Values | Sort-Object @{ Expression = { -not [bool]$_.InstallLocation } }, DisplayName)
}
function Get-InstalledApplication {
    $apps = [Collections.Generic.List[object]]::new()
    $unreadable = 0
    $views = @(
        @{ Hive = [Microsoft.Win32.RegistryHive]::LocalMachine; View = [Microsoft.Win32.RegistryView]::Registry64 },
        @{ Hive = [Microsoft.Win32.RegistryHive]::LocalMachine; View = [Microsoft.Win32.RegistryView]::Registry32 },
        @{ Hive = [Microsoft.Win32.RegistryHive]::CurrentUser; View = [Microsoft.Win32.RegistryView]::Default })
    foreach ($view in $views) {
        $base = $null; $uninstall = $null
        try {
            $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey($view.Hive, $view.View)
            $uninstall = $base.OpenSubKey('Software\Microsoft\Windows\CurrentVersion\Uninstall', $false)
            if ($null -eq $uninstall) { continue }
            foreach ($name in $uninstall.GetSubKeyNames()) {
                if (Test-DiscoveryCancelled) { break }
                $key = $null
                try {
                    $key = $uninstall.OpenSubKey($name, $false)
                    if ($null -eq $key) { continue }
                    $displayName = [string]$key.GetValue('DisplayName', '')
                    if (-not $displayName) { continue }
                    $apps.Add([pscustomobject]@{ DisplayName = $displayName
                        DisplayVersion = [string]$key.GetValue('DisplayVersion', ''); Publisher = [string]$key.GetValue('Publisher', '')
                        InstallLocation = [string]$key.GetValue('InstallLocation', '')
                        DisplayIcon = (ConvertFrom-DisplayIcon ([string]$key.GetValue('DisplayIcon', '')))
                        UninstallString = [string]$key.GetValue('UninstallString', '') })
                } catch { $unreadable++; Write-Verbose $_.Exception.Message }
                finally { if ($null -ne $key) { $key.Dispose() } }
            }
        } catch { $unreadable++; Write-Verbose $_.Exception.Message }
        finally {
            if ($null -ne $uninstall) { $uninstall.Dispose() }
            if ($null -ne $base) { $base.Dispose() }
        }
    }
    if ($unreadable) { Write-DiscoveryMessage "$unreadable registry entries/views could not be read." 'WARN' }
    return Merge-InstalledApplications $apps.ToArray()
}
function Get-DiscoveryRoots {
    $local = [Environment]::GetFolderPath('LocalApplicationData')
    $programFiles = [Environment]::GetFolderPath('ProgramFiles')
    $windows = [Environment]::GetFolderPath('Windows')
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($root in @(
        @{ Path = $programFiles; Kind = 'Install' },
        @{ Path = [Environment]::GetFolderPath('ProgramFilesX86'); Kind = 'Install' },
        @{ Path = (Join-Path $local 'Programs'); Kind = 'Install' },
        @{ Path = $local; Kind = 'Data' },
        @{ Path = [Environment]::GetFolderPath('ApplicationData'); Kind = 'Data' },
        @{ Path = (Join-Path $windows 'System32'); Kind = 'System' },
        @{ Path = (Join-Path $windows 'SysWOW64'); Kind = 'System' },
        @{ Path = (Join-Path $programFiles 'WindowsApps'); Kind = 'Packaged App' })) {
        if ($root.Path -and $seen.Add($root.Path)) { [pscustomobject]$root }
    }
}
function Get-DiscoveryProcesses {
    $unreadable = 0
    foreach ($process in @(Get-Process -ErrorAction Stop)) {
        try {
            if (Test-DiscoveryCancelled) { break }
            $path = $process.Path
            if ($path) { [pscustomobject]@{ Name = $process.ProcessName; Path = $path; Id = $process.Id } }
            else { $unreadable++ }
        } catch { $unreadable++; Write-Verbose $_.Exception.Message }
        finally { $process.Dispose() }
    }
    if ($unreadable) { Write-DiscoveryMessage "$unreadable processes could not be fully inspected." 'WARN' }
}
function Get-ExecutableMetadata {
    param([string]$Path)
    try {
        $info = [Diagnostics.FileVersionInfo]::GetVersionInfo($Path)
        return [pscustomobject]@{ ProductName = $info.ProductName; FileDescription = $info.FileDescription
            CompanyName = $info.CompanyName; OriginalFilename = $info.OriginalFilename
            InternalName = $info.InternalName; FileVersion = $info.FileVersion }
    } catch { Write-Verbose "Metadata unavailable: $($_.Exception.Message)"; return $null }
}
function Get-AppSignalScore {
    param([string]$Value, $Tokens)
    $valueNormal = ($Value -replace '(?i)\.exe$', '' -replace '[\s_.-]+', ' ').Trim().ToLowerInvariant()
    $score = 0
    foreach ($token in $Tokens.Keys) {
        if ($valueNormal -eq $token) { $score = [Math]::Max($score, 60 + $Tokens[$token]) }
        elseif ($valueNormal.StartsWith($token, [StringComparison]::OrdinalIgnoreCase)) { $score = [Math]::Max($score, 35 + $Tokens[$token]) }
        elseif ($valueNormal.IndexOf($token, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $score = [Math]::Max($score, 10 + $Tokens[$token]) }
    }
    return $score
}
function Add-AppIdentityTokens {
    param($State, [string[]]$Names, [int]$Weight = 0)
    foreach ($token in @(Get-AppSearchTokens $Names)) {
        if ($State.Tokens.Count -ge 40) { break }
        if (-not $State.Tokens.ContainsKey($token) -or $State.Tokens[$token] -lt $Weight) { $State.Tokens[$token] = $Weight }
    }
}
function Test-DiscoveryBudget {
    param($State)
    if (Test-DiscoveryCancelled) { $State.Cancelled = $true; return $false }
    if ($State.Watch.Elapsed.TotalSeconds -gt $State.MaxSeconds -or $State.Entries -ge 20000 -or $State.Directories -ge 1500) { $State.Limited = $true; return $false }
    return $true
}
function Get-DiscoveryChildren {
    param([string]$Path, $State)
    if (-not (Test-DiscoveryBudget $State)) { return }
    try {
        Assert-PlainAncestors $Path
        $State.Directories++
        # Lazy enumeration bounds even a directory with millions of entries.
        foreach ($child in [IO.Directory]::EnumerateFileSystemEntries($Path)) {
            if (-not (Test-DiscoveryBudget $State)) { break }
            $State.Entries++
            try { Get-Item -LiteralPath $child -Force -ErrorAction Stop }
            catch { $State.Unreadable++; Write-Verbose $_.Exception.Message }
        }
    } catch { $State.Unreadable++; Write-Verbose $_.Exception.Message }
}
function Add-AppCandidate {
    param($State, [string]$Path, [int]$Score, [string]$Reason, [string]$Publisher = '', [string]$DisplayName = '')
    if (-not $Path -or $State.Candidates.Count -ge 250 -or -not (Test-DiscoveryBudget $State)) { return }
    try {
        $pathNormal = ConvertTo-LocalPath $Path
        $entry = Get-PathEntry $pathNormal
        if ($null -eq $entry) { return }
        $running = $false
        foreach ($processPath in $State.ProcessPaths) {
            if (($entry.PSIsContainer -and (Test-PathWithin $processPath $pathNormal)) -or $processPath -eq $pathNormal) { $running = $true; break }
        }
        $type = if ($entry.PSIsContainer) { 'Install' } else { 'Application' }
        $warning = ''
        # More specific roots override broader ones (Local\Programs is Install,
        # even though it is also under LocalAppData).
        foreach ($root in @($State.Roots | Sort-Object { $_.Path.Length })) {
            if (Test-PathWithin $pathNormal $root.Path) {
                if ($root.Kind -eq 'System') { $type = 'System'; $warning = 'Windows system location - not recommended as migration Source.' }
                elseif ($root.Kind -eq 'Packaged App') { $type = 'Packaged App'; $warning = 'Packaged/MSIX application - migration by folder junction may be unsupported or unsafe.' }
                elseif ($root.Kind -eq 'Data' -and $entry.PSIsContainer) { $type = 'Data' }
                elseif ($root.Kind -eq 'Install' -and $entry.PSIsContainer) { $type = 'Install' }
            }
        }
        if (-not $warning -and $entry.PSIsContainer) {
            if ($entry.Name -match '(?i)updat') { $type = 'Updater' }
            elseif ($entry.Name -match '(?i)cache|temp') { $type = 'Cache' }
        }
        if ($warning) { $Reason += '; ' + $warning }
        if ($State.Candidates.ContainsKey($pathNormal)) {
            $existing = $State.Candidates[$pathNormal]
            $existing.Score = [Math]::Max($Score, $existing.Score)
            if (-not $existing.Reason.Contains($Reason)) { $existing.Reason += '; ' + $Reason }
            $existing.Running = $existing.Running -or $running
            if ($Publisher) { $existing.Publisher = $Publisher }
            return
        }
        if (-not $DisplayName) { $DisplayName = $entry.Name }
        $size = if ($entry.PSIsContainer) { 'Unknown' } else { '{0:N2} MiB' -f ($entry.Length / 1MB) }
        $State.Candidates[$pathNormal] = [pscustomobject]@{ Type = $type; Name = $DisplayName; Path = $pathNormal
            Running = $running; Size = $size; Publisher = $Publisher; Reason = $Reason; Score = $Score
            IsDirectory = [bool]$entry.PSIsContainer }
    } catch { $State.Unreadable++; Write-Verbose $_.Exception.Message }
}
function Add-ExecutableIdentity {
    param($State, [string]$Path, [int]$Score, [string]$Reason)
    $metadata = Get-ExecutableMetadata $Path
    $publisher = ''; $name = ''
    if ($null -ne $metadata) {
        $publisher = $metadata.CompanyName; $name = $metadata.ProductName
        Add-AppIdentityTokens $State @($metadata.ProductName, $metadata.FileDescription, $metadata.InternalName) 5
        Add-AppIdentityTokens $State @($metadata.CompanyName) -10
    }
    Add-AppCandidate $State $Path $Score $Reason $publisher $name
    $parent = [IO.Path]::GetDirectoryName($Path)
    Add-AppCandidate $State $parent ($Score - 5) 'Executable parent folder' $publisher
    # Infer two parents, excluding generic directory names and scan roots.
    $ancestor = $parent
    for ($level = 0; $level -lt 2 -and $ancestor; $level++) {
        if ($ancestor -notin @($State.Roots | ForEach-Object Path)) { Add-AppIdentityTokens $State @([IO.Path]::GetFileName($ancestor)) 0 }
        $ancestor = [IO.Path]::GetDirectoryName($ancestor)
    }
    foreach ($app in $State.Apps) {
        if ($app.DisplayIcon -eq $Path -or ($app.InstallLocation -and (Test-PathWithin $Path $app.InstallLocation))) {
            Add-AppIdentityTokens $State @($app.DisplayName) 10
            Add-AppIdentityTokens $State @($app.Publisher) -10
            Add-AppCandidate $State $app.InstallLocation 95 'Registry install location' $app.Publisher $app.DisplayName
        }
    }
}
function Publish-AppCandidates {
    param($State)
    if ($null -ne $script:Context) {
        # Copy rows; the worker never mutates objects already bound by WPF.
        $rows = @($State.Candidates.Values | Sort-Object @{Expression='Score';Descending=$true}, Path | Select-Object Type,Name,Path,Running,Size,Publisher,Reason,Score,IsDirectory)
        $script:Context.Queue.Enqueue([pscustomobject]@{ Kind = 'Candidates'; Data = $rows })
    }
}
function Find-AppLocations {
    param([string]$Query, $InstalledApplication = $null, [int]$MaxSeconds = 15)
    if ($null -ne $InstalledApplication) { $Query = $InstalledApplication.DisplayName }
    $queryTokens = @(Get-AppSearchTokens @($Query))
    if (-not $queryTokens.Count) { throw 'Enter an app/product name or executable name with at least three meaningful characters.' }
    $state = @{ Tokens = @{}; Candidates = @{}; Roots = @(Get-DiscoveryRoots); Apps = @(); ProcessPaths = @()
        Watch = [Diagnostics.Stopwatch]::StartNew(); MaxSeconds = [Math]::Min(30, [Math]::Max(1, $MaxSeconds))
        Entries = 0; Directories = 0; Unreadable = 0; Cancelled = $false; Limited = $false }
    Add-AppIdentityTokens $state @($Query) 20
    Write-DiscoveryMessage "Discovery started for '$Query' (read-only)."
    $state.Apps = @(Get-InstalledApplication)
    $processes = @(Get-DiscoveryProcesses)
    $state.ProcessPaths = @($processes | ForEach-Object Path)
    $exeName = $Query.Trim()
    if (-not $exeName.EndsWith('.exe', [StringComparison]::OrdinalIgnoreCase)) { $exeName += '.exe' }
    if ($exeName.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0) { $exeName = '' }
    foreach ($process in $processes) {
        if (-not (Test-DiscoveryBudget $state)) { break }
        if ((Get-AppSignalScore $process.Name $state.Tokens) -ge 55) { Add-ExecutableIdentity $state $process.Path 110 'Running executable' }
        else {
            $metadata = Get-ExecutableMetadata $process.Path
            if ($null -ne $metadata -and (Get-AppSignalScore $metadata.ProductName $state.Tokens) -ge 70) { Add-ExecutableIdentity $state $process.Path 100 'Running executable; ProductName match' }
        }
    }
    foreach ($app in $state.Apps) {
        if (-not (Test-DiscoveryBudget $state)) { break }
        if (($null -ne $InstalledApplication -and $app.DisplayName -eq $InstalledApplication.DisplayName) -or
            (Get-AppSignalScore $app.DisplayName $state.Tokens) -ge 55 -or ($exeName -and [IO.Path]::GetFileName($app.DisplayIcon) -eq $exeName)) {
            Add-AppIdentityTokens $state @($app.DisplayName) 10
            Add-AppIdentityTokens $state @($app.Publisher) -10
            Add-AppCandidate $state $app.InstallLocation 95 'Registry install location' $app.Publisher $app.DisplayName
            if ($app.DisplayIcon) { Add-ExecutableIdentity $state $app.DisplayIcon 80 'DisplayIcon; main executable candidate' }
        }
    }
    Publish-AppCandidates $state
    $topFolders = [Collections.Generic.List[object]]::new()
    $visited = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $pending = [Collections.Generic.Queue[object]]::new()
    # Registry/process locations are exact seeds, including installations outside the common roots.
    foreach ($candidate in @($state.Candidates.Values)) {
        if ($candidate.IsDirectory -and $candidate.Type -notin @('System','Packaged App')) { $pending.Enqueue(@{ Path = $candidate.Path; Depth = 1; Matched = $true }) }
    }
    foreach ($root in $state.Roots) {
        if (-not (Test-DiscoveryBudget $state)) { break }
        if ($root.Kind -eq 'System') {
            if ($exeName -and $Query.Trim().EndsWith('.exe', [StringComparison]::OrdinalIgnoreCase)) {
                $path = Join-Path $root.Path $exeName
                if ([IO.File]::Exists($path)) { Add-AppCandidate $state $path 75 'Exact system executable' }
            }
            continue
        }
        $beforeUnreadable = $state.Unreadable
        foreach ($entry in @(Get-DiscoveryChildren $root.Path $state)) {
            if ($entry.PSIsContainer) {
                $topFolders.Add($entry)
                $score = Get-AppSignalScore $entry.Name $state.Tokens
                if ($score -gt 0) { Add-AppCandidate $state $entry.FullName $score 'Folder name / related app token' }
                if ($root.Kind -ne 'Packaged App' -and -not (Test-ReparseEntry $entry) -and $entry.FullName -notin @($state.Roots | ForEach-Object Path)) {
                    $pending.Enqueue(@{ Path = $entry.FullName; Depth = 1; Matched = ($score -ge 35) })
                }
            } elseif ($exeName -and $entry.Name -eq $exeName) { Add-ExecutableIdentity $state $entry.FullName 85 'Exact executable name; main executable candidate' }
        }
        if ($root.Kind -eq 'Packaged App' -and $state.Unreadable -gt $beforeUnreadable) { Write-DiscoveryMessage 'WindowsApps could not be enumerated. Permissions were not changed.' 'WARN' }
    }
    while ($pending.Count -and (Test-DiscoveryBudget $state)) {
        $node = $pending.Dequeue()
        if (-not $visited.Add($node.Path)) { continue }
        # Specific EXE inputs get a bounded shallow search even when their product name is unknown.
        if (-not $node.Matched -and (-not $exeName -or $queryTokens[0].Length -lt 4)) { continue }
        $folderScore = Get-AppSignalScore ([IO.Path]::GetFileName($node.Path)) $state.Tokens
        if ($folderScore -gt 0) { Add-AppCandidate $state $node.Path $folderScore 'Related app token'; $node.Matched = $true }
        foreach ($entry in @(Get-DiscoveryChildren $node.Path $state)) {
            if (Test-ReparseEntry $entry) { continue }
            if ($entry.PSIsContainer) {
                if ($node.Depth -lt 3 -and $entry.FullName -notin @($state.Roots | ForEach-Object Path)) { $pending.Enqueue(@{ Path = $entry.FullName; Depth = ($node.Depth + 1); Matched = $node.Matched }) }
            } elseif ($entry.Extension -ieq '.exe') {
                if ($exeName -and $entry.Name -eq $exeName) { Add-ExecutableIdentity $state $entry.FullName 85 'Exact executable name; main executable candidate' }
                elseif ($node.Matched) {
                    $metadata = Get-ExecutableMetadata $entry.FullName
                    $score = Get-AppSignalScore $entry.BaseName $state.Tokens
                    $publisher = ''; $name = ''
                    if ($null -ne $metadata) {
                        $score = [Math]::Max($score, (Get-AppSignalScore $metadata.ProductName $state.Tokens))
                        $score = [Math]::Max($score, ((Get-AppSignalScore $metadata.FileDescription $state.Tokens) - 5))
                        $publisher = $metadata.CompanyName; $name = $metadata.ProductName
                    }
                    if ($score -ge 35) { Add-AppCandidate $state $entry.FullName ($score + 5) 'Executable metadata / name match; main executable candidate' $publisher $name }
                }
            }
        }
    }
    # Revisit already-read top-level names using canonical identity inferred from an unknown EXE.
    foreach ($entry in $topFolders) {
        $score = Get-AppSignalScore $entry.Name $state.Tokens
        if ($score -gt 0) { Add-AppCandidate $state $entry.FullName $score 'Related app token' }
    }
    if ($state.Unreadable) { Write-DiscoveryMessage "$($state.Unreadable) locations could not be inspected; scan continued without changing permissions." 'WARN' }
    if ($state.Limited) { Write-DiscoveryMessage 'Scan limit reached; results are partial. Use a more specific name or Installed Apps.' 'WARN' }
    if ($state.Cancelled) { Write-DiscoveryMessage 'Discovery cancelled; partial results retained.' }
    Write-DiscoveryMessage "$($state.Candidates.Count) candidate locations found. Classification is a hint; Analyze is still required."
    Publish-AppCandidates $state
    return @($state.Candidates.Values | Sort-Object @{Expression='Score';Descending=$true}, Path)
}
function Get-CandidateFolderSize {
    param([string]$Path)
    if ($Path -in @(Get-DiscoveryRoots | ForEach-Object Path) -or (Test-PathWithin $Path ([Environment]::GetFolderPath('Windows')))) { return 'Unknown (system/scan root)' }
    $state = @{ Watch = [Diagnostics.Stopwatch]::StartNew(); MaxSeconds = 5; Entries = 0; Directories = 0; Unreadable = 0; Cancelled = $false; Limited = $false }
    $pending = [Collections.Generic.Stack[string]]::new(); $pending.Push((ConvertTo-LocalPath $Path))
    [long]$bytes = 0
    while ($pending.Count -and (Test-DiscoveryBudget $state)) {
        foreach ($entry in @(Get-DiscoveryChildren $pending.Pop() $state)) {
            if (Test-ReparseEntry $entry) { $state.Unreadable++; continue }
            if ($entry.PSIsContainer) { $pending.Push($entry.FullName) } else { $bytes += $entry.Length }
        }
    }
    if ($state.Unreadable -or $state.Cancelled -or $state.Limited) { return 'Unknown (partial/unavailable)' }
    return ('~{0:N2} GiB (file data)' -f ($bytes / 1GB))
}
function Get-CandidateSourcePath {
    param($Candidate)
    $path = ConvertTo-LocalPath $Candidate.Path
    $entry = Get-PathEntry $path
    if ($null -eq $entry) { throw 'This candidate is no longer available.' }
    if ($entry.PSIsContainer) { return $path }
    return [IO.Path]::GetDirectoryName($path)
}
