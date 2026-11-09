# How it works

Sonar has three parts (four while it records a run, see [Record and replay](#record-and-replay)), all started by one script (`Start-AzlSonar.ps1`) in one PowerShell 7 process. The full contract is in [design.md](./design.md).

| Part | What it does | Source |
| --- | --- | --- |
| Azure poller | Every `pollSeconds` (20 s): reads the deployment's step trees (validation and deployment) from `deploymentSettings/default`, the edge machines of the resource group with their `ProvisionOs` job (simplified machine provisioning), the Arc machine of every node and, on the OEM image route once a validation exists, each Arc machine's mandatory extensions | Azure Resource Manager GETs through the signed-in Az PowerShell context, the same resources the portal reads |
| Log tailer | Follows the deployment log files on the seed node as they grow | One read-only script per poll over PowerShell remoting (WinRM), or over SSH with Posh-SSH when WinRM is blocked |
| Web view | Step tree, live log stream with filters, phase and node status, log access guidance, export | Static page served from `http://localhost:<port>/`, live updates over Server-Sent Events, polling fallback |

## Phases Sonar follows

1. **Provisioning** or **Arc registration**: before any validation step is reported, how each machine gets ready. Sonar follows both routes (`provisioningRoute`, `auto` by default):
   - **Simplified machine provisioning** (preview, phase *Provisioning*): each machine is an edge machine. Sonar shows its lifecycle (`Creating` → `AwaitingConnection` → `Provisioning` → `ReadyForOs` → `InstallingOs` → `Provisioned`), the lifecycle stages, and the `ProvisionOs` job's steps with their errors (for example `InstallExtensions` failing because an extension could not be downloaded). The Arc machine is named after the device (`<device-id>-1`); Sonar reads the name from the edge machine, so the config does not need it. When the machines are provisioned with azurelocal-ztp, Sonar also follows the ZTP event file. It adds ZTP's per-machine steps (the management address before the claim and after the OS install, then the BIOS restore), and says **ZTP complete: OS configuration next** when every machine is done. See [Following a zero-touch provisioning run](./ztp.md).
   - **OEM image + Arc registration** (phase *Arc registration*): no edge machines. The node is registered with `Invoke-AzStackHciArcInitialization` and its Arc machine carries the host name. Sonar shows what the registration does, per machine: the **OS image update** (zero-day solution update, only when the OEM image is not the latest: Scan, Download, Install; 40-45 minutes, then a reboot) and the **Bootstrap** (NetworkConfig ... ArcConfiguration > ArcRegistration, ArcExtensionInstall), both read on the node with `Get-ArcZeroDaySolutionUpdateStatus` and `Get-ArcBootstrapStatus` by the node probe, and the **Azure registration** (the Arc machine appears and turns `Connected`). A node that reboots shows *Rebooting / unreachable since*; when every machine is registered the status reads *Ready for Validate*. The four mandatory extensions (`AzureEdgeDeviceManagement`, `AzureEdgeLifecycleManager`, `AzureEdgeRemoteSupport`, `AzureEdgeTelemetryAndDiagnostics`) install during Validate, so they appear only then, in their own *Extensions (installed during Validate)* group.

   When validation starts, the page moves on to the Validate mode; the Provisioning tile stays and can be clicked to look at the machines again.
   **OS configuration** (between Provisioning and Validation, from the toolkit's event file): once ZTP is done, or an ISO install is in place, the toolkit configures each node. The page follows it per machine, with the method (ZTP or ISO), the transport and the versions, 14 steps (the computer name and Arc registration are verify-only on a ZTP machine), the retries and restarts, the guarded network change and the domain join. It is ready when every machine has converged; it never keeps Provisioning running. See [stage by stage](./stages.md#os-configuration).
2. **Validation**: every validation step with its status, times, duration and errors.
3. **Deployment**: every deployment step and sub-step, with the live logs from the seed node.
4. **Done** or **Failed**: the deployment succeeded, or the active phase reported an error (the failed step's exception text is shown inline; a failed machine counts during provisioning and Arc registration, and the chip says which phase failed).

## Live logs

- **Reading.** Each poll reads only the new bytes of each active file (shared read, so the writer and rotation are never blocked). Listing the folders is the expensive part, so it runs on every 3rd poll or after 60 s; in between only the files already known are tailed. Renamed (rotated) files keep their place, so their lines are not sent twice.
- **Time.** Each line is placed by its own leading timestamp when it has one (ISO 8601, `yyyy-MM-dd HH:mm:ss`, `[yyyy-MM-dd HH:mm:ss]`, `MM/dd/yyyy HH:mm:ss`, transcript `Start time:`), else by the timestamp in its file name, else by the time Sonar received it. Node-local times are converted to UTC with the node's offset. Lines placed by receive time are marked `~` and count as approximate when you filter the logs to a step.
- **Levels.** Errors and warnings are highlighted; summaries such as `error=0`, `Failed: 0` or `0 failed` are not.
- **Order and gaps.** Every line has a sequence number. The page merges the catch-up request and the live stream in that order, never shows a line twice, and notices when the back end restarted (new instance id), then reloads.
- **Memory.** The back end keeps the last 5000 lines; the page keeps up to 20000 and draws the newest 3000.

## Export

**Export** (`GET /api/export`, see the [API reference](./api.md#apiexport)) downloads one JSON bundle: the config (no secrets), the guidance, the latest state, the change-only state timeline (a snapshot only when something changed, at most 5000; the latest state is always included) and the log lines, with metadata that says how many snapshots and lines the caps dropped.

## The API

The page is a client of Sonar's own HTTP API: nine read-only `GET` routes on `http://localhost:<port>/` (config, about, guidance, details, state, logs, the `events` stream, export and, in a replay, the recording), behind the per-start access token. Anything on the same machine that has the token can read them. Every route, field, the stream protocol and recipes for curl and PowerShell are in the [API reference](./api.md).

## Beyond the deployment

Besides Validate and Deploy, Sonar labels three more situations. They are built from Microsoft Learn only and are **unverified against a live run**:

- **Azure lagging behind the node.** If the deployment step list still says *Deploy not started* while the seed node log shows the orchestrator running a role and interface, the page shows that as the current step (*from node log*) and says so; a newer running ARM deployment is shown as *re-run pending*. At the start of Deploy mode a note names the stage: the limited Environment Checker, the full one, then cloud deployment.
- **Updates.** After deployment, `updateSummaries`, `updates` and `updateRuns` give an update its own phase, step tree and Log access entry.
- **Add node and repair.** Azure has no resource for them; set `track` to `add-node` or `repair` and Sonar shows the Log access entry, the Arc machines and the node log.

## Record and replay

**Recording** (`-Record <file>` or `recordPath`) adds a fourth part to a live run: a recorder on its own runspace that, every half second, writes what changed since its last look to an append-only JSON Lines file, one event per line with its UTC time:

| Event | Written when | Holds |
| --- | --- | --- |
| `session` | Sonar starts (a restart appends a new one) | format, Sonar version, instance id, the public config, the phase guidance |
| `state` | the published state changed | the first state of a session in full (a keyframe), then only the changes (`ops`: set, delete, truncate by path); a new keyframe once the changes since the last one add up to its size, or after 200 changes |
| `tailer` | the log tailer status changed | the status (connected, unavailable with the reason, active files) |
| `log` | new log lines | the lines exactly as the page got them (seq, times, file, level, text) |
| `end` | Sonar stopped cleanly | nothing |

The recorder reads the same shared state the page is served from, so it records only what the page was sent, and masks every string again before writing (secret formats, the log account's password and the Key Vault names). An unchanged state is not written; a poll that changed only the time and the running timers is a few hundred bytes.

**Replaying** (`-Replay <file>`) starts the same web server with no poller, tailer, node probe or Azure sign-in. It checks the file (a session header first, a known format, at least one state; a cut-off line is skipped and counted) and serves it whole at `/api/replay`; `/api/config` carries the recorded config plus a `replay` object (cluster, file, recorded from/to, speed, start, autoplay). The page then plays it locally: a clock moves the position at the chosen speed; at each step the page takes the last keyframe before the position, applies the changes after it, and renders the result, the log lines up to the position and the tailer status through the same code as a live run. Moving forward appends the new log lines as they would have arrived; jumping back or far ahead rebuilds the log pane at the new position. Timers and *Last poll* use the replay clock.

The scrubber's markers come from the states themselves: each change of phase (Arc registration or Provisioning, Validate, Deploy; a second Deploy after a failure is *Deploy (2)*), each main Deploy step when it starts (the top-level steps, or the children of a single top-level step), the first failed step of a run, a Sonar restart and the end. The position reads as the time since the current phase began (**Deploy +1:42:10**), counted from the phase's first step, which can be before the recording started.

`?demo=1&replay=1` plays the demo deployment as a built-in recording (64 minutes: Arc registration, Validate, Deploy), made with the same keyframe and change format.

## What Sonar reads

Sonar only reads. Everything it takes from Azure, the nodes and the BMC is in this table; the reference for these calls (what each one returns, what else is possible) is in the ZTP docs: the [API reference](https://github.com/AzureLocal/azurelocal-ztp/blob/main/docs/appendix/api-reference.md) for Azure Resource Manager and Redfish, and [the Configurator app API](https://github.com/AzureLocal/azurelocal-ztp/blob/main/docs/appendix/configurator-app-api.md) for the service in the maintenance environment.

| Source | What Sonar reads | How | When |
| --- | --- | --- | --- |
| **Azure Resource Manager** | The cluster's `deploymentSettings/default` (validation and deployment step trees) | `GET` through `Invoke-AzRestMethod` under your Az PowerShell sign-in; `apiVersion` (default `2026-10-01`), with `apiVersionFallback` tried once | Every `pollSeconds` |
| | `edgeMachines` and each machine's `jobs/ProvisionOs` (simplified machine provisioning: lifecycle, the OS-install step tree, the Arc machine ID) | `GET`; `edgeApiVersion` (default `2026-10-01`). Skipped when `provisioningRoute` is `oem-image`. | Every `pollSeconds` |
| | The Arc machine of each node (`Microsoft.HybridCompute/machines`) and its `extensions` | `GET`, api-version `2026-07-15`; the extensions on the OEM-image route only, once a validation or deployment has steps | Every `pollSeconds` |
| | Running ARM deployments (`Microsoft.Resources/deployments`, filter `provisioningState eq 'Running'`) | `GET`, api-version `2021-04-01` | While the deployment has not succeeded |
| | `updateSummaries/default`, `updates`, `updates/{name}/updateRuns` of the cluster | `GET`; skipped when `updateTrack` is `off` | Every `pollSeconds` |
| **Nodes (WinRM or SSH)** | The deployment log files on the seed node | A read-only script per poll: it lists the `logs.paths` folders and tails growing files | Every `logs.pollSeconds` |
| | Arc registration status on each node, OEM-image route only: `Get-ArcBootstrapStatus` and `Get-ArcZeroDaySolutionUpdateStatus` | The two local PowerShell cmdlets of the node, with `-ErrorAction SilentlyContinue` | Only while Arc registration runs |
| **This workstation** | WinRM `TrustedHosts` | Reads it and tells you; never sets it | At start |
| **Key Vault** | The log account's user name and password, only with `credential.source` `keyvault`; and the domain account's password, the `keyvault://` reference of `identity.active_directory.domain_join_account.password`, only after a node reports `DomainJoined` | `Get-AzKeyVaultSecret`, held in memory as a secure string and masked everywhere | Once, at start; the domain password once, at the first `DomainJoined` |
| **ZTP event file** | The events a ZTP run appends (`ztpEvents.path`) | Reads the local file, shared with the writer | Every 2 seconds |
| **ARM event file** | The events the toolkit's Validate and Deploy run appends: the checks before the submit, each validation and deployment step with its number and status, the failing step and the known issue, the approval (`armEventsPath`) | Reads the local file, shared with the writer; a new run starts on its `RunStarted` line | Every 2 seconds |
| **Verification event file** | The events the toolkit's pre-cluster verification gate appends (`precluster-verification-events.jsonl` in its report directory): the run, each check with its status, node, message, remedy and source, and the verdict with its expiry. Only the latest run is shown. | Reads the local file, shared with the writer (the whole file whenever it changes) | Every 2 seconds |
| **OS configuration event file** | The events the toolkit's OS configuration run appends: the run, each node's method and versions, each step's plan and result, retries, the guarded network change, the domain join (`osConfigEventsPath`) | Reads the local file, shared with the writer; a node's attempt restarts on its next `NodeStarted` line | Every 2 seconds |
| **Azure Arc run commands** | The OS configuration run commands of a node being configured over Arc Run Command (`Microsoft.HybridCompute/machines/{name}/runCommands`): name, state, age; one stuck in *Creating* for 10 minutes is flagged | `GET` (read-only), only for a node with a running attempt over Arc Run Command; unverified against a live run | Every `pollSeconds` while it runs |
| **BMC (Redfish)** | Nothing | Sonar makes no Redfish call. The ZTP stages that use Redfish are in the ZTP [API reference](https://github.com/AzureLocal/azurelocal-ztp/blob/main/docs/appendix/api-reference.md). | |
| **Configurator app service (TCP 20001)** | Nothing | Sonar does not call the maintenance environment's REST service. ZTP's Device stage does ([the Configurator app API](https://github.com/AzureLocal/azurelocal-ztp/blob/main/docs/appendix/configurator-app-api.md)). The two node cmdlets above are the local PowerShell front end of the same bootstrap service on an installed OS. | |

Azure access is one function, `Invoke-AzlSonarArmGet`, which calls `Invoke-AzRestMethod -Method GET`; there is no other Azure call site in the module besides the sign-in checks and the Key Vault read. Only Arc machine IDs of the form `/subscriptions/{s}/resourceGroups/{rg}/providers/Microsoft.HybridCompute/machines/{name}` are followed. The sign-in needs read access to these resources only. How each ZTP stage shows up in the page is in [Following a ZTP run](./ztp.md).
## Read-only

Sonar only reads Azure and the nodes. It never starts, retries or cancels a deployment, never writes to Azure (no Arc run command, no Arc SSH), never writes to a node, and never changes the workstation's `TrustedHosts`. The only file it writes is the recording you ask for, and a replay never contacts Azure or a node. The page is served to this machine only, and secrets are masked in everything it shows, exports or records.
