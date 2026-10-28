# Registering this machine with GitHub Actions

## Scope: one registration per repository

A personal GitHub account has no organization-level runners, so a self-hosted
runner is bound to exactly one repository. Serving several repositories from one
machine means running the same script once per repository; each instance gets its
own root (`C:\actions-runner\<repo>`) and work folder, so they never collide.
Pool of instances on one machine: ~100 MB RSS and ~300 MB disk each while idle.

To share one runner across an organization instead, the repositories have to live
in a GitHub organization: organization runners can be granted to all repositories
at once. Moving repositories is not reversible and changes every URL, so only do
it deliberately.

## Register a repository

```powershell
# on a machine with gh and admin rights on the repository
gh api -X POST repos/<owner>/<repo>/actions/runners/registration-token --jq .token

# on the Windows machine, elevated PowerShell
.\scripts\runner-setup.ps1 -Token <token> -Repo <owner>/<repo>
```

The registration token expires after one hour and registers one runner.

Add repository-specific labels with `-Labels windows,x64,extra-label`; the script
always requires `windows` and `x64` because the jobs rely on them.

## Check and remove

```powershell
gh api repos/<owner>/<repo>/actions/runners --jq '.runners[] | {name,status,busy,labels:[.labels[].name]}'
& C:\actions-runner\<repo>\svc.cmd status
& C:\actions-runner\<repo>\svc.cmd uninstall
```

`svc.cmd uninstall` does not delete the runner on GitHub; remove it with
`gh api -X DELETE repos/<owner>/<repo>/actions/runners/<id>`.

## Requirements

- Windows 10/11 or Server 2019+, x64.
- A dedicated account or VM. Jobs may rewrite `HKCU\Environment`, switch the
  console codepage and install software.
- Network access to `github.com`, `api.github.com` and the release assets.
- Never `pull_request` on a self-hosted runner in a public repository: a fork's
  pull request would run arbitrary code on this machine. Trigger with
  `workflow_dispatch` and `workflow_run` only.
