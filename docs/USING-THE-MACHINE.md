# Using this machine from any project

One Windows machine serves several repositories. The labels describe the
machine; the registration binds an instance to exactly one repository. So
"the other project can use the machine" means one instance per repository, not
one shared registration.

## Contract

- Labels are always `self-hosted, windows, x64, regrevia-win`. They are the
  same on every instance; never encode a project name in a label.
- Instance root is `C:\actions-runner\<repo-slug>`, service name is
  `actions.runner.<owner>-<repo>.regrevia-<slug>`, work folder is `_work`.
  Never point two repositories at one root: `.runner`, `.credentials` and
  `_work` would overwrite each other and the second `config.cmd` fails.
- Add the repository to `scripts/repos.txt`, then on the machine in an elevated
  PowerShell: `.\scripts\register-repos.ps1`. One command, one instance per
  repository, same labels. Re-running it is idempotent.
- Registration tokens live one hour and register one instance. They are minted
  by the script, never stored. Nothing needs to be re-registered later: an
  instance stays bound until it is removed with `config.cmd remove`.

## What a project puts in its workflow

```yaml
windows:
  if: github.event_name != 'pull_request'
  runs-on: [self-hosted, windows, x64, regrevia-win]
```

A public repository must never run `pull_request` on this machine: fork PRs
execute arbitrary code on the host. Keep `pull_request` on GitHub-hosted
runners and expose the self-hosted legs to `push` / `workflow_dispatch` only.
Serialize jobs that touch the shared surface (PATH, registry, installed
software, fixed ports) with a `concurrency` group, and restore what you change.

## What is and is not independent

Independent per instance: root folder, work folder, credentials, runner
process, Windows service. One repository's job can never be picked up by
another repository's instance.

Shared on the machine: the Windows user, PATH and other environment variables,
installed software, package caches, disk. This is not a sandbox. One job at a
time per instance, and instances can run at the same time, so a job that
changes global state must serialize with `concurrency` and undo its changes.

## Keeping it always available

- The runner is a Windows service with start type Automatic, so it comes back
  after a reboot with no sign-in. Check with
  `Get-Service actions.runner.* | Select Name,Status,StartType`.
- The machine must stay powered and online; on a laptop, disable sleep on AC
  (`powercfg /change standby-timeout-ac 0`). Offline instances keep no queue:
  jobs wait in GitHub for up to a day, then fail.
- Health at any time: `.\scripts\doctor.ps1` (read-only), or dispatch the
  `ops-health` workflow in this repository, which runs the same check on the
  machine itself.
- Disk: each instance keeps its own checkout; `doctor.ps1` reports the work
  folder size per repository.

## Adding a project later

1. Add `owner/repo` to `scripts/repos.txt` (commit it, so the list stays the
   source of truth).
2. On the machine, elevated PowerShell in `C:\win-runner`:
   `git pull; .\scripts\register-repos.ps1`
3. In that repository, point the Windows job at the label set for `push` and
   `workflow_dispatch`; keep `pull_request` on GitHub-hosted runners.
4. Verify once with a real run: the runner name and labels in the job log must
   be `regrevia-<slug>` and the label set above.

`gh` must be authenticated on the machine for step 2 (the script mints the
registration token). Without `gh`, mint the token on any machine with
`gh api -X POST repos/<owner>/<repo>/actions/runners/registration-token --jq .token`
and pass it to `runner-setup.ps1 -Token <token> -Repo <owner>/<repo>`.
