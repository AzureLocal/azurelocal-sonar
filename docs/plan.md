# AzL Sonar — plan

Owner request (10 Oct 2026): a dedicated tool that monitors an Azure Local cluster deployment in more real time than the portal. It must collect and show the entire process: every step and its status, the live deployment log files as they are written, which account to use, and when to collect the live logs. Modern interface; PowerShell or a PowerShell back end; easy to use, not an installed product.

Status vocabulary: Backlog · In progress · Blocked (say on what) · Done (unverified) · Verified. Update this file task by task.

## Goals

1. **One view of the whole deployment**: provisioning (edge machines) → validation → deployment, as a live step tree with status, timestamps, durations and errors.
2. **Live logs**: stream the deployment log files from the seed node while they are written; filter, search, highlight warnings and errors; jump from a failed step to the matching log lines.
3. **Guidance built in**: for each phase, show which account reads the logs (Local Identity or Active Directory deployment), where the logs are, and when they exist.
4. **Zero install**: `Start-AzlSonar.ps1` (PowerShell 7) starts a local back end and opens the browser at `http://localhost:<port>`. No service, no database, no admin rights on the workstation beyond what the data sources need.
5. **Read-only**: Sonar never changes Azure or the nodes.
6. **Evidence**: export a run as a self-contained bundle (step timeline, logs, screenshots) for troubleshooting and support cases.

## Architecture (initial)

| Layer | Choice | Why |
|---|---|---|
| Back end | PowerShell 7 module, `System.Net.HttpListener` on localhost; JSON API plus Server-Sent Events for live updates | Ships as scripts; nothing to install |
| Azure data | ARM REST with the signed-in Azure CLI or Az PowerShell token: `Microsoft.AzureStackHCI/clusters/{name}/deploymentSettings/default` (validation and deployment step tree), `edgeMachines` and `jobs` (provisioning), Arc machines and extensions, activity log | Published APIs; the portal reads the same resources |
| Node logs | PowerShell remoting to the seed node (WinRM) with the right account per phase; fallback Arc run command (polling tail) or Arc SSH | Works on the management network and remotely through Arc |
| Front end | Single static page (HTML, CSS, vanilla JavaScript; no build step, no CDN at run time), light and dark theme | Opens anywhere; works air-gapped |
| Config | One JSON/YAML file per cluster (subscription, resource group, cluster, nodes, identity model, Key Vault secret names for credentials) | Repeatable, no hardcoded values |

## Backlog

