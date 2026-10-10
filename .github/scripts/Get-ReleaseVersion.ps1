<#
.SYNOPSIS
  Prints the release version defined in build.bat (the line  set "VERSION=...").
  With -Tag, also checks that a pushed tag names that version.

.DESCRIPTION
  A tag is accepted when it is the version itself (0.3.4-experimental) or the version
  without its "-experimental" suffix (0.3.4), which is how the existing releases are tagged.
  Prints the version on stdout. In GitHub Actions it also sets the step outputs
  "version" and, with -Tag, "prerelease" ("true" when the tag carries a suffix such as -experimental).
#>
[CmdletBinding()]
param(
    [string]$BuildBat,
    [string]$Tag
)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'Common.ps1')
if (-not $BuildBat) { $BuildBat = Join-Path $here '..\..\build.bat' }

if (-not (Test-Path -LiteralPath $BuildBat)) { Fail 'build.bat not found' "No file at $BuildBat" }

$found = @()
foreach ($line in [IO.File]::ReadAllLines($BuildBat)) {
    $m = [regex]::Match($line, '^\s*set\s+"VERSION=([^"]+)"\s*$')
    if ($m.Success) { $found += $m.Groups[1].Value }
}
if ($found.Count -ne 1) {
    Fail 'VERSION not found' "Expected exactly one line  set `"VERSION=...`"  in $BuildBat, found $($found.Count)."
}
$version = $found[0]
if ($version -notmatch '^\d+\.\d+\.\d+(-[A-Za-z0-9.]+)?$') {
    Fail 'Unexpected VERSION' "VERSION '$version' in build.bat does not look like 0.3.4 or 0.3.4-experimental."
}

if ($Tag) {
    $plain = $version -replace '-experimental$', ''
    if ($Tag -ne $version -and $Tag -ne $plain) {
        $accepted = if ($plain -eq $version) { "'$version'" } else { "'$version' or '$plain'" }
        Fail 'Tag does not match VERSION' ("Pushed tag '$Tag' but build.bat says VERSION=$version. Accepted tag: $accepted.`n" +
            "Bump VERSION in build.bat and add the block to docs/CHANGELOG.txt in a commit, then tag that commit.`n" +
            "To redo a wrong tag: delete it (git push --delete origin $Tag) and push the right one.")
    }
    # Previous releases: plain tag (0.2.10) = regular release, tag with a suffix (0.1.1-experimental style) = pre-release.
    Set-StepOutput 'prerelease' $(if ($Tag -match '-') { 'true' } else { 'false' })
}

Set-StepOutput 'version' $version
Write-Output $version
