# Shared helpers for the scripts in this folder (dot-source it). Works in Windows PowerShell 5.1 and PowerShell 7.

function Fail([string]$Title, [string]$Message) {
    # Plain message for the log, plus an annotation when running in GitHub Actions.
    Write-Host "ERROR: $Title - $Message"
    if ($env:GITHUB_ACTIONS -eq 'true') {
        $flat = ($Message -replace '%', '%25') -replace "\r?\n", '%0A'
        Write-Host "::error title=$Title::$flat"
    }
    exit 1
}

function Set-StepOutput([string]$Name, [string]$Value) {
    # No-op outside GitHub Actions (local runs). Appends as UTF-8 without BOM, LF.
    if ($env:GITHUB_OUTPUT) {
        [IO.File]::AppendAllText($env:GITHUB_OUTPUT, "$Name=$Value`n", (New-Object System.Text.UTF8Encoding($false)))
    }
}