| T | Task | Status | Owner |
|---|---|---|---|
| S-1 | Research: the deploymentSettings step tree (validation and deployment) — schema, nesting, status values, timestamps, error fields, refresh behaviour, api-version; edgeMachines lifecycle and jobs for provisioning | Done (unverified) (10 Oct; docs/research.md with Learn citations; live shape captured) | AI |
| S-2 | Research: deployment log locations on the seed node per phase (bootstrap, validation, deployment, LCM/ECE), file naming and rotation, which account can read them for Local Identity and for AD deployments, and when each log appears; documented sources only, marked where verified live | Done (unverified) (10 Oct; live log paths verified on nic26-clus01 during Deploy) | AI |
| S-3 | Research: access methods to the logs — WinRM/PS remoting (TrustedHosts for workgroup nodes), Arc run command, Arc SSH — limits and security | Done (unverified) (10 Oct; WinRM primary, SSH fallback; run command/Arc SSH excluded as writes) | AI |
| S-4 | Design: API contract between back end and page; data model for steps, logs, accounts guidance; UI wireframe (step tree, timeline, log stream, node and account panel) | Done (unverified) (10 Oct 23:20; docs/design.md) | AI |
| S-5 | Build v0.1: back end (Azure poller, log tailer, SSE), page (step tree, live log pane, filters), `Start-AzlSonar.ps1`, config file, README | Done (unverified) (10 Oct; e88fea9, c6772a8, d1b889f; GPT review blockers fixed; should-fixes in progress) | AI |
| S-6 | Tests: Pester for the back end (mocked ARM and node responses), PSScriptAnalyzer clean, page smoke test | Done (unverified) (10 Oct; 278 Pester tests pass, analyzer clean; 3e54f52) | AI |
| S-7 | Live test against the NIC 2026 lab cluster deployment (`nic26-clus01`): follow Validate and Deploy end to end; screenshots | In progress (10 Oct 23:47; Sonar live on the nic26-clus01 Deploy pass, screenshot E17/20261010-2347) | AI |
| S-8 | Provisioning view: follow both ways the machines get ready — simplified machine provisioning (edge machine lifecycle, lifecycle stages, `ProvisionOs` steps and errors) and OEM image + Arc registration (Arc machine, Connected, the four mandatory extensions); `provisioningRoute` (auto/simplified/oem-image); Arc machine names resolved from the edge machine (`<device-id>-1`) instead of assumed; `arc-registration` phase and guidance; page panel with demo data for both routes | Done (unverified) (11 Oct; Pester with the recorded 10 Oct edge machine responses and a derived InstallExtensions failure; page checked in demo mode only; OEM image route and the live page not yet run against Azure) | AI |
| S-9 | Export bundle: timeline JSON, collected logs, HTML report | Backlog | AI |
| S-10 | Docs site and session material: how to run it, what each phase means, account guidance; demo in the Azure Local session alongside Beacon | Backlog | AI |
| S-11 | Record and replay (owner request, 11 Oct): `-Record <file>` (or `recordPath`) appends every published state (keyframe, then changes only), tailer status and log line, masked, to a JSON Lines recording that survives restarts (a new session per start); `-Replay <file> [-Speed] [-StartAt] [-Autoplay]` plays it through the same page with no Azure or node access: transport bar (play/pause, 1×/30×/60×/240×, scrubber with Arc registration, Validate, Deploy and main-step markers, *Deploy +h:mm:ss*), exact state at any moment, page labelled `Replay of <cluster> · recorded <date>`; `?demo=1&replay=1` built-in recording; `tests/fixtures/recording-sample.jsonl` | Done (unverified) (11 Oct; Pester for record, masking, append, seek, start offsets, invalid files and both server modes; web-logic cases for seek, markers, clock and scrubber math; replay page checked in a headless browser with the sample and the demo recording; not yet recorded against a live deployment) | AI |
| S-12 | Log access panel (owner request, 11 Oct): the log access block takes too much space from the step tree above it and shows more than the operator needs. Collapse it by default to one status line (source, node, account, tailing ok/failed, last line time) with an expander for the detail; move account guidance and paths behind the expander or a help link; keep the step tree the primary view at every width | Backlog | AI |
| S-13 | Track-aware monitoring (owner request, 11 Oct): detect and follow every track instead of one fixed path — provisioning route (simplified machine provisioning vs OEM image + Arc registration, `provisioningRoute auto` decides from Azure), identity model (Local Identity with Key Vault vs Active Directory: AD prerequisites and domain join steps, the right log account guidance for each), the deployment itself (Validate and Deploy), and a new **update** track: solution updates on a running cluster (`updateRuns` / update summaries, per-step progress and errors, node reboots, SBE updates). Phase model, page labels and recording markers per track; demo data and Pester for each | Backlog | AI |
| S-14 | Re-run detection (lab, 11 Oct): before the deploymentSettings resource exists, and after a failed attempt until the new ARM deployment rewrites it, Sonar shows the previous state (arc-registration, or failed). Read the newest validate/deploy ARM deployment too and show *validating / re-validating* while it is Running and newer than the last deploymentSettings result. Same lag at the start of Deploy: the seed node ran `BareMetal:EnableWindowsFeaturesForDeployment` (CloudDeployment log, LCM job started 18:31:23Z) while deploymentSettings still said *Deploy not started* — when Azure lags, show the current role:interface from the tailed node log as the live step, marked *from node log* | Backlog | AI |

## Inputs from the NIC 2026 lab (10 Oct 2026)

- Two nodes provisioned with simplified machine provisioning; edge machine lifecycle seen live: `Creating → AwaitingConnection → Provisioning (onboarding to Arc) → ReadyForOs → InstallingOs (Initialize, DownloadOs, PrepareOs, RebootOs, InstallExtensions, Finalize) → Provisioned`, plus the `jobs/ProvisionOs` step list.
- Deployment model: Local Identity with Key Vault (no AD). The cluster-operations local admin is a non-built-in account on every node.
- Arc machine names after provisioning are device IDs, not host names; Sonar must map host name ↔ Arc resource (S-8: read from the edge machine's `ProvisionOs` target, else `arcMachineResourceId`).
- A `ProvisionOs` job can fail after the OS is installed and the machines are connected to Arc (for example at `InstallExtensions`); Sonar must show the failing step and its error inline (the S-8 failure case).
