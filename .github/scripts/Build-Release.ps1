<#
.SYNOPSIS
  Runs the project's own build.bat, checks the package it produced and writes its SHA-256.

.DESCRIPTION
  1. prints the Visual Studio / MSVC toolset in use (so a toolchain problem is visible at the top of the log);
  2. runs build.bat from the repository root and keeps its output;
  3. on failure, explains the known causes (see the __chkstk note below) and stops;
  4. checks release\MPFever-<VERSION>.zip: MPFever.exe, winhttp.dll, mod\mpfever_1\...;
  5. copies the zip to -OutDir together with MPFever-<VERSION>.zip.sha256 ("<hash>  <file>", sha256sum format).

  Known failure: with recent MSVC toolsets the native module fails to link with
  "LNK2019: unresolved external symbol __chkstk" (the module links with /NODEFAULTLIB and some
  functions have large locals, so the compiler emits a stack probe). That needs a fix in native\ .
  This script only reports it clearly; it does not work around it.
#>
[CmdletBinding()]
param(
    [string]$Version,
    [string]$OutDir
)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'Common.ps1')

$repo = (Resolve-Path (Join-Path $here '..\..')).Path
Set-Location $repo
if (-not $Version) {
    $global:LASTEXITCODE = 0
    $Version = (& (Join-Path $here 'Get-ReleaseVersion.ps1'))
    if ($LASTEXITCODE -ne 0) { exit 1 }
}
if (-not $OutDir) { $OutDir = Join-Path $repo 'release\upload' }

# ---- 1. toolchain ----
Write-Host '=== toolchain'
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (Test-Path $vswhere) {
    $vsdir = (& $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath) | Select-Object -First 1
    $vsname = (& $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property displayName) | Select-Object -First 1
    $vsver = (& $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property catalog_productDisplayVersion) | Select-Object -First 1
    Write-Host "Visual Studio : $vsname $vsver"
    Write-Host "Install path : $vsdir"
    $vcfile = if ($vsdir) { Join-Path $vsdir 'VC\Auxiliary\Build\Microsoft.VCToolsVersion.default.txt' }
    if ($vcfile -and (Test-Path $vcfile)) { Write-Host "MSVC toolset  : $((Get-Content $vcfile -TotalCount 1).Trim())  (the one native\build.bat uses)" }
} else {
    Write-Host 'vswhere.exe not found (build.bat will stop with its own message).'
}
Write-Host "Version       : $Version"

# ---- 2. build ----
Write-Host '=== build.bat'
$log = Join-Path ([IO.Path]::GetTempPath()) ('mpfever-build-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.log')
# 2>&1 is inside the cmd string so that Windows PowerShell 5.1 does not turn stderr lines into errors.
& cmd.exe /d /c '.\build.bat 2>&1' | Tee-Object -FilePath $log
$code = $LASTEXITCODE

# ---- 3. diagnose ----
if ($code -ne 0) {
    $text = if (Test-Path $log) { [IO.File]::ReadAllText($log) } else { '' }
    $hint = "build.bat exited with code $code. See the log above for the first error."
    if ($text -match '__chkstk') {
        $hint = "Native module: unresolved external symbol __chkstk (build.bat exit code $code).`n" +
                "Known problem with recent MSVC toolsets: the module is freestanding (/NODEFAULTLIB) and some functions have large locals, " +
                "so the compiler emits a stack-probe call that nothing provides. It is a source problem in native\, not a CI problem; " +
                "this workflow will pass once native\ builds with the toolset printed at the top of this log."
    } elseif ($text -match 'vswhere\.exe not found|Visual Studio C\+\+ tools not found|MSBuild not found') {
        $hint = "Visual Studio / MSBuild was not found on this runner (build.bat exit code $code)."
    } elseif ($text -match '=== 2/3 launcher' -and $text -notmatch '=== 3/3 package') {
        $hint = "The native module built; the launcher (MSBuild step 2/3) failed (build.bat exit code $code)."
    } elseif ($text -notmatch '=== 2/3 launcher') {
        $hint = "The native module (step 1/3, native\build.bat) failed (build.bat exit code $code)."
    }
    Fail 'build.bat failed' $hint
}

# ---- 4. check the package ----
Write-Host '=== check package'
$zip = Join-Path $repo "release\MPFever-$Version.zip"
if (-not (Test-Path -LiteralPath $zip)) {
    Fail 'Package missing' "build.bat succeeded but release\MPFever-$Version.zip does not exist. Is VERSION in build.bat '$Version'?"
}
Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [IO.Compression.ZipFile]::OpenRead($zip)
try {
    $entries = @{}
    $backslashed = 0
    foreach ($e in $archive.Entries) {
        # Windows PowerShell 5.1 (used by build.bat) can write "MPFever\x" names; compare with / either way.
        if ($e.FullName.Contains('\')) { $backslashed++ }
        $entries[$e.FullName.Replace('\', '/')] = $e.Length
    }
} finally { $archive.Dispose() }

$problems = @()
$required = @(
    'MPFever/MPFever.exe', 'MPFever/MPFever.exe.config', 'MPFever/winhttp.dll',
    'MPFever/README.txt', 'MPFever/INSTALL.txt', 'MPFever/CHANGELOG.txt',
    'MPFever/mod/mpfever_1/mod.json'
)
foreach ($r in $required) {
    if (-not $entries.ContainsKey($r)) { $problems += "missing: $r" }
}
foreach ($r in 'MPFever/MPFever.exe', 'MPFever/winhttp.dll') {
    if ($entries.ContainsKey($r) -and $entries[$r] -le 0) { $problems += "empty: $r" }
}
$modEntries = @($entries.Keys | Where-Object { $_ -like 'MPFever/mod/mpfever_1/*' }).Count
if ($modEntries -lt 2) { $problems += "mod/mpfever_1 has only $modEntries entries" }
if ($problems.Count -gt 0) { Fail 'Package check failed' (($problems | ForEach-Object { "  - $_" }) -join "`n") }
if ($backslashed -gt 0) {
    $w = "$backslashed of $($entries.Count) zip entry names use a backslash (the zip is written by Windows PowerShell 5.1 in build.bat, which ignores the forward-slash intent of its comment). Windows tools read it fine; some Linux/macOS unzip tools do not. Not changed here."
    Write-Host "WARNING: $w"
    if ($env:GITHUB_ACTIONS -eq 'true') { Write-Host "::warning title=Zip entry names::$w" }
}
Write-Host "OK: $($entries.Count) entries, $modEntries under MPFever/mod/mpfever_1/, MPFever.exe $($entries['MPFever/MPFever.exe']) bytes, winhttp.dll $($entries['MPFever/winhttp.dll']) bytes"

# ---- 5. checksum + staging ----
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$zipOut = Join-Path $OutDir "MPFever-$Version.zip"
Copy-Item -LiteralPath $zip -Destination $zipOut -Force
$hash = (Get-FileHash -LiteralPath $zipOut -Algorithm SHA256).Hash.ToLowerInvariant()
$shaFile = "$zipOut.sha256"
[IO.File]::WriteAllText($shaFile, "$hash  MPFever-$Version.zip`n", (New-Object System.Text.UTF8Encoding($false)))
Write-Host "SHA-256: $hash  MPFever-$Version.zip"
Write-Host "Staged in $OutDir"
Set-StepOutput 'sha256' $hash
exit 0
