# azurelocal-sonar - Agent instructions

<!--
  AGENTS.md is the canonical, cross-tool instruction file for this repo. Codex CLI, Cursor and VS Code Copilot read it
  natively; Claude Code imports it through CLAUDE.md. Keep it thin: the authoritative source for org standards is the
  HCS Governance MCP; this file is the bootstrap and the offline fallback.
-->

## What this repo is

AzL Sonar is a real-time, read-only monitor for Azure Local deployments: a PowerShell 7 module (`src/AzlSonar`), a
local back end on `http://localhost:<port>/` and a vanilla web page. It follows the deployment step tree from Azure,
streams the live deployment logs from the seed node, and can record a run and replay it later without Azure or node
access. Read [README.md](README.md), [repo-intent.md](repo-intent.md), [docs/plan.md](docs/plan.md) and
[docs/research.md](docs/research.md) before changing behaviour.

## Start here - connect to the HCS Governance MCP

At session start call `bootstrap(repo="azurelocal-sonar", client="<claude-code | codex | gemini | cursor | vscode>")`.
Prefer a live MCP answer over anything written here.

## Offline fallback (when the MCP server is unreachable)

**Standards scope:** `azurelocal`.

**Hard rules digest:**

- No secrets, tokens, passwords, subscription/tenant/client IDs, connection strings, real host names, real IP or MAC
  addresses in any committed file. Examples use documentation values only (192.0.2.x, 198.51.100.x, 203.0.113.x,
  `00000000-0000-0000-0000-000000000001`, `example.test`, the fictional company IIC).
- PowerShell 7.4+ only: `Set-StrictMode -Version Latest`, `$ErrorActionPreference = 'Stop'`. Never Windows PowerShell 5.1, never Bash.
- Markdown for documentation. The docs site is VitePress with dead-link checking on (`ignoreDeadLinks` stays off).
- Commit format: `type(scope): short description` (`feat`, `fix`, `docs`, `chore`, `refactor`, `test`, `ci`).
- Release wording: the Azure Local release is called **12.2609 (latest)** in everything public.
- No customer, event or test-environment names in anything public (docs, tests, fixtures, examples, screenshots).

## Repo rules (specific to Sonar)

1. **Read-only.** Sonar observes; it never changes a deployment, a node or Azure. New code may only GET and read.
2. **Loopback only.** The server binds `localhost`; keep that model. No remote listeners, no CORS widening, no auth bypass.
3. **Masking.** Everything that is stored, served or recorded passes `Protect-AzlSonarText`. Recordings keep identifiers
   (GUIDs, IPs, host names) unless made with `-Publishable`; never commit a real recording. `recordings/` is gitignored.
4. **Evidence.** Mark a plan item *Verified* only when it was verified (a live run or a replay of a real recording);
   otherwise *Done (unverified)*. Behaviour built from Microsoft Learn or REST reference only is labelled
   "unverified against a live run" in the UI and the docs.
5. **Tests.** `Invoke-Pester -Path ./tests` passes (about 6 minutes), no Azure sign-in, no network except a localhost port.
   Add a Pester case for every behaviour change; web logic goes in `tests/web-logic.cases.js`.
6. **Analyzer.** `Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1` returns nothing.
7. **Events contract.** The recording format (`docs/reference/events.schema.json`) is a public contract other tools
   emit into. Additive changes only; a breaking change bumps `format`.

## Where things are

| Path | What |
|---|---|
| `Start-AzlSonar.ps1` | Entry point (live, `-Record`, `-Publishable`, `-Replay`). |
| `src/AzlSonar/Private/` | Poller, step tree, tailer, recorder, publishable pseudonymiser, server. |
| `src/AzlSonar/web/` | The page (vanilla JS, no build step). |
| `src/AzlSonar/data/phase-guidance.json` | Per-phase log-access guidance (account, paths, timing, confidence). |
| `scripts/` | `Protect-Recording.ps1`, `Test-MarkdownLinks.ps1`. |
| `tests/` | Pester 5 suite, fixtures, Node web-logic cases. |
| `docs/` | VitePress site (plan, research, design, reference). |
