#requires -Version 5.1
<#
.SYNOPSIS
Register this machine as a self-hosted runner for one or more repositories.

.DESCRIPTION
A personal GitHub account has no organization-level runners, so sharing this
machine with several projects means one runner instance per repository. This
script does that in one command: for each repository it asks GitHub for a fresh
registration token (never written to disk) and delegates download, config and
service install to runner-setup.ps1.

Labels describe the machine, not the repository, so every instance gets the same
labels by default.

.PARAMETER Repos
Repositories to register, as owner/name. Defaults to scripts/repos.txt.

.EXAMPLE
.\register-repos.ps1 -Repos regrevia/Envoy, regrevia/dsh-lite-memory
#>
[CmdletBinding()]
param(
    [string[]]$Repos,
    [string[]]$Labels = @("windows", "x64", "regrevia-win"),
    [string]$RunnerRootBase = "C:\actions-runner",
    [switch]$NoService
)

$ErrorActionPreference = "Stop"
$setup = Join-Path $PSScriptRoot "runner-setup.ps1"
if (-not (Test-Path -LiteralPath $setup)) { throw "runner-setup.ps1 not found next to this script" }

if (-not $Repos -or $Repos.Count -eq 0) {
    $listPath = Join-Path $PSScriptRoot "repos.txt"
    if (-not (Test-Path -LiteralPath $listPath)) { throw "no -Repos given and no repos.txt at $listPath" }
    $Repos = @(Get-Content -LiteralPath $listPath |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -and -not $_.StartsWith("#") })
}
if (-not $Repos -or $Repos.Count -eq 0) { throw "repository list is empty" }

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    throw "gh CLI is required to mint registration tokens: https://cli.github.com"
}

$results = New-Object System.Collections.ArrayList

foreach ($repo in $Repos) {
    if ($repo -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') {
        Write-Warning "skipping '$repo': expected owner/name"
        continue
    }
    $slug = ($repo -split "/")[1].ToLowerInvariant()
    Write-Host ""
    Write-Host ("=== {0} (instance {1}) ===" -f $repo, $slug) -ForegroundColor Cyan

    $token = & gh api -X POST ("repos/{0}/actions/runners/registration-token" -f $repo) --jq .token
    if (-not $token) {
        [void]$results.Add([pscustomobject]@{ Repo = $repo; Result = "failed: no registration token (admin rights?)" })
        continue
    }

    try {
        $call = @{
            Token = $token
            Repo = $repo
            Labels = $Labels
            RunnerRoot = (Join-Path $RunnerRootBase $slug)
        }
        if ($NoService) { $call["NoService"] = $true }
        & $setup @call
        if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { throw "runner-setup.ps1 exited with $LASTEXITCODE" }
        [void]$results.Add([pscustomobject]@{ Repo = $repo; Result = "registered" })
    } catch {
        [void]$results.Add([pscustomobject]@{ Repo = $repo; Result = ("failed: {0}" -f $_.Exception.Message) })
    } finally {
        Remove-Variable -Name token -ErrorAction SilentlyContinue
    }
}

Write-Host ""
Write-Host "summary:" -ForegroundColor Cyan
$results | Format-Table -AutoSize
Write-Host "verify: gh api repos/<owner>/<repo>/actions/runners --jq '.runners[] | {name,status,busy}'"
if (@($results | Where-Object { $_.Result -ne "registered" }).Count -gt 0) { exit 1 }
