# Shared test-only ownership boundary. Never used to relax production safeguards.
function New-TestSandbox {
    param([string]$ProjectRoot)
    $project = ConvertTo-LocalPath $ProjectRoot
    $parent = Join-Path $project '.test-sandbox'
    Assert-PlainAncestors $parent
    $id = [Guid]::NewGuid().ToString('N')
    $root = Join-Path $parent $id
    if ($null -ne (Get-PathEntry $root)) { throw 'Test sandbox collision.' }
    [void][IO.Directory]::CreateDirectory($root)
    $owner = [pscustomobject]@{ SessionId = $id; Project = $project; Root = $root; CreatedUtc = [DateTime]::UtcNow.ToString('o'); Identity = (Get-DirectoryIdentity $root) }
    Write-NewManagedJson (Join-Path $root '.junction-test-sandbox') $owner
    return $owner
}
function Assert-TestSandboxOwnership {
    param($Sandbox)
    $root = ConvertTo-LocalPath $Sandbox.Root
    $expected = Join-Path (Join-Path $Sandbox.Project '.test-sandbox') $Sandbox.SessionId
    if ($Sandbox.SessionId -notmatch '^[a-f0-9]{32}$' -or $root -ne $expected -or -not (Test-PathWithin $root $Sandbox.Project) -or $root.Length -le 3) { throw 'Test sandbox scope mismatch.' }
    Assert-PlainAncestors $root
    $marker = Read-ManagedJson (Join-Path $root '.junction-test-sandbox')
    if ($marker.SessionId -ne $Sandbox.SessionId -or $marker.Project -ne $Sandbox.Project -or $marker.Root -ne $root -or
        $marker.Identity -ne $Sandbox.Identity -or (Get-DirectoryIdentity $root) -ne $Sandbox.Identity) { throw 'Missing, malformed or mismatched test sandbox ownership.' }
}
function Assert-TestMutationPath {
    param($Sandbox, [string]$Path)
    $canonical = ConvertTo-LocalPath $Path
    if ($canonical -eq $Sandbox.Root -or -not (Test-PathWithin $canonical $Sandbox.Root)) { throw "Test mutation outside its owned sandbox: $canonical" }
    Assert-PlainAncestors ([IO.Path]::GetDirectoryName($canonical))
}
function Remove-EmptyTestSandboxParent {
    [CmdletBinding()]
    param([string]$ProjectRoot, [string]$ParentPath)
    try {
        $project = ConvertTo-LocalPath $ProjectRoot
        $parent = ConvertTo-LocalPath $ParentPath
        $expected = ConvertTo-LocalPath (Join-Path $project '.test-sandbox')
        if ($parent -ne $expected -or $parent -eq [IO.Path]::GetPathRoot($parent) -or -not (Test-PathWithin $parent $project)) {
            throw 'Test sandbox parent scope mismatch.'
        }
        Assert-PlainAncestors $parent
        if ($null -eq (Get-PathEntry $parent)) { return }
        # Include hidden/system entries. A sibling session or unknown file belongs
        # to someone else; never delete it or recurse into it to tidy the parent.
        if (@(Get-ChildItem -LiteralPath $parent -Force -ErrorAction Stop).Count) { return }
        Assert-PlainAncestors $parent
        [IO.Directory]::Delete($parent, $false)
        if ($null -ne (Get-PathEntry $parent)) { throw 'Empty sandbox parent still exists.' }
    } catch {
        Write-Warning "Sandbox parent cleanup incomplete: $ParentPath. $($_.Exception.Message)"
    }
}
function Remove-TestSandboxSafely {
    param($Sandbox)
    Assert-TestSandboxOwnership $Sandbox
    $pending = [Collections.Generic.Stack[string]]::new(); $pending.Push($Sandbox.Root)
    $links = [Collections.Generic.List[object]]::new()
    # Inventory first. Unsupported links abort cleanup before any deletion.
    while ($pending.Count) {
        $path = $pending.Pop()
        Assert-PlainAncestors $path
        foreach ($entry in @(Get-ChildItem -LiteralPath $path -Force -ErrorAction Stop)) {
            if (-not (Test-PathWithin $entry.FullName $Sandbox.Root)) { throw 'Sandbox cleanup escaped its root.' }
            if (Test-ReparseEntry $entry) {
                if (-not $entry.PSIsContainer -or $entry.LinkType -ne 'Junction') { throw "Cleanup refused unsupported reparse point: $($entry.FullName)" }
                $destination = Get-JunctionDestination $entry.FullName
                if (-not (Test-PathWithin $destination $Sandbox.Root)) { throw "Cleanup refused junction with an external destination: $($entry.FullName)" }
                $links.Add([pscustomobject]@{ Source = $entry.FullName; Target = $destination })
            } elseif ($entry.PSIsContainer) { $pending.Push($entry.FullName) }
        }
    }
    foreach ($link in $links) {
        Assert-TestSandboxOwnership $Sandbox
        Remove-JunctionOnly $link.Source $link.Target
    }
    $plan = Get-PlainTreeDeletionPlan $Sandbox.Root
    Remove-PlainTreeFromPlan $plan { Assert-TestSandboxOwnership $Sandbox }
    if ($null -ne (Get-PathEntry $Sandbox.Root)) { throw "Cleanup incomplete: $($Sandbox.Root)" }
    Remove-EmptyTestSandboxParent $Sandbox.Project ([IO.Path]::GetDirectoryName($Sandbox.Root))
}
