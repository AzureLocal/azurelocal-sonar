# Contributing

Thank you for helping with AzL Sonar. Contributions are welcome, especially fixtures from real deployments (after
`-Publishable`), step-name and timing corrections against current Microsoft Learn, and more test cases.

## Before you start

- Read the [README](README.md), [repo-intent.md](repo-intent.md) and the [plan](docs/plan.md).
- Sonar is **read-only** and binds **localhost only**. A change that writes to Azure or a node, or opens the listener
  to other machines, will not be accepted.
- Never commit a recording that was not made with `-Publishable`, and never commit identifiers, secrets, or customer and event names.
  Use documentation values: 192.0.2.x, 198.51.100.x, 203.0.113.x, `example.test`, the fictional company IIC.

## How to contribute

1. Fork the repo and branch from `main`: `feat/<topic>`, `fix/<topic>`, `docs/<topic>`.
2. Keep one logical change per pull request.
3. Add or update Pester cases (`tests/`) and, for page logic, `tests/web-logic.cases.js`.
4. Update the docs the change touches (README, `docs/`), and add a line under `[Unreleased]` in [CHANGELOG.md](CHANGELOG.md).
5. Fill out the pull request template.

## Checks (CI runs the same)

```powershell
Invoke-Pester -Path ./tests -CI                                                    # about 6 minutes
Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1   # must return nothing
./scripts/Test-MarkdownLinks.ps1                                                   # relative links and headings resolve
cd docs; npm install; npm run docs:build                                           # dead links fail the build
```

## Commit messages

[Conventional Commits](https://www.conventionalcommits.org/): `<type>(<scope>): <description>`.

| Type | When |
|---|---|
| `feat` | New behaviour |
| `fix` | Bug fix |
| `docs` | Documentation only |
| `test` | Tests only |
| `ci` | Workflows and checks |
| `chore` / `refactor` | Maintenance, no behaviour change |

Releases are cut by the owner from the release-please pull request; contributors do not tag.

## Style

- PowerShell 7.4+, `[CmdletBinding()]` and a comment-based help block on every public function, approved verbs.
- `Set-StrictMode -Version Latest` and `$ErrorActionPreference = 'Stop'`.
- Everything stored or served goes through `Protect-AzlSonarText`.
- Say what is unverified. Learn is the source for documented behaviour; what only a live run showed is marked as such.

## Code of conduct

Be respectful and constructive.
