# win-runner

Self-hosted Windows runner registration for `regrevia` repositories; labels describe the machine, the registration decides the repository.

Repository-scoped by design: a personal GitHub account has no organization-level
runners, so one machine serves several repositories as several independent runner
instances (separate root and work folder each).

- [`scripts/runner-setup.ps1`](scripts/runner-setup.ps1) — download the runner,
  `config.cmd` it for one repository, install it as a service. Idempotent: a
  previous instance for the same repository is removed first.
- [`docs/REGISTRATION.md`](docs/REGISTRATION.md) — scope, registration, removal,
  requirements and the `pull_request` rule.

This repository holds infrastructure only. What each project checks on the node
stays in that project.
