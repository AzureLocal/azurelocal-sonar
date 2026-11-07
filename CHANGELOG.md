# Changelog

All notable changes to AzL Sonar are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/) and this project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Unreleased

### Features

* **provisioning:** azurelocal-ztp's per-machine stages are steps of each machine. **Management address (maintenance environment)** (stage Device, before the claim) comes first and shows before the edge machine exists. **Management address on the management NIC** (Network, after the OS install) and **BIOS restored** (Restore: the final BIOS values after temporary install values) come last. Only a failed state is an error, so a Network job queued behind other jobs shows as running.
* **provisioning:** with the ZTP event file, a machine is done when Azure reports it Provisioned, its Network step succeeded, and its Restore step succeeded or is not applicable. Restore is not applicable when the stage ends (its `StageCompleted`, or Handoff) with no events for the machine. Until then the machine stays running at 95%.
* **provisioning:** `provisioning.ztpComplete` (all machines done) and `provisioning.nextStep` (`OS configuration` and its guide, https://azurelocal.cloud). Each machine has a `ztp` entry with its Device, Network and Restore step status.
* **web:** when ZTP is complete, the phase chip reads **ZTP complete**, the status reads "ZTP complete: N of N machines provisioned. OS configuration next", and a note under the header links the OS configuration guide.

### Changed

* **provisioning:** the simplified route no longer says **Ready for Validate**. After ZTP comes OS configuration (OEM drivers, `C:\SBE`, DHCP off, DNS and time, the deployment admin; azurelocal-toolkit Phase 03), then Validate. `provisioning.readyForValidate` stays in the state; it is always false on the simplified route. The OEM image route is unchanged.
* **provisioning:** the **Prepare for Validate** step and the per-machine `prepare` field are removed: azurelocal-ztp no longer has a Prepare stage. Prepare events in older event files still show in the log pane.

## [0.5.0](https://github.com/AzureLocal/azurelocal-sonar/compare/v0.4.0...v0.5.0) (2026-11-07)


### Features

* **provisioning:** ZTP Device, Network and Restore steps; ZTP complete hands over to OS configuration ([f776a23](https://github.com/AzureLocal/azurelocal-sonar/commit/f776a2362a8e63b35fb974e88d8143e7f2310ba5))


### Bug Fixes

* **dashboard:** use the Azure Local family icon for the favicon and page logo ([d7dfef5](https://github.com/AzureLocal/azurelocal-sonar/commit/d7dfef5086ed366ce1b7d44b6b95bc4b0e2bec09))
* **dashboard:** use the Azure Local family icon for the favicon and page logo ([aac5d52](https://github.com/AzureLocal/azurelocal-sonar/commit/aac5d52c02ce0680d804de215bd73b6a4bde7149))

## [0.4.0](https://github.com/AzureLocal/azurelocal-sonar/compare/v0.3.0...v0.4.0) (2026-11-06)


### Features

* **provisioning:** show azurelocal-ztp's Prepare stage after the OS is provisioned ([4601f85](https://github.com/AzureLocal/azurelocal-sonar/commit/4601f85a82a956236fdd26df86ce2adb01d82690))
* **provisioning:** show azurelocal-ztp's Prepare stage after the OS is provisioned ([15b5056](https://github.com/AzureLocal/azurelocal-sonar/commit/15b5056f3e1878a8588c68705583b822bfd20d1c))


### Bug Fixes

* **provisioning:** don't report an earlier attempt's ProvisionOs error as a failure ([b3f0cbf](https://github.com/AzureLocal/azurelocal-sonar/commit/b3f0cbf998f8a076a99e3e3a6645a27570491369))
* **provisioning:** don't report an earlier attempt's ProvisionOs error as a failure ([f2bfbfb](https://github.com/AzureLocal/azurelocal-sonar/commit/f2bfbfb7793ad605b4844eeb07545e5eca4af296))
* **web:** an open page reloads itself when Sonar comes back with new page code ([f61d062](https://github.com/AzureLocal/azurelocal-sonar/commit/f61d062102f8933832bb1e6dc4a6a5778627d086))
* **web:** an open page reloads itself when Sonar comes back with new page code ([21ad818](https://github.com/AzureLocal/azurelocal-sonar/commit/21ad8180b70bf984a231423f8e70847efcbd7ba5))
* **web:** header says Ready for Validate when every machine is done ([f9b7dab](https://github.com/AzureLocal/azurelocal-sonar/commit/f9b7dabb48ec59dc86752922bc40cc11adc2ed5c))
* **web:** header says Ready for Validate when every machine is done ([b9baad1](https://github.com/AzureLocal/azurelocal-sonar/commit/b9baad161e63afe811688db32a452bf26106a818))

## [0.3.0](https://github.com/AzureLocal/azurelocal-sonar/compare/v0.2.0...v0.3.0) (2026-10-16)


### Features

* GA api-versions and 12.2609 guidance, Azure lag and Environment Checker stage, update track, deployment shape, collapsed log access ([223bf68](https://github.com/AzureLocal/azurelocal-sonar/commit/223bf6845683b2ecbc7e2b8549787c0f85cb14e6))
* OEM-route Arc registration phase shows what registration does - OS image update (Get-ArcZeroDaySolutionUpdateStatus: Scan, Download, Install), bootstrap steps (Get-ArcBootstrapStatus incl. ArcConfiguration &gt; ArcRegistration), Arc machine registered and Connected; extensions move to Validate; read-only node probe over WinRM/SSH ([74871d4](https://github.com/AzureLocal/azurelocal-sonar/commit/74871d4e5434d46bad51baff8157475651692153))
* provisioning route setting and provisioning / Arc registration phases for both routes (simplified and OEM image) - work in progress, committed on owner order ([00c8f78](https://github.com/AzureLocal/azurelocal-sonar/commit/00c8f7801f77f0b28183c236930a768b7a5c4fd7))
* **recording:** publishable recordings (identifier pseudonyms, verified) and the export bundle ([948991d](https://github.com/AzureLocal/azurelocal-sonar/commit/948991d4df7b6bcf5c2a4e1e680e9e640c29f47d))
* Sonar back end - ARM poller, seed-node log tailer, HttpListener/SSE server, Start-AzlSonar.ps1, example config (S-5) ([e88fea9](https://github.com/AzureLocal/azurelocal-sonar/commit/e88fea95f41f9df57c89978fa6d61d5f8fc16e80))
* **web:** clearer confidence badge on the log-access card - 'Confirmed on Azure Local 2609 (Local Identity)' vs 'From Microsoft docs - not yet confirmed', with what was observed and what to do if it differs; README explains it ([f217022](https://github.com/AzureLocal/azurelocal-sonar/commit/f2170225d8f5fb4788ebe0748512257cf1912596))
* **web:** Sonar page - live step tree, log stream, guidance card, export, demo mode (S-5) ([c6772a8](https://github.com/AzureLocal/azurelocal-sonar/commit/c6772a8c0d6359d34f321aedc2efed8f69b2d908))
* **ztp:** follow the azurelocal-ztp provisioning event file (ztpEvents.path) in the log pane ([f15754b](https://github.com/AzureLocal/azurelocal-sonar/commit/f15754b608e728b5da2db7461dca575026fc13cc))


### Bug Fixes

* GPT review should-fixes - log event times with node UTC offset, page log sequencing and restart detection, SSE flow control and client cap, bounded discovery and state, file filter rebuild, step window re-render, zero-count summaries, rename rotation; docs: README, getting started, how it works ([930433f](https://github.com/AzureLocal/azurelocal-sonar/commit/930433f132c2555182e377485192909f7f22d3d0))
* loopback-only requests and secret redaction (GPT review blockers); SSH log transport fallback via Posh-SSH stdin; deployment log paths verified live ([d1b889f](https://github.com/AzureLocal/azurelocal-sonar/commit/d1b889f8e3b7514b23090e1aee648b985aa8e027))

## [Unreleased]

### Fixed

- Resolve the web-logic runner's app path from the working directory so the relative path used by Linux CI loads the same module as Pester's absolute path.

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
