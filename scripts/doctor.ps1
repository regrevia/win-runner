#requires -Version 5.1
<#
Read-only health check for the runner instances on this machine.

Run it in an elevated or a normal PowerShell; it changes nothing. For every
repository listed in scripts/repos.txt it reports whether the instance directory
exists, whether its Windows service is running and set to start automatically,
the runner version and the size of the work folder.

Exit code 0 when every listed repository is healthy, 1 otherwise.
#>
[CmdletBinding()]
param(
    [string[]]$Repos,
    [string]$RunnerRootBase = "C:\actions-runner"
)

$ErrorActionPreference = "Stop"

if (-not $Repos -or $Repos.Count -eq 0) {
    $listPath = Join-Path $PSScriptRoot "repos.txt"
    if (-not (Test-Path -LiteralPath $listPath)) { throw "no -Repos given and no repos.txt at $listPath" }
    $Repos = @(Get-Content -LiteralPath $listPath |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -and -not $_.StartsWith("#") })
}

$rows = New-Object System.Collections.ArrayList
$failures = 0

foreach ($repo in $Repos) {
    $slug = ($repo -split "/")[1].ToLowerInvariant()
    $root = Join-Path $RunnerRootBase $slug
    $installed = Test-Path -LiteralPath $root
    $service = Get-Service -Name "actions.runner.*" -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like "*$slug*" -or $_.DisplayName -like "*$slug*" } |
        Select-Object -First 1
    $version = ""
    if ($installed) {
        $listener = Get-ChildItem -LiteralPath $root -Filter "Runner.Listener.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($listener) { $version = $listener.VersionInfo.FileVersion }
    }
    $work = Join-Path $root "_work"
    $workMB = 0
    if (Test-Path -LiteralPath $work) {
        $sum = (Get-ChildItem -LiteralPath $work -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
        if ($sum) { $workMB = [math]::Round($sum / 1MB, 0) }
    }
    $ok = $installed -and $service -and $service.Status -eq "Running"
    if (-not $ok) { $failures++ }
    [void]$rows.Add([pscustomobject]@{
        Repo      = $repo
        Installed = $installed
        Service   = $(if ($service) { $service.Name } else { "" })
        Status    = $(if ($service) { [string]$service.Status } else { "" })
        StartType = $(if ($service) { [string]$service.StartType } else { "" })
        Version   = $version
        WorkMB    = $workMB
        Ok        = $ok
    })
}

$rows | Format-Table -AutoSize | Out-String | Write-Host
Write-Host ("checked {0} repositories, {1} not healthy" -f $Repos.Count, $failures)
if ($failures -gt 0) { exit 1 }
