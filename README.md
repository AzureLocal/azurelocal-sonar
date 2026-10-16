# AzL Sonar

**Real-time monitor for Azure Local deployments.** Follow a deployment while it runs: how each machine gets ready (simplified machine provisioning or OEM image + Arc registration), every validation and deployment step and its status, and the live deployment logs from the seed node, in a modern local web view. PowerShell back end; nothing to install. Read-only towards Azure and the nodes. Record a run to a local file and replay it later, time-scrubbed, through the same page.

Beacon checks the environment before deployment. Sonar listens to the deployment as it happens.

> Status: new. See [repo-intent.md](repo-intent.md) and the [plan](docs/plan.md).

- [Requirements](#requirements)
- [Quick start](#quick-start)
- [Record and replay](#record-and-replay)
- [Configuration reference](#configuration-reference)
- [Follow ZTP provisioning](#follow-ztp-provisioning)
- [How the machines get ready: the two routes](#how-the-machines-get-ready-the-two-routes)
- [What each phase shows](#what-each-phase-shows)
- [Where the logs are](#where-the-logs-are)
- [Which account reads the logs](#which-account-reads-the-logs)
- [Read-only and security model](#read-only-and-security-model)
- [Troubleshooting](#troubleshooting)
- [Screenshots](#screenshots)
- [Further reading](#further-reading)

## Requirements

On the workstation or jump server that runs Sonar:

| Need | Why |
| --- | --- |
| **PowerShell 7.4 or later** | The back end is a PowerShell 7 module (`#Requires -Version 7.4`). Windows PowerShell 5.1 cannot run it. |
| **Az.Accounts, signed in** (`Connect-AzAccount`) | Sonar reads Azure through the signed-in Az PowerShell context (`Invoke-AzRestMethod`). It stops at start if nobody is signed in. |
| **Read access to the resource group** (Reader is enough) | The step tree comes from `deploymentSettings`, the node status from the Arc machines (and, once Validate has started on the OEM image route, the mandatory extensions), provisioning from `edgeMachines`. All GETs. On simplified machine provisioning, the Arc machine Sonar follows is the one the edge machine names; if it sits in another resource group, Reader there too. |
| **For live logs:** WinRM to the seed node | PowerShell remoting on 5985/5986 with an account in the node's local Administrators. Workgroup (Local Identity) nodes, and any node reached by IP address, need the address in this workstation's WinRM `TrustedHosts` (Sonar checks it and tells you; it never changes it). |
| **or** SSH to the seed node with **Posh-SSH** | When WinRM is blocked, Sonar uses SSH (`Install-Module Posh-SSH -Scope CurrentUser`). `sshd` must run on the node (node preparation enables it) and a credential is required. |
| Az.KeyVault | Only when `credential.source` is `keyvault`. |
| A browser on the same machine | The page is served on `http://localhost:<port>/` and answers this machine only. |

Without log access Sonar still runs: the step tree, phases and node status come from Azure; the log pane shows why the logs are unavailable and which account and location to use.

## Get Sonar

Clone the repository (or download the ZIP from GitHub and extract it):

```powershell
git clone https://github.com/AzureLocal/azurelocal-sonar.git
cd azurelocal-sonar
```

If you downloaded the ZIP, unblock the files once so PowerShell runs them: `Get-ChildItem -Recurse | Unblock-File`.
There is nothing to install: no service, no database, no build step.

## Quick start

1. Sign in to Azure with an account that can read the resource group:

   ```powershell
   Connect-AzAccount
   Set-AzContext -Subscription '<subscription id>'
   ```

2. Copy the example config and fill in your values (one file per cluster, kept outside the repo):

   ```powershell
   New-Item -ItemType Directory -Force ./config | Out-Null   # git-ignored
   Copy-Item ./examples/sonar.config.example.json ./config/clus01.json
   ```

   ```json
   {
     "subscriptionId": "00000000-0000-0000-0000-000000000000",
     "resourceGroup": "rg-example-azl",
     "clusterName": "clus01",
     "identityModel": "LocalIdentity",
     "provisioningRoute": "auto",
     "nodes": [
       { "name": "node01", "address": "192.0.2.11", "seed": true },
       { "name": "node02", "address": "192.0.2.12" }
     ],
     "credential": { "source": "prompt" }
   }
   ```

   You do not need the Arc machine names: on simplified machine provisioning Sonar reads them from the edge machines (`<device-id>-1`), on the OEM image route the Arc machine carries the host name. Set `nodes[].arcMachineName` only to override that.

3. For a workgroup node or an IP address, make sure the seed node is in `TrustedHosts` (elevated, appends to the list; Sonar never changes it):

   ```powershell
   Set-Item WSMan:\localhost\Client\TrustedHosts -Value '192.0.2.11' -Concatenate -Force
   ```

4. Start Sonar:

   ```powershell
   ./Start-AzlSonar.ps1 -ConfigPath ./config/clus01.json
   ```

   It asks for the account that reads the logs (`credential.source: prompt`), starts the back end on `http://localhost:8642/` and opens the browser. Press Ctrl+C to stop.

| Parameter | Default | Meaning |
| --- | --- | --- |
| `-ConfigPath` | (required) | The cluster's config file. |
| `-Port` | `8642` | Local port. Pick another if 8642 is taken (Sonar says so). |
| `-Credential` | (none) | The log account; overrides `credential.source`. |
| `-NoBrowser` | off | Do not open the browser. |
| `-Record` | (none) | Also append the run to this recording file (JSON Lines). See [Record and replay](#record-and-replay). A normal recording keeps identifiers (GUIDs, IP addresses, host and cluster names). |
| `-Publishable` | off | With `-Record`: also replace every identifier with a stable pseudonym, so the recording can be shared. Needs a new file. See [Share a recording](#share-a-recording-publishable). |
| `-ExtraTerm` | (none) | With `-Publishable`: extra strings that must never appear (a company or site name). |

Add `?demo=1` to the page URL to see the page with built-in sample data (no API calls): a running deployment. `?demo=1&route=simplified` shows three machines on simplified machine provisioning (one provisioned, one installing the OS, one failed at `InstallExtensions`); `?demo=1&route=oem` shows two machines registering on the OEM image route (one updating its OS image, in `Download`; one bootstrapping, in `ArcConfiguration > ArcRegistration`). `?demo=1&replay=1` plays the demo deployment as a built-in recording, so you can try the replay controls without a file.

## Record and replay

Sonar can keep what the page was sent during a run and play it back later through the same page: the step tree, timers, phase chip, node status, tailer status and log pane rebuild exactly as they were at any moment of the run.

**Record** (live; needs the same sign-in and access as a normal run):

```powershell
./Start-AzlSonar.ps1 -ConfigPath ./config/clus01.json -Record ./recordings/clus01.jsonl
```

- The recording is JSON Lines, one event per line with its UTC time: a `session` header (Sonar version, the public config and the guidance), every published state (the first as a keyframe, then only what changed), every tailer status and every log line. An unchanged state is not written; a new keyframe follows once the changes since the last one add up to its size, so a long deployment stays small and any moment can be rebuilt quickly.
- Appending: start Sonar again with the same file and it adds a new session (nothing is overwritten). A file cut off mid-line (Sonar killed) is fine: the reader skips the partial line.
- Masked: only what the page was sent is written, after masking. Every string is masked again on the way to the file (the log account's password, `password=`, `secret=`, `token=`, `Bearer ...`, SAS `sig=`, `-Password ...`), plus the Key Vault vault and secret names as exact values. No credential, token or secret name reaches the file.
- **Recordings keep identifiers unless you record with `-Publishable`.** Masking removes secrets only. A normal recording still holds the subscription, tenant and principal GUIDs, IP and MAC addresses, the resource group, cluster and node names and host and domain names that appear in the logs and the step tree. Treat it like a log export and do not publish it as it is; see [Share a recording](#share-a-recording-publishable).
- `recordPath` in the config does the same as `-Record` (relative to the config file). The page shows a red **Recording** pill while it records.
- The `recordings/` folder of this repository is git-ignored. A recording holds the deployment's log text: treat it like a log export.

**Replay** (no Azure sign-in, no node access, nothing to configure):

```powershell
./Start-AzlSonar.ps1 -Replay ./recordings/clus01.jsonl -Speed 240 -StartAt deployment
```

| Parameter | Default | Meaning |
| --- | --- | --- |
| `-Replay` | (required) | The recording (`.jsonl`, or `.jsonl.gz`). |
| `-Speed` | `60` | Starting speed in recorded seconds per real second (0.1 to 3600). The page offers 1×, 30×, 60× and 240× (and yours). |
| `-StartAt` | the start | An offset into the recording (`1:42:10`, `90m`, `1h30m`, `45s`), a UTC time inside it, or a phase: `arc-registration`, `validation`, `deployment`. |
| `-Autoplay` | off | Start playing at once instead of paused. |
| `-Port`, `-NoBrowser` | | As for a live run. |

**Large recordings.** The page is sent the recording as one document, so a replay of a very long run needs memory in proportion to its size. A real five-hour recording of 137 MB (203,000 log lines, many of them very long) is better replayed after it is made publishable with the long lines cut (`-MaxLogTextLength`): see [Share a recording](#share-a-recording-publishable) for the measured start time and memory. `.jsonl.gz` is read directly.

The page says **Replay of clus01 · recorded 11 Oct 2026, 08:00** (your cluster and date) in a striped bar under the header, with a **Replay** badge, *Replay (not live)* instead of *Live* and *Logs (replay)* as the log title, so it is never mistaken for a live run. The transport bar has play/pause (Space when nothing else has the focus), the speed buttons, a scrubber over the whole run with markers (Arc registration, Validate, Deploy, each main Deploy step, failures, a Sonar restart, the end; click one to jump, or use **Jump to…**) and the position as the time since the current phase began (**Deploy +1:42:10**) next to the recorded clock time. Scrubbing rebuilds the exact state at that moment (the last keyframe before it plus the changes after it). Timers, durations and *Last poll* run on the replay clock. Export is not offered in a replay (the recording is the export).

## Share a recording (publishable)

A recording made with `-Publishable` (or rewritten with `scripts/Protect-Recording.ps1`) has every identifier replaced by a stable pseudonym (the same value always gets the same token inside one recording), keeps the structure, timestamps, step names and durations, and replays the same. The finished file is read back with a set of identifier detectors; if anything is left, nothing is written.

```powershell
# while recording (a new file; the finished file is verified, or renamed .NOT-PUBLISHABLE):
./Start-AzlSonar.ps1 -ConfigPath ./config/clus01.json -Record ./recordings/clus01.shareable.jsonl -Publishable

# from a recording you already have (the source is never changed):
./scripts/Protect-Recording.ps1 -Path ./recordings/clus01.jsonl -Destination ./recordings/clus01.publishable.jsonl.gz -MaxBytes 15MB

# count what is left, per category (never the values):
./scripts/Protect-Recording.ps1 -Path ./recordings/clus01.publishable.jsonl.gz -VerifyOnly
```

Token formats: `00000000-0000-0000-0000-000000000001` for GUIDs, `192.0.2.x`, `198.51.100.x`, `203.0.113.x` for IPv4, `2001:db8::N` for IPv6, `sub-0001`, `rg-01`, `cluster-01`, `node-01`, `host-01.dom-01.example.test`, `user-01`. See [Publishable recordings](docs/reference/publishable-recordings.md) for all of them, what the check can and cannot see, and what to review by hand before you publish. `examples/recording.publishable.example.jsonl` is a small recording made this way.

## Configuration reference

Unknown fields are ignored. Sonar validates the file at start and lists every problem at once.

| Field | Required | Default | Meaning |
| --- | --- | --- | --- |
| `subscriptionId` | yes | | Subscription GUID of the Azure Local instance. |
| `resourceGroup` | yes | | Resource group of the instance (and its Arc machines and edge machines). |
| `clusterName` | yes | | The `Microsoft.AzureStackHCI/clusters` resource name. |
| `apiVersion` | no | `2026-10-01` | api-version for `clusters/deploymentSettings` and the update resources. The newest GA version on Microsoft Learn (the template reference lists no property change since 2024-04-01). A preview version stays possible (`2025-09-15-preview`, for a subscription that is whitelisted for it). |
| `apiVersionFallback` | no | `2025-10-01` | Tried once when `apiVersion` is not accepted (`InvalidApiVersionParameter`, `NoRegisteredProviderFound`); Sonar says so in the warnings. Empty = no fallback. |
| `edgeApiVersion` | no | `2026-10-01` | api-version for `edgeMachines` and their `jobs` (GA from 2026-10-01; the earlier versions are previews, from `2025-12-01-preview`). |
| `track` | no | `auto` | `auto` follows the deployment and an update when Azure reports one. `add-node` or `repair` shows that operation after deployment (guidance, the Arc machines and the node log; Azure reports no steps for them). `update` always reads the update resources. Add node and repair are unverified against a live run. |
| `updateTrack` | no | `auto` | `off` never calls the update resources (`updateSummaries`, `updates`, `updateRuns`). |
| `provisioningRoute` | no | `auto` | How the machines get ready before deployment: `simplified` (simplified machine provisioning, edge machines), `oem-image` (OEM image + Arc registration; edge machines are never read) or `auto` (simplified when edge machines for the configured nodes exist in the resource group, else oem-image). See [the two routes](#how-the-machines-get-ready-the-two-routes). |
| `identityModel` | yes | | `LocalIdentity` or `ActiveDirectory`. Picks the account guidance and whether `TrustedHosts` is needed. |
| `pollSeconds` | no | `20` | Azure poll interval, 5 to 3600 seconds. |
| `nodes` | yes | | At least one node. |
| `nodes[].name` | yes | | Host name, unique. |
| `nodes[].address` | yes | | Host name or IP address Sonar connects to for logs (seed node only). |
| `nodes[].arcMachineName` | no | resolved | Arc resource name, only to override Sonar. Without it: on the simplified route, the Arc machine the node's edge machine names (the `ProvisionOs` job's target, else `properties.arcMachineResourceId`; `<device-id>-1`); on the OEM image route, the node name. |
| `nodes[].seed` | no | `false` | The node whose logs are tailed. At most one; when none is marked, the first node is used (with a warning). |
| `logs.paths` | no | `C:\CloudContent\MASLogs`, `C:\MASLogs`, `C:\CloudDeployment\Logs`, `C:\Observability`, `C:\Windows\System32\Bootstrap\Logs` | Folders tailed on the seed node. A folder that does not exist yet is checked again at every folder listing. |
| `logs.include` | no | `*.log`, `*.txt`, `*.xml` | File name patterns to tail (at least one). |
| `logs.exclude` | no | `*.etl` | File name patterns to skip (exclude wins; may be empty). |
| `logs.recurseDepth` | no | `3` | Sub-folder depth, 0 to 10. |
| `logs.activeWindowMinutes` | no | `30` | Only files written within this many minutes are tailed, 1 to 10080. |
| `logs.maxLinesPerPoll` | no | `500` | Lines read per poll across all files, 1 to 10000; the rest come next poll. |
| `logs.pollSeconds` | no | `pollSeconds` | Log poll interval, 1 to 3600 seconds. |
| `logs.transport` | no | `auto` | `auto` (WinRM, then SSH), `winrm` or `ssh`. |
| `credential.source` | no | `prompt` | `prompt` (asks once at start), `parameter` (`-Credential`; without it the current Windows identity is used for WinRM) or `keyvault`. |
| `credential.vault` | for `keyvault` | | Key Vault name. |
| `credential.usernameSecret` | for `keyvault` | | Secret that holds the user name. |
| `credential.passwordSecret` | for `keyvault` | | Secret that holds the password. |
| `credential.password`, `.secret`, `.secretValue` | never | | Rejected: secrets never go in the config file. |
| `recordPath` | no | (none) | Record every run to this file, as with `-Record` (which overrides it). Relative to the config file. See [Record and replay](#record-and-replay). |
| `ztpEvents.path` | no | (none) | The event file of the [azurelocal-ztp](https://github.com/AzureLocal/azurelocal-ztp) provisioning scripts (JSON Lines: `timestamp`, `node`, `state`, `evidence`, `nextAction`, `level`, `stage`). Sonar follows it and shows each event in the log pane. Relative to the config file. See [Follow ZTP provisioning](#follow-ztp-provisioning). |

Fixed limits (not configurable): the folders are listed (`Get-ChildItem`) on every 3rd log poll or after 60 s, whichever comes first, and the known active files are tailed in between; at most 300 active files and 2000 tracked files; 1 MiB per file per poll; a file already present at start is read from 16 KiB before its end; the back end keeps the last 5000 log lines and up to 5000 state snapshots; at most 10 browser tabs stream at once.

## Follow ZTP provisioning

Before a deployment exists, the machines are provisioned: [azurelocal-ztp](https://github.com/AzureLocal/azurelocal-ztp) mounts a virtual USB over the BMC, boots the nodes into the maintenance environment, collects the ownership vouchers and creates the edge machines. Its watch writes one JSON object per line (`Mounted`, `Booting`, `MaintenanceEnvironmentRunning`, `VoucherWritten`, `ReadyForPortal`, the failure states, and `StageStarted` / `StageCompleted` / `StageFailed`) to a local file. Point Sonar at that file and the events appear in the log pane, ordered by their own UTC time, next to the edge machine progress Sonar already reads from Azure (route `simplified`):

```json
{
  "provisioningRoute": "simplified",
  "ztpEvents": { "path": "./ztp-events.jsonl" }
}
```

Sonar only reads the file (it is opened with read sharing while the scripts append) and never writes it. `Start-ZtpMonitor.ps1` in the ZTP repository writes this config for you and starts Sonar. Errors and warnings (`level`) are coloured by the log pane's usual rules; the recording and replay carry the events like any other log line.

## How the machines get ready: the two routes

Before the cluster deployment starts, each machine has to run the Azure Stack HCI OS and be registered with Azure Arc. Azure Local has two ways to get there, and Sonar follows both:

| | Simplified machine provisioning (preview) | OEM image + Arc registration |
| --- | --- | --- |
| How it works | You claim the machine in Azure; Azure installs the OS and onboards it. Each machine is an edge machine (`Microsoft.AzureStackHCI/edgeMachines`, api `2025-12-01-preview`) with a `jobs/ProvisionOs` job. | The machine runs the OS from the OEM image; you run `Invoke-AzStackHciArcInitialization` on it. There are no edge machines. |
| Phase in Sonar | **Provisioning** | **Arc registration** |
| Progress | Edge machine lifecycle `Creating` → `AwaitingConnection` → `Provisioning` → `ReadyForOs` → `InstallingOs` → `Provisioned` (`lifecycleDetails.lifecycleStatus`), with `provisioningState` and `machineState`; the lifecycle stages and sub-stages; the `ProvisionOs` job steps (`CreatedTargetArcMachine` … `BootIntoTargetOS` … `InstallExtensions`, `DeleteUnusedRoleAssignments`, `DeleteUnusedArcMachine`) with each step's `exception[]`; the job status (`DeploymentSuccess`, `DeploymentFailed`) and its `properties.error`. | What `Invoke-AzStackHciArcInitialization` does, per machine, in three groups. **OS image update** (zero-day solution update, only when the OEM image is not the latest: `Scan`, `Download`, `Install`; Learn: typically 40-45 minutes, then a reboot, then the registration is run again) and **Bootstrap** (`NetworkConfig`, `RemoteConfig`, `WebProxy`, `TimeServer`, `HostName`, `ArcConfiguration` with `ArtifactsUpload`, `ConnectivityValidation`, `ArcRegistration`, `ArcExtensionInstall`), read on the node with `Get-ArcZeroDaySolutionUpdateStatus` and `Get-ArcBootstrapStatus` (read-only, over the tailer's transport and account, every `pollSeconds`, only during this phase); **Azure registration**: the Arc machine appears (`Microsoft.HybridCompute/machines`, api `2024-07-10`) and turns `Connected`. Lifecycle `NotStarted` → `UpdatingOsImage` → `Bootstrapping` → `Registered`, or `Failed` with the node's `Errors` text. A node that stops answering (the reboot after the update) shows *Rebooting / unreachable since* instead of failing. The mandatory extensions install later, during Validate: they appear in their own group (*Extensions (installed during Validate)*) once a validation exists. |
| Arc machine name | `<device-id>-1`, read from the edge machine (the job's target `provisioningRequest.onboardingConfiguration.resourceId`, else `properties.arcMachineResourceId`). While the OS installs, `arcMachineResourceId` points at the maintenance environment's `ROE1-…` machine in a managed resource group, which is why the job target comes first. | The host name. |
| Ready when | Lifecycle `Provisioned` and the job `DeploymentSuccess`. | Arc machine `Connected` and bootstrap `Succeeded` (Arc `Connected` alone on nodes without the bootstrap cmdlets). When every machine is registered and no validation exists, the status reads **Ready for Validate**. |

`provisioningRoute` picks the route (`auto` by default: simplified when edge machines for the configured nodes exist, else OEM image). With `auto`, edge machines that match no configured node (by name, host name or an explicit `arcMachineName`) do not count; Sonar says so in the warnings.

## What each phase shows

The header shows the current phase, worked out from what Azure reports, in this order: deployment, else validation, else the machine-readiness phase of the route (provisioning or Arc registration):

| Phase | When | What Sonar shows |
| --- | --- | --- |
| **Provisioning** (simplified route) | No validation or deployment steps yet | The **Provisioning** panel: one entry per machine with its lifecycle chip, Sonar's progress estimate (from the lifecycle and the finished job steps; the job's own `percentComplete` is in the tooltip, because it read 50 even after success in recorded responses), the Arc machine it resolved, and the tree of lifecycle stages and `ProvisionOs` steps with live timers and errors inline. Logs from `C:\Windows\System32\Bootstrap\Logs` once the OS is installed. |
| **Arc registration** (OEM image route) | No validation or deployment steps yet | The same panel titled **Arc registration**: per machine, the *OS image update*, *Bootstrap* and *Azure registration* groups with the node's own step names, step counters, live timers and error text; *Ready for Validate* when every machine is registered. Logs from `C:\Windows\System32\Bootstrap\Logs`. |
| **Validation** | `reportedProperties.validationStatus` has steps | The validation step tree: each step's status, start, end, duration and error text, the running step with a live timer, progress counts. |
| **Deployment** | `reportedProperties.deploymentStatus` has steps | The nested deployment step tree (steps within steps), with the same detail, and the live logs from the seed node. |
| **Done** | The deployment succeeded | The finished trees with durations; the logs stay on the node. |
| **Update** (unverified against a live run) | Azure reports an update installing (`updateSummaries` state *UpdateInProgress*) on a deployed cluster | The update's step tree from `updateRuns` (steps, times, expected time when Azure gives it, errors), the update version and the summary (solution and SBE version, failed health checks). Built from the Microsoft Learn REST reference only. |
| **Add node**, **Repair** (unverified against a live run) | `track` is `add-node` or `repair` in the config and the deployment is done | The guidance card (`Add-Server` / `Repair-Server`, monitoring with `Start-MonitoringActionplanInstanceToComplete`, `-Rerun`, storage rebalance), the Arc machines and the live node log. |
| **Failed** | The active phase reports an error (a failed machine counts during provisioning and Arc registration) | The failed step with its exception text expanded inline; select it to filter the logs to its time window. The phase chip names the phase that failed (`Failed: Provisioning`). |

**When Azure lags behind the node.** The deployment step list can say *Deploy not started* while the seed node is already running (it did, on a live run). Sonar then labels it: the role and interface that the node log shows (for example `BareMetal:EnableWindowsFeaturesForDeployment`) is shown as the current step, marked *from node log*, and a note says where the information was read. After a failed attempt, until Azure rewrites the result, a newer running ARM deployment is shown as *re-run pending*. At the start of Deploy mode a note says which part runs: the limited Environment Checker, the full Environment Checker, then cloud deployment (Learn, 12.2609 latest). Both are inferred from the node log and the ARM deployment list and are unverified end to end.

The Provisioning / Arc registration panel collapses once validation starts; open it again with its *Machines* toggle. The machine data stays in `/api/state` (`provisioning`) and in the export.

Live logs: every line with its time, level (errors and warnings highlighted; zero-count summaries such as `Failed: 0` are not flagged) and file; filters by level, text, file and step. A line with its own timestamp is placed by that time (converted to UTC with the node's offset); a line without one is placed by the time Sonar received it and marked `~` (approximate). **Export** downloads one JSON bundle: config without secrets, the latest state, the change-only state timeline, the log lines and metadata that says how much the caps dropped.

## Where the logs are

Confirmed on a real two-node Azure Local 2609 deployment with Local Identity (10 Oct 2026), on the seed node during the Deploy pass, read as the non-built-in deployment local admin (see [docs/research.md](docs/research.md)):

| Folder | What is there | When |
| --- | --- | --- |
| `C:\CloudContent\MASLogs` (and `ASSecurityOSConfigLogs`) | `BareMetal_*`, `AzureStackOSConfig_*`, `WDAC_*`: one file per step, timestamp in the file name | From the start of Deploy |
| `C:\MASLogs` | `BareMetal_*`, `Install-LCMController_*`, `LCMECELiteLogs\summary.*.log.xml` | From the start of Deploy |
| `C:\Observability` | `OSConfig\*`, `ObsScheduledTaskTranscripts\*`, `CredScanLogs\*` | From the start of Deploy |
| `C:\CloudDeployment\Logs` | Environment Checker and cloud deployment logs (Learn names the folder, not the files) | **Not there** about 10 minutes into Deploy; appears later in the run. Sonar keeps checking. |
| `C:\Windows\System32\Bootstrap\Logs` | `setup.log`, `arcInstallLog-*.txt`, `AzStackHci.ArcConnection.Debug.log\PowerShell_transcript.*`, ETW `*.etl` (skipped) | Provisioning and Arc registration: bootstrap, Arc agent install, the registration transcript |

**How far to trust the log-access card.** Each entry on the card carries a confidence badge. **Confirmed on Azure Local 2609 (Local Identity)** means the folders and the account were checked on a real deployment. **From Microsoft docs — not yet confirmed** means the entry comes from Microsoft Learn only (today: every Active Directory entry, and the provisioning, validation and post-deployment phases); on your version or identity model the details may differ. Either way Sonar watches every known log folder, so it still finds the logs; if an entry is wrong for you, please open an issue.

Also on the nodes, not tailed by default (add them to `logs.paths` if you need them; on the OEM image route the agent log is worth adding while the machines register): `C:\ProgramData\AzureConnectedMachineAgent\Log` (`himds.log`, `azcmagent.log`) and `C:\ProgramData\GuestConfig\ext_mgr_logs`, `extension_logs` (Arc agent and extensions). Before the OS is installed, the maintenance environment keeps its logs under `/var/log`; get them through the Configurator app support package.

## Which account reads the logs

Learn does not document the permissions on these folders; members of the node's local Administrators could read them in a live test. The page's **Log access** card shows the same guidance for your identity model, with sources.

| Phase | Local Identity | Active Directory |
| --- | --- | --- |
| Provisioning (OS installed) | The local admin set when provisioning, or the non-built-in local admin you created with the same credentials on every node | The local administrator (same on every node); if the nodes were joined to the domain before deployment (2604+), the deployment user added to local Administrators |
| Arc registration (OEM image) | The built-in `Administrator` until the deployment local admin exists, then the deployment local admin | The built-in `Administrator` until the deployment admin exists, then the local administrator used for deployment (or the deployment user, if the nodes were joined to the domain beforehand) |
| Validation | The deployment local admin (`localAdminUserName`), non-built-in | The local administrator |
| Deployment | The deployment local admin | The local administrator; the LCM (deployment) user is added to local Administrators during deployment |
| After deployment | The deployment local admin; `RecoveryAdmin` (password in Key Vault) | The LCM user; the local administrator |

Do not use the built-in `Administrator` for validation or deployment: deployment renames it to `ASBuiltInAdmin`, so it stops working mid-run (Sonar warns at start). It is fine while the machines register with Arc. Azure side: Reader on the resource group is enough for everything Sonar does.

## Read-only and security model

- **Loopback only.** The server binds `http://localhost:<port>/` and answers requests from this machine only (anything else gets 403). Only `GET` is accepted (others get 405). Static files are served from the `web` folder only.
- **Never writes to Azure.** Every Azure call is a `GET` through `Invoke-AzRestMethod`. Arc run command and Arc SSH are not used because both write to Azure.
- **Never writes to a node.** Each poll runs one read-only script that lists and reads log files with shared read access (the writer and log rotation are never blocked). Over SSH the script is streamed through stdin; no file is written on the node. Sonar keeps no state on the node.
- **Never changes the workstation.** Sonar reads `TrustedHosts` and tells you what is missing; it never sets it. The only file it ever writes is the recording you ask for with `-Record` (or `recordPath`), and it only appends to it.
- **Recordings.** A recording holds what the page was sent, masked again on the way to the file (see [Record and replay](#record-and-replay)): no credential, token or Key Vault name. It still holds identifiers unless it was made with `-Publishable`. A replay (`-Replay`) reads that file only: no Azure sign-in, no call to Azure, no connection to a node.
- **Secrets.** No secret is allowed in the config file. Key Vault secrets are read once at start and kept in memory as a `PSCredential`. `/api/config` and the export carry no secrets, no secret names and no node addresses. Log text is redacted before it is stored, served or exported: the log account's password, and common secret formats (`password=`, `secret=`, `token=`, `AccountKey=`, `Bearer ...`, SAS `sig=`, `-Password ...`).
- **SSH host keys.** The SSH fallback accepts the node's host key on first use (Posh-SSH `-AcceptKey`). Use it on a management network you trust.
- **Resource use.** Bounded memory (5000 lines, 5000 snapshots, 2000 tracked files), at most 10 live browser streams, and a slow or stuck browser tab is dropped instead of slowing the others.

## Troubleshooting

| Symptom | Cause and fix |
| --- | --- |
| `No Azure sign-in found in this PowerShell session` | Run `Connect-AzAccount` in the same PowerShell 7 window, then start Sonar again. |
| `Az PowerShell (Az.Accounts) is not installed` | `Install-Module Az.Accounts -Scope CurrentUser`. |
| `GET deploymentSettings ... failed` (403 or 404 on the subscription) | Wrong subscription in the Az context or no access: `Set-AzContext -Subscription <id>` and check you have Reader on the resource group. A 404 on `deploymentSettings` alone is normal before the deployment starts (phase: provisioning or Arc registration). |
| The page shows **Arc registration** but you use simplified machine provisioning | With `provisioningRoute: auto`, no edge machine matched a configured node. Name the nodes after the edge machines (or their host names), or set `provisioningRoute` to `simplified`. The warnings say how many edge machines matched nothing. |
| A machine stays **Not started** on the OEM image route | Nothing read on the node and no Arc machine with the node's name in the resource group: run `Invoke-AzStackHciArcInitialization` on the node, or set `nodes[].arcMachineName` if you registered it under another name. The *OS image update* / *Bootstrap* groups say *not read from the node yet* with the reason when Sonar cannot reach the node (same WinRM/SSH requirements as the log tailer). |
| Logs unavailable: `... is not in the WinRM client TrustedHosts list` | Workgroup (Local Identity) nodes and IP addresses use NTLM. In an elevated session: `Set-Item WSMan:\localhost\Client\TrustedHosts -Value '<address>' -Concatenate -Force`. Check with `Get-Item WSMan:\localhost\Client\TrustedHosts`. |
| Logs unavailable: `WinRM: Access is denied` | The account is not a local admin on the node, or it is a local account that is not the built-in Administrator and the node filters its token (`LocalAccountTokenFilterPolicy` must be 1; it was 1 on the test nodes). Use the deployment local admin, not `Administrator`. |
| Logs unavailable: WinRM cannot connect (timeout, firewall, `5985`) | WinRM is blocked from this workstation. Install Posh-SSH (`Install-Module Posh-SSH -Scope CurrentUser`) and keep `logs.transport` at `auto`, or set it to `ssh`. SSH needs a credential (prompt, `-Credential` or Key Vault) and `sshd` running on the node. |
| `SSH: the Posh-SSH module is not installed` | `Install-Module Posh-SSH -Scope CurrentUser`, then restart Sonar. |
| `Not created yet (checked at every folder listing): C:\CloudDeployment\Logs` | Normal early in Deploy: the folder appears later. The other folders are tailed meanwhile. |
| `Cannot listen on http://localhost:8642/` | The port is in use (another Sonar?). Start with `-Port 9000`. |
| `Cannot write the recording ...` or `The recording path is a folder` | `-Record` (or `recordPath`) must name a file in a folder you can write to, for example `./recordings/clus01.jsonl`. Sonar checks it before it starts. |
| `The Recorder stopped unexpectedly` | Writing the recording failed (for example the disk is full). The live view carries on; restart Sonar with the same `-Record` file to append a new session. |
| `... is not an AzL Sonar recording` or `... holds no state snapshots` | `-Replay` needs a file written by `-Record`. A recording made before the first state was published has nothing to play. |
| `-StartAt ... is past the end of the recording` | The offset is longer than the recording; the message gives its length. |
| `N line(s) of the recording are not valid events and were skipped` | Usually the last line of a session cut off when Sonar was killed. Harmless. |
| The page says **Polling** instead of **Live** | The live stream dropped or 10 tabs are already open; the page polls every 5 s and reconnects by itself. Close extra tabs. |
| The log account stopped working mid-deployment | It was the built-in `Administrator`, which deployment renames to `ASBuiltInAdmin`. Restart Sonar with the deployment local admin. |
| `credential.source is keyvault but Az.KeyVault is not installed` | `Install-Module Az.KeyVault -Scope CurrentUser`; the signed-in account needs secret get on the vault. |

## Screenshots

<!-- Screenshots go here once the live run (plan task S-7) is complete: the step tree during Deploy, the live log pane with a step filter, the Log access card, and the dark theme. -->

_Screenshots will be added after the live test on a test cluster (plan task S-7)._

## Further reading

- [Getting started](docs/getting-started.md) and [How it works](docs/how-it-works.md)
- [Design](docs/design.md): the API, data model and behaviour contract
- [Research](docs/research.md): Microsoft Learn sources and what was verified live
- [Publishable recordings](docs/reference/publishable-recordings.md) and the [event feed](docs/reference/events.md) (the JSON Lines contract other tools can emit, and how to launch Sonar from a deployment pipeline)
- Export bundle: `./scripts/Export-SonarBundle.ps1 -Recording <file> -OutDirectory <dir>` writes a timeline JSON and a self-contained HTML report from any recording.
- Tests: `Invoke-Pester -Path tests` (Pester 5; no Azure or node calls). Lint: `Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1`. See [CONTRIBUTING.md](CONTRIBUTING.md) and the [CHANGELOG](CHANGELOG.md).
