#requires -Version 5.1
<#
Registers this Windows machine as a self-hosted GitHub Actions runner for one
repository and installs it as a Windows service.

One registration is scoped to one repository: a personal GitHub account has no
organization-level runners. To serve several repositories from the same machine,
run this script once per repository; every instance gets its own root directory
and work folder, so the instances cannot collide.

Run it on a dedicated Windows account or a dedicated VM, never on a desktop you
also use for work: the acceptance jobs assume they may modify PATH, the registry
and the user profile.

  # 1. on a machine with gh and admin rights on the target repository
  gh api -X POST repos/<owner>/<repo>/actions/runners/registration-token --jq .token

  # 2. on the Windows machine, in an elevated PowerShell
  .\scripts\runner-setup.ps1 -Token <token> -Repo <owner>/<repo>

The token expires after one hour, registers exactly one runner, and must never
be committed or pasted into a file.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Token,
    [Parameter(Mandatory = $true)][string]$Repo,
    [string]$RunnerRoot,
    [string]$Name,
    [string]$Work = "_work",
    [string[]]$Labels = @("windows", "x64"),
    [switch]$Ephemeral,
    [switch]$NoService
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0

if ($Repo -notmatch "^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$") { throw "-Repo must look like owner/name, got '$Repo'" }
if ($Labels -notcontains "windows") { throw "labels must include windows" }
if ($Labels -notcontains "x64") { throw "labels must include x64" }

# One instance per repository: derive a stable, filesystem-safe root and name
# from the repository slug unless the caller overrides them.
$slug = ($Repo -split "/")[1].ToLowerInvariant()
if (-not $Name) { $Name = "regrevia-$slug" }
if (-not $RunnerRoot) { $RunnerRoot = Join-Path "C:\actions-runner" $slug }

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
$isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin -and -not $NoService) {
    throw "not running as administrator: pass -NoService to register and run the runner interactively instead of installing it as a service"
}
if (-not $isAdmin) { Write-Host "-NoService: registering without a Windows service; the runner stays in the foreground" }

if (Get-Service -Name "actions.runner.*" -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like "*$slug*" -or $_.Name -like "*$slug*" }) {
    Write-Host "a runner service for '$slug' already exists; removing it first so this run is idempotent"
    Get-Service -Name "actions.runner.*" | Where-Object { $_.Name -like "*$slug*" } | ForEach-Object {
        & (Join-Path $RunnerRoot "svc.cmd") stop 2>$null | Out-Null
        & (Join-Path $RunnerRoot "svc.cmd") uninstall 2>$null | Out-Null
    }
}

$env:RUNNER_ALLOW_RUNASROOT = $null
if (-not (Test-Path -LiteralPath $RunnerRoot)) { New-Item -ItemType Directory -Path $RunnerRoot -Force | Out-Null }
Push-Location $RunnerRoot
try {
    if (-not (Test-Path -LiteralPath (Join-Path $RunnerRoot "config.cmd"))) {
        $release = Invoke-RestMethod -Uri "https://api.github.com/repos/actions/runner/releases/latest" -UseBasicParsing
        $asset = $release.assets | Where-Object { $_.name -like "actions-runner-win-x64-*.zip" } | Select-Object -First 1
        if (-not $asset) { throw "no actions-runner-win-x64 asset in the latest runner release" }
        $zip = Join-Path $env:TEMP $asset.name
        Write-Host ("downloading {0}" -f $asset.name)
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zip -UseBasicParsing
        Expand-Archive -LiteralPath $zip -DestinationPath $RunnerRoot -Force
        Remove-Item -LiteralPath $zip -Force
    }

    $configArgs = @(
        "--unattended",
        "--replace",
        "--url", ("https://github.com/{0}" -f $Repo),
        "--token", $Token,
        "--name", $Name,
        "--work", $Work,
        "--labels", ($Labels -join ",")
    )
    if ($Ephemeral) { $configArgs += "--ephemeral" }

    Write-Host ("registering {0} for {1} at {2}" -f $Name, $Repo, $RunnerRoot)
    & (Join-Path $RunnerRoot "config.cmd") @configArgs
    if ($LASTEXITCODE -ne 0) { throw "config.cmd failed with exit code $LASTEXITCODE" }

    if ($Ephemeral) {
        Write-Host "ephemeral runner configured; start it with run.cmd when a job is waiting"
    } elseif (-not $isAdmin) {
        Write-Host ("registered; start it now with: & '{0}\run.cmd' (keep this window open, stop with Ctrl+C)" -f $RunnerRoot)
    } else {
        & (Join-Path $RunnerRoot "svc.cmd") install
        if ($LASTEXITCODE -ne 0) { throw "svc.cmd install failed with exit code $LASTEXITCODE" }
        & (Join-Path $RunnerRoot "svc.cmd") start
        if ($LASTEXITCODE -ne 0) { throw "svc.cmd start failed with exit code $LASTEXITCODE" }
        Start-Sleep -Seconds 3
        & (Join-Path $RunnerRoot "svc.cmd") status
    }
}
finally {
    Pop-Location
}
Write-Host ("done: runner '{0}' for {1} (root {2}, work {3}, labels {4})" -f $Name, $Repo, $RunnerRoot, $Work, ($Labels -join ","))
