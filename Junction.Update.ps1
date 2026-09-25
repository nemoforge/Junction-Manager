# Manual metadata checks only. Remote content never becomes code or a local path.
function ConvertTo-AppVersion {
    param($Value)
    if ($Value -isnot [string] -or $Value.Length -gt 32 -or $Value -cnotmatch '^[Vv]?(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$') {
        throw [FormatException]::new('Invalid stable application version.')
    }
    $parsed = $null
    if (-not [version]::TryParse(($Value -replace '^[Vv]', ''), [ref]$parsed)) { throw [FormatException]::new('Invalid application version components.') }
    return $parsed
}
function Compare-AppVersion {
    param($Current, $Remote)
    return (ConvertTo-AppVersion $Remote).CompareTo((ConvertTo-AppVersion $Current))
}
function ConvertTo-TrustedUpdateUri {
    param($Value, [ValidateSet('Metadata','Page')][string]$Purpose = 'Page')
    $uri = $null
    if ($Value -isnot [string] -or $Value.Length -gt 2048 -or $Value -match '[\s\\]' -or
        -not [Uri]::TryCreate($Value, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -ne 'https' -or
        -not $uri.IsDefaultPort -or $uri.UserInfo -or $uri.Query -or $uri.Fragment) {
        throw [FormatException]::new('An absolute trusted HTTPS URL without credentials, query or fragment is required.')
    }
    $repository = [Uri]$script:AppInfo.RepositoryUrl
    $repoPath = $repository.AbsolutePath.TrimEnd('/')
    $trusted = $uri.DnsSafeHost -eq $script:AppInfo.Website
    if ($Purpose -eq 'Metadata') {
        $trusted = $trusted -or ($uri.DnsSafeHost -eq 'raw.githubusercontent.com' -and $uri.AbsolutePath.StartsWith($repoPath + '/', [StringComparison]::Ordinal))
        $trusted = $trusted -and $uri.AbsolutePath.EndsWith('.json', [StringComparison]::OrdinalIgnoreCase)
    } else {
        if ($uri.DnsSafeHost -eq $repository.DnsSafeHost) {
            # Repository/release pages only; never /releases/download assets or redirects.
            $trusted = $uri.AbsolutePath -cmatch ('^' + [regex]::Escape($repoPath) + '(/releases(/latest|/tag/[A-Za-z0-9._-]+)?)?/?$')
        }
        if ($uri.AbsolutePath -match '(?i)\.(exe|msi|ps1|bat|cmd|zip|7z|rar|dll|com|scr)$') { $trusted = $false }
    }
    if (-not $trusted -or $uri.AbsolutePath.Contains('%')) { throw [FormatException]::new('Update URL is outside the official metadata/page allowlist.') }
    return $uri
}
function Invoke-UpdateMetadataGet {
    param([Uri]$Uri)
    # Validate again at the actual network boundary. No redirects (including an
    # HTTPS -> HTTP downgrade on .NET Framework), credentials, cookies or retries.
    $endpoint = ConvertTo-TrustedUpdateUri $Uri.AbsoluteUri 'Metadata'
    Add-Type -AssemblyName System.Net.Http
    $handler = [Net.Http.HttpClientHandler]::new()
    $client = $null; $response = $null
    try {
        $handler.AllowAutoRedirect = $false
        $handler.UseCookies = $false
        $handler.UseDefaultCredentials = $false
        $handler.Credentials = $null
        $handler.DefaultProxyCredentials = $null
        $client = [Net.Http.HttpClient]::new($handler)
        $client.Timeout = [TimeSpan]::FromSeconds(8)
        $client.MaxResponseContentBufferSize = 16384
        $client.DefaultRequestHeaders.Accept.ParseAdd('application/json')
        # ResponseContentRead applies the timeout and buffer limit to the body too.
        $response = $client.GetAsync($endpoint, [Net.Http.HttpCompletionOption]::ResponseContentRead).GetAwaiter().GetResult()
        if (-not $response.IsSuccessStatusCode) { throw [Net.Http.HttpRequestException]::new('Update metadata request failed.') }
        return $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    } finally {
        if ($null -ne $response) { $response.Dispose() }
        if ($null -ne $client) { $client.Dispose() } else { $handler.Dispose() }
    }
}
function ConvertFrom-UpdateMetadata {
    param($Json)
    if ($Json -isnot [string] -or [Text.Encoding]::UTF8.GetByteCount($Json) -gt 16384 -or -not $Json.TrimStart().StartsWith('{')) {
        throw [FormatException]::new('Invalid update JSON object or response size.')
    }
    try { $data = ConvertFrom-Json -InputObject $Json -ErrorAction Stop }
    catch { throw [FormatException]::new('Invalid update JSON.') }
    if ($data -isnot [pscustomobject]) { throw [FormatException]::new('Expected an update object.') }
    $fields = @($data.PSObject.Properties | ForEach-Object Name)
    if ('version' -notin $fields) { throw [FormatException]::new('Missing update version.') }
    $version = ConvertTo-AppVersion $data.version
    if ('product' -in $fields -and ($data.product -isnot [string] -or $data.product -cne $script:AppInfo.Name)) {
        throw [FormatException]::new('Update product mismatch.')
    }
    $result = [pscustomobject]@{ Version = $version; Notes = ''; DownloadUrl = ''; ReleaseNotesUrl = '' }
    if ('notes' -in $fields) {
        if ($data.notes -isnot [string] -or $data.notes.Length -gt 2000 -or $data.notes -match '[\x00-\x08\x0B\x0C\x0E-\x1F]') { throw [FormatException]::new('Invalid update notes.') }
        $result.Notes = $data.notes
    }
    foreach ($field in @('downloadUrl','releaseNotesUrl')) {
        if ($field -in $fields) { $result.$field = (ConvertTo-TrustedUpdateUri $data.$field 'Page').AbsoluteUri }
    }
    return $result
}
function Get-UpdateMetadata {
    param([string]$Endpoint = $script:AppInfo.UpdateMetadataUrl)
    $uri = ConvertTo-TrustedUpdateUri $Endpoint 'Metadata'
    return ConvertFrom-UpdateMetadata (Invoke-UpdateMetadataGet $uri)
}
function New-UpdateResult {
    param([string]$State, [string]$Message)
    return [pscustomobject]@{ State = $State; Message = $Message; LatestVersion = ''; Notes = ''; DownloadUrl = ''; ReleaseNotesUrl = '' }
}
function Write-UpdateLog {
    param([string]$Message, [ValidateSet('INFO','WARN')][string]$Level = 'INFO')
    try { Write-OperationLog $Message $Level }
    catch { Write-Warning 'Update status could not be written to the application log.' }
}
function Get-UpdateStatus {
    param([string]$Endpoint = $script:AppInfo.UpdateMetadataUrl, [string]$CurrentVersion = $script:AppInfo.Version)
    Write-UpdateLog 'Update check requested.'
    if ([string]::IsNullOrWhiteSpace($Endpoint)) {
        return New-UpdateResult 'NotConfigured' 'Update metadata endpoint is not configured. See README for publication setup.'
    }
    try {
        $current = ConvertTo-AppVersion $CurrentVersion
        $metadata = Get-UpdateMetadata $Endpoint
        $comparison = $metadata.Version.CompareTo($current)
        $latest = 'V' + $metadata.Version.ToString()
        Write-UpdateLog ('Latest published version: ' + $latest)
        if ($comparison -gt 0) {
            $result = New-UpdateResult 'UpdateAvailable' ("A new version is available.`r`nCurrent: V{0}`r`nLatest: {1}" -f $current, $latest)
            $result.DownloadUrl = $metadata.DownloadUrl
            $result.ReleaseNotesUrl = $metadata.ReleaseNotesUrl
            $result.Notes = $metadata.Notes
        } elseif ($comparison -eq 0) {
            $result = New-UpdateResult 'UpToDate' ("You're up to date.`r`n{0} V{1} is the latest version." -f $script:AppInfo.Name, $current)
        } else {
            $result = New-UpdateResult 'Ahead' 'Current version is newer than the published update metadata.'
        }
        $result.LatestVersion = $latest
        return $result
    } catch {
        $failure = $_.Exception.GetBaseException()
        if ($failure -is [FormatException]) {
            Write-UpdateLog 'Update information is invalid.' 'WARN'
            return New-UpdateResult 'Invalid' 'Update information is invalid.'
        }
        if ($failure -is [OperationCanceledException] -or $failure -is [TimeoutException]) { Write-UpdateLog 'Update check failed: request timed out.' 'WARN' }
        else { Write-UpdateLog 'Update check failed: connection or HTTP error.' 'WARN' }
        return New-UpdateResult 'Unavailable' 'Unable to check for updates. Please try again later.'
    }
}
function Open-TrustedUpdateUri {
    param($Value)
    try {
        $uri = ConvertTo-TrustedUpdateUri $Value 'Page'
        $startInfo = [Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = $uri.AbsoluteUri
        $startInfo.UseShellExecute = $true
        [void][Diagnostics.Process]::Start($startInfo)
        return 'Opened the official page in your default browser.'
    } catch { return 'Unable to open the official page. Check your default browser settings.' }
}
function New-UpdateAboutWindow {
    param($Owner)
    [xml]$aboutXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="540" Height="500" MinWidth="480" MinHeight="440" WindowStartupLocation="CenterOwner" ShowInTaskbar="False" FontFamily="Segoe UI" FontSize="13" Background="#F3F5F7">
  <Grid Margin="24">
    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
    <StackPanel><TextBlock x:Name="Identity" FontSize="21" FontWeight="SemiBold"/><TextBlock x:Name="Author" Margin="0,10,0,0"/><TextBlock x:Name="Support" Margin="0,6,0,16" Foreground="#526170"/></StackPanel>
    <Button x:Name="CheckButton" Grid.Row="1" Content="Check for Updates" HorizontalAlignment="Left" Padding="14,8"/>
    <TextBlock x:Name="Status" Grid.Row="2" Text="Checks run only when you request them." TextWrapping="Wrap" Margin="0,16,0,10"/>
    <TextBox x:Name="Notes" Grid.Row="3" IsReadOnly="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" BorderThickness="0" Background="Transparent"/>
    <WrapPanel Grid.Row="4" Margin="0,12,0,0"><Button x:Name="DownloadButton" Content="Open Download Page" IsEnabled="False" Padding="12,8" Margin="0,0,8,0"/><Button x:Name="NotesButton" Content="Release Notes" IsEnabled="False" Padding="12,8"/></WrapPanel>
  </Grid>
</Window>
'@
    $reader = [Xml.XmlNodeReader]::new($aboutXaml)
    try { $window = [Windows.Markup.XamlReader]::Load($reader) } finally { $reader.Close() }
    if ($null -ne $Owner -and $Owner.IsVisible) { $window.Owner = $Owner }
    $window.Title = 'About ' + $script:AppInfo.Name
    $window.FindName('Identity').Text = '{0} {1}' -f $script:AppInfo.Name, $script:AppInfo.Version
    $window.FindName('Author').Text = $script:AppInfo.Author
    $window.FindName('Support').Text = '{0}  |  {1}' -f $script:AppInfo.Website, $script:AppInfo.SupportEmail
    $view = @{ Window = $window; Result = $null }
    foreach ($name in @('CheckButton','Status','Notes','DownloadButton','NotesButton')) { $view[$name] = $window.FindName($name) }
    return $view
}
