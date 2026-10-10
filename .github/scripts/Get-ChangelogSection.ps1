<#
.SYNOPSIS
  Extracts the block of one version from docs/CHANGELOG.txt, to be used as the release notes.

.DESCRIPTION
  The changelog lists versions newest first. A block starts with a line like
      0.3.4-experimental - short summary
  followed by indented lines, and ends before the next such line (or at the end of the file).
  The heading line is kept, as in the notes of the earlier releases. Blank lines at the end are dropped.
  Fails if the version has no block, or more than one.
  Line endings of the input (LF or CRLF) do not matter; the output has LF endings, UTF-8 without BOM.

.EXAMPLE
  .\Get-ChangelogSection.ps1 -Version 0.3.4-experimental -OutFile notes.md
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Version,
    [string]$Path,
    [string]$OutFile
)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'Common.ps1')
if (-not $Path) { $Path = Join-Path $here '..\..\docs\CHANGELOG.txt' }

if (-not (Test-Path -LiteralPath $Path)) { Fail 'Changelog not found' "No file at $Path" }

$utf8 = New-Object System.Text.UTF8Encoding($false)
$lines = [IO.File]::ReadAllLines($Path, $utf8)

$headingOfVersion = '^' + [regex]::Escape($Version) + '\s+-\s+\S'
$anyHeading = '^\d+\.\d+\.\d+\S*\s+-\s+\S'

$starts = @()
for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match $headingOfVersion) { $starts += $i }
}
if ($starts.Count -eq 0) {
    Fail 'No changelog entry' ("docs/CHANGELOG.txt has no block starting with '$Version - ...'.`n" +
        "Add one at the top of the file (same format as the others) before tagging.")
}
if ($starts.Count -gt 1) { Fail 'Duplicate changelog entry' "docs/CHANGELOG.txt has $($starts.Count) blocks for '$Version'." }

$first = $starts[0]
$end = $lines.Count
for ($j = $first + 1; $j -lt $lines.Count; $j++) {
    if ($lines[$j] -match $anyHeading) { $end = $j; break }
}
while ($end -gt $first + 1 -and [string]::IsNullOrWhiteSpace($lines[$end - 1])) { $end-- }

if ($end -le $first + 1) { Fail 'Empty changelog entry' "The block for '$Version' has a heading but no entries." }

$block = $lines[$first..($end - 1)]
$text = ($block -join "`n") + "`n"

if ($OutFile) {
    $full = if ([IO.Path]::IsPathRooted($OutFile)) { $OutFile } else { Join-Path (Get-Location).Path $OutFile }
    $dir = Split-Path -Parent $full
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    [IO.File]::WriteAllText($full, $text, $utf8)
    Write-Host "Wrote $($block.Count) lines of release notes for $Version to $OutFile"
} else {
    Write-Output $text
}
