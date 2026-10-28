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

## Binding model

Two different things, easy to confuse:

- **Labels** describe the machine: `self-hosted`, `windows`, `x64`, `regrevia-win`.
  They let a workflow ask for "a Windows x64 machine of this pool".
- **Registration** decides which repository may use the instance. A runner
  registered to `owner/a` never picks up a job from `owner/b`, no matter what the
  labels say.

So the same labels go on every instance of this machine, and the registration is
what binds an instance to a project. Workflows select the machine with
`runs-on: [self-hosted, windows, x64, regrevia-win]`.

## Directory layout

```
C:\win-runner\                 # machine-level tooling (this repository)
C:\actions-runner\<repo>\      # one instance per repository, never shared
```

Every repository gets its own directory and its own `_work`. Do not re-register a
second repository into an existing root: `config.cmd` keeps `.runner`,
`.credentials` and `_work` inside the root, so a shared root overwrites the
registration, deletes the other project's credentials, and mixes checkouts, tokens
and build output of unrelated projects in one tree. `register-repos.ps1` derives
`C:\actions-runner\<slug>` per repository for exactly this reason.

## Isolation: what is guaranteed, what is not

Guaranteed by one-instance-per-root:

- separate registration and credentials per project;
- separate `_work`: checkouts, temp files and artifacts do not leak between
  projects;
- separate Windows service (`actions.runner.<owner>-<repo>.<name>`), so stopping
  or upgrading one project's runner does not disturb another;
- one job at a time per instance, because a runner executes a single job.

**Not** guaranteed: this is not a sandbox. Instances run as the same Windows user,
so they share the file system, environment variables, `HKCU` (including `Path`),
installed software, and package caches (pip, npm, NuGet). Consequences:

- a job that rewrites `Path`, installs software or claims a fixed port can break a
  job of another project on the same machine; serialize such jobs with a
  `concurrency` group, or give that project its own machine;
- untrusted code must never run here. Public repositories: never trigger on
  `pull_request`, only `workflow_dispatch` and `workflow_run`;
- job logs and artifacts of a public repository are world-readable. Keep secrets
  out of them and treat the machine as public-facing;
- moving a repository to an organization is the only way to get true pooling, and
  that changes URLs irreversibly.

## Register a repository

```powershell
# on a machine with gh and admin rights on the repository
gh api -X POST repos/<owner>/<repo>/actions/runners/registration-token --jq .token

# on the Windows machine, elevated PowerShell
.\scripts\runner-setup.ps1 -Token <token> -Repo <owner>/<repo> -Labels windows,x64,regrevia-win
```

The registration token expires after one hour and registers one runner.

Several repositories at once, one instance each:

```powershell
.\scripts\register-repos.ps1 -Repos regrevia/a,regrevia/b
# or list them in scripts/repos.txt
```

The script mints a token per repository, derives `C:\actions-runner\<slug>`, and
stops on the first failure. Adding a project later is the same command with one
more entry.

## As a Windows service

`config.cmd --runasservice` creates the service; the runner package has no
`svc.cmd` (that is the Linux/macOS `svc.sh`). Elevation is required. The setup
script does this automatically when started from an elevated shell.

```powershell
Get-Service actions.runner.* | Select-Object Name, Status, StartType   # Running / Automatic
Stop-Service actions.runner.regrevia-Envoy.regrevia-envoy
sc.exe delete actions.runner.regrevia-Envoy.regrevia-envoy             # after Stop-Service
```

A service starts on boot with nobody logged in. Without elevation, pass
`-NoService`: `config.cmd` itself works, but the runner stays in the foreground
and dies with its console (closing the window is a Ctrl+C: exit code
`0xC000013A`). Scheduled tasks at logon are a stopgap only; they die the same way
when their console is closed and do not run when the machine is on battery.

## Check and remove

```powershell
gh api repos/<owner>/<repo>/actions/runners --jq '.runners[] | {name,status,busy,labels:[.labels[].name]}'
```

`online` means the instance is connected. To remove an instance: `config.cmd
remove` in its root (it asks for a remove token, `POST
repos/<owner>/<repo>/actions/runners/remove-token`), then `sc.exe delete` the
service. Deleting the GitHub runner entry alone leaves the directory registered.

## Requirements

- Windows 10/11 or Server 2019+, x64.
- A dedicated account or VM. Jobs may rewrite `HKCU\Environment`, switch the
  console codepage and install software.
- Network access to `github.com`, `api.github.com` and the release assets. This
  machine's egress to `codeload.github.com` times out intermittently, so workflows
  should not let an action download or artifact upload decide the job result; print
  assertion output into the log as well.
- Never `pull_request` on a self-hosted runner in a public repository.
