# Changelog

All notable changes to AzL Sonar are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/) and this project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.0] - 2026-10-15

Hardening release (owner order of 15 Oct 2026: the tools 100% built out). Everything below that reads Azure or the node is
covered by Pester with mocked answers; what could not be run live is marked "unverified against a live run" in the page and
the docs.

### Added

- **Publishable recordings.** `-Record -Publishable`, `Export-AzlSonarPublishableRecording`, `Test-AzlSonarPublishableRecording` and
  `scripts/Protect-Recording.ps1` replace GUIDs, IPv4, IPv6 and MAC addresses, SIDs, host and domain names, UPNs, subscription,
  resource group, cluster, node and user names with stable pseudonyms (`00000000-0000-0000-0000-000000000001`, `192.0.2.x`,
  `node-01`, `host-01.dom-01.example.test` ...), keep structure, timestamps, step names and durations, and refuse to write when a
  verification pass still finds an original (a live `-Publishable` recording is renamed `.NOT-PUBLISHABLE`). Options:
  `-ExtraTerm`, `-MaxLogTextLength`, `-MaxInfoLinesPerEvent`, `-MaxIdleSeconds`, `-MaxBytes`, `-VerifyOnly`. The detectors are
  compiled C# (a 137 MB recording in about five minutes). See `docs/reference/publishable-recordings.md`.
- **Update track** (unverified against a live run): `updateSummaries`, `updates` and `updateRuns` read into a step tree, with the
  update as the phase, a replay marker and a guidance card; `track` and `updateTrack` in the config; add node and repair as guidance
  cards and a config `track`.
- **Azure lag and Environment Checker stage:** the state carries `lag` (Azure behind the node log, or a newer running ARM deployment)
  and `environmentChecker` (limited, full, cloud deployment); the node-log role and interface is shown as the current step marked
  *from node log*; the page shows notes under the header.
- **Export bundle:** `Export-AzlSonarBundle` and `scripts/Export-SonarBundle.ps1` write a timeline JSON and a self-contained HTML
  report from any recording.
- **Log access panel** collapsed by default to one status line with an expander (S-12).
- **Event feed contract:** `docs/reference/events.schema.json` and `docs/reference/events.md` (what other tools can emit and Sonar
  replays; how a deployment pipeline runs Sonar with `-Record`).
- **Deployment shape in the config:** `clusterPattern` (Standard or RackAware), `architecture` (hyperconverged or disaggregated) and
  `internalDns`, with Learn's notes on the guidance card and a warning for the rack aware and Local Identity combination (Learn
  contradicts itself there).
- CI (`.github/workflows/ci.yml`: Pester per test file, the page logic under Node, PSScriptAnalyzer, relative links, the docs build),
  release-please, `PSScriptAnalyzerSettings.psd1`, `AGENTS.md`, `CLAUDE.md`, `CONTRIBUTING.md`, a pull request template and this file.
- `examples/recording.publishable.example.jsonl`: a small recording made with `-Publishable`.

### Changed

- Default api-versions are the GA versions on Microsoft Learn: deploymentSettings and the update resources `2026-10-01`, edge machines
  `2026-10-01`, Arc machines `2026-07-15`; the preview versions stay configurable and `apiVersionFallback` (default `2025-10-01`) is
  tried once when the configured version is not accepted.
- Guidance for release 12.2609 (latest): Validate about 10 minutes; Deploy 2.5 to 3 hours with a limited then a full Environment
  Checker run, Begin cloud deployment 45-60 minutes, Deploy Moc and ARB Stack 40-45 minutes (a new "How long" row).
- Reading a recording keeps no parsed JSON for log and tailer events (memory).
- `Protect-AzlSonarText` compiles its patterns once.
- The docs build checks dead links (`ignoreDeadLinks` is off); the module version is 0.2.0.
- README and docs say that recordings keep identifiers unless made with `-Publishable`; names of test environments and events are removed from the public docs.

### Fixed

- A `<time>` placeholder outside a code span broke the VitePress build of `docs/design.md`.

## [0.1.0] - 2026-10-11

First version: live step tree from Azure, live log tailing from the seed node, phase guidance, provisioning and Arc registration
views for both routes, record and replay, export, and a local web page.
