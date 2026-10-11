# AzL Sonar — design (v0.1)

This is the contract every part of Sonar is built to (plan task S-4). Back end, page and tests follow it exactly; change it here first.

## Layout

| Path | What |
| --- | --- |
| `Start-AzlSonar.ps1` | Entry point. `-ConfigPath <file>` (required), `-Port` (default 8642), `-NoBrowser`, `-Credential <pscredential>` (node logs; optional). Imports the module, starts the server, opens the browser, runs until Ctrl+C. |
| `src/AzlSonar/AzlSonar.psd1`, `AzlSonar.psm1` | PowerShell 7 module, `Set-StrictMode -Version Latest`. Public functions: `Start-AzlSonarServer`, `Get-AzlSonarDeploymentState`, `ConvertTo-AzlSonarStepTree`, `Get-AzlSonarPhaseGuidance`, `Read-AzlSonarConfig`. |
| `src/AzlSonar/Private/*.ps1` | Azure poller, log tailer, node probe (Arc registration status on the nodes, OEM image route), HTTP/SSE server, helpers. |
| `src/AzlSonar/web/index.html`, `app.js`, `app.css` | The page. Vanilla HTML/CSS/JS, no build step, no CDN, no external fonts. Light and dark theme (`prefers-color-scheme` + toggle). |
| `src/AzlSonar/data/phase-guidance.json` | Which account reads which logs in which phase (see below). |
| `examples/sonar.config.example.json` | Example config with neutral values (zero GUIDs, RFC 5737 / documentation addresses). |
| `tests/*.Tests.ps1` | Pester 5. Mocked ARM and node responses; no live calls. `WebLogic.Tests.ps1` runs the page's pure log logic under Node (`tests/web-logic.cases.js`); skipped when Node is not installed. |

## Config (`sonar.config.json`)

```json
{
  "subscriptionId": "00000000-0000-0000-0000-000000000000",
  "resourceGroup": "rg-example-azl",
  "clusterName": "clus01",
  "apiVersion": "2025-09-15-preview",
  "edgeApiVersion": "2025-12-01-preview",
  "provisioningRoute": "auto",
  "identityModel": "LocalIdentity",
  "pollSeconds": 20,
  "nodes": [
    { "name": "node01", "address": "192.0.2.11", "seed": true },
    { "name": "node02", "address": "192.0.2.12" }
  ],
  "logs": {
    "paths": ["C:\\CloudContent\\MASLogs", "C:\\MASLogs", "C:\\CloudDeployment\\Logs", "C:\\Observability", "C:\\Windows\\System32\\Bootstrap\\Logs"],
    "include": ["*.log", "*.txt", "*.xml"],
    "exclude": ["*.etl"],
    "recurseDepth": 3,
    "activeWindowMinutes": 30,
    "maxLinesPerPoll": 500,
    "pollSeconds": 20,
    "transport": "auto"
  },
  "credential": { "source": "prompt" }
}
```

`identityModel`: `LocalIdentity` or `ActiveDirectory`. `credential.source`: `prompt` (Get-Credential at start), `parameter` (`-Credential`), or `keyvault` with `vault`, `usernameSecret`, `passwordSecret` (read once at start with Az.KeyVault; never logged, never sent to the page). `provisioningRoute`: `simplified`, `oem-image` or `auto` (default; see *Machine readiness* below). `nodes[].arcMachineName` is optional and overrides the Arc machine Sonar resolves; the normalised config keeps `arcMachineName` (the node name when not given) and `arcMachineNameSet` (whether the config gave it). `logs.pollSeconds` defaults to the top-level `pollSeconds`. `logs.transport`: `auto` (WinRM, then SSH), `winrm` or `ssh`. Every field and its default is listed in the README.

## Azure poller (read-only)

Uses the signed-in Az PowerShell context (`Invoke-AzRestMethod`). Every `pollSeconds`:

1. `GET .../providers/Microsoft.AzureStackHCI/clusters/{cluster}/deploymentSettings/default?api-version={apiVersion}` → `properties.deploymentMode`, `properties.provisioningState`, `properties.reportedProperties.validationStatus` and `.deploymentStatus`. Each status object is `{ status, steps[] }`; a step is `{ name, description, fullStepIndex, startTimeUtc, endTimeUtc, status, steps[]?, exception[]? }` (steps nest; `exception` is an array of strings). Either status object can be `{}` (not started). Learn documents `Error`, `Success`, `InProgress`; the lab also shows `Not Started`. Normalisation is case-insensitive and tolerant: unknown values become `unknown` with the raw value kept in `rawStatus`.
2. Unless `provisioningRoute` is `oem-image`, best effort (ignore 404/400): `GET .../providers/Microsoft.AzureStackHCI/edgeMachines?api-version={edgeApiVersion}` (edge machines exist from 2025-12-01-preview) in the resource group, and for each `GET {edge machine id}/jobs/ProvisionOs?api-version={edgeApiVersion}` (404 before it is submitted; then `properties.operationDetails[name=ProvisionOs].status` stands in).
3. The route and each node's Arc machine (see *Machine readiness*), then `GET {arc machine resource id}?api-version=2024-07-10` per node → `properties.status` (Connected/Disconnected), `properties.lastStatusChange`, `properties.agentVersion`, `systemData.createdAt`.
4. OEM image route only, once a validation or deployment has steps, for each Arc machine that exists: `GET {arc machine resource id}/extensions?api-version=2024-07-10` → the four mandatory extensions (they install during Validate, not during Arc registration), into `extensions`.

**Node probe (OEM image route, Arc registration only).** A third worker (`Invoke-AzlSonarNodeProbeLoop`, not started when `provisioningRoute` is `simplified`) runs while `provisioning.route` is `oem-image` and `activePhase` is `arc-registration`. Every `pollSeconds` it opens (and keeps) one connection per unfinished node with the log tailer's transport and account (WinRM, then SSH via Posh-SSH; `logs.transport`) and runs a read-only script: `Get-ArcZeroDaySolutionUpdateStatus` and `Get-ArcBootstrapStatus` with `-ErrorAction SilentlyContinue` (and `-JsonResult` when the command offers it); a missing command is reported as not available (simplified-route nodes, other images). Objects are flattened on the node (enums as names, dates ISO 8601 UTC; Windows PowerShell 5.1). The result lands in `Shared.NodeProbe[node]` and the poller merges it into `provisioning.nodes[]`. A node is finished (no longer read) when its Arc machine is `Connected` and its bootstrap `Succeeded` (or the command is not on it). A failed attempt keeps the last data and records `unreachableSince` (first failure). Messages and errors are masked with `Protect-AzlSonarText` and the credential.

`ConvertTo-AzlSonarStepTree` turns a status object into a flat-or-nested normalized tree:
`{ id (fullStepIndex), name, description, status (normalized: notstarted|running|success|error|skipped), start, end, durationSeconds, errors[], children[] }`. Durations: end−start; running steps use now−start.

`Get-AzlSonarDeploymentState` returns
`{ cluster, mode, provisioningState, phase (provisioning|arc-registration|validation|deployment|done|failed), activePhase, provisioning{ route, routeSource, phase, status, readyForValidate, nodes[] }, extensions{ shown, status, nodes[{ name, arcMachineName, status, ready, total, extensions[], errors[], tree[] }] }, validation{ status, tree[] , counts{} }, deployment{ status, tree[], counts{} }, nodes[{ name, arcMachineName, arcMachineResourceId, arcSource, arcStatus, lastStatusChange, agentVersion, registeredAt }], edgeMachines[], current { phase, stepPath[] , stepName }, warnings[], pollError, polledAt }`.
`current` = the deepest step with status running (else the last finished step). `phase`: deployment if deploymentStatus has steps, else validation if validationStatus has steps, else the machine-readiness phase of the route (provisioning or arc-registration). `done` when the deployment succeeded; `failed` when the active phase is in error (for the machine-readiness phase: any machine in error). `activePhase` is the phase without done/failed. In the machine-readiness phase, `stepPath` starts with the node name (one synthetic parent per machine).

### Machine readiness: the two routes (plan task S-8)

**Route.** `provisioningRoute` `simplified` or `oem-image` as configured (`routeSource: config`); `auto` (`routeSource: auto`) picks simplified when at least one edge machine maps to a configured node, else oem-image (with a warning when edge machines exist but none map). An edge machine maps to a node by its name, its host name (`siteDetails.deviceConfiguration.hostName`, else the job's `provisioningRequest.deviceConfiguration.hostName`), or its Arc machine name against an explicit `arcMachineName`.

**Arc machine per node** (`arcSource`): an explicit `arcMachineName` always wins (`config`; read in the config's resource group, or at the edge machine's id when the names match). Otherwise, simplified route: the `ProvisionOs` job's `provisioningRequest.onboardingConfiguration.resourceId` (`edgeMachine.job`, the `<device-id>-1` target), else the edge machine's `properties.arcMachineResourceId` (`edgeMachine`; while the OS installs this is the maintenance environment's `ROE1-…` machine in a managed resource group). OEM image route or no edge machine: the node name in the config's resource group (`nodeName`). Ids read from Azure are used only when they match `/subscriptions/*/resourceGroups/*/providers/Microsoft.HybridCompute/machines/*`.

**`provisioning.nodes[]`** (one per configured node): `{ name, route, exists, edgeMachineName, lifecycle, lifecycleMessage, status (notstarted|running|success|error|unknown), percent, reportedPercent, provisioningState, machineState, connectivityStatus, arcMachineName, arcMachineResourceId, arcSource, arcStatus, job{ status, operationStatus, provisioningState, start, end, error }, extensions[{ name, present, rawStatus, status, message, start, end }], start, end, errors[], tree[] }`; OEM image nodes add `update` and `bootstrap` (`{ available, state (read|notAvailable|noData|notRead), status, rawStatus, done, total, current, start, end }`, leaf step counts) and `probe` (`{ state (ok|unreachable|pending), reason, transport, lastProbeUtc, lastSuccessUtc, unreachableSince }`). Tree nodes have the `ConvertTo-AzlSonarStepTree` shape, with ids set by Sonar.

| | Simplified (`provisioning`) | OEM image (`arc-registration`) |
| --- | --- | --- |
| `lifecycle` | `lifecycleDetails.lifecycleStatus.status` (`Creating`, `AwaitingConnection`, `Provisioning`, `ReadyForOs`, `InstallingOs`, `Provisioned`); `NotCreated` without an edge machine | `NotStarted`, `UpdatingOsImage` (update InProgress), `Bootstrapping` (bootstrap running or done but the Arc machine not Connected yet, or the update done and the registration not run again), `Registered` (Arc `Connected` and bootstrap `Succeeded`, or the bootstrap status cannot be read on that node), `Failed` (update or bootstrap Failed, with the node's `Errors[]` text, or the agent Expired), `Unknown` (Arc machine unreadable and nothing read on the node); `lifecycleMessage` adds *Rebooting / unreachable since <time>* while the node does not answer |
| `tree` | the lifecycle stages with their sub-stages (ids `lifecycle.N`, `lifecycle.N.M`), then one `ProvisionOs job` node (id `job`; status from the job `status`, e.g. `DeploymentSuccess`/`DeploymentFailed`; errors = `properties.error` as `code: message`) whose children are the job's `reportedProperties` validation and deployment steps (ids `job.N`) with their `exception[]` | three groups: `OS image update` (`update`, `update.N`: the `DetailedResponse[]` of `Get-ArcZeroDaySolutionUpdateStatus`), `Bootstrap` (`bootstrap`, `bootstrap.N`, `bootstrap.N.M`: `Get-ArcBootstrapStatus`), node step names kept, `StartTime` dropped on `NotStarted` entries (it is the time of the call), `Errors[]` (or `Message`) as errors; a group the node did not report is `NotAvailable`, `NoData` or `NotRead` with the reason; `Azure registration` (`arc`) with `Arc machine registered` (`arc.machine`) and `Arc agent Connected` (`arc.connected`) |
| `status` | error when the lifecycle, `provisioningState` or `machineState` failed, the job failed or has an error, or any tree node is in error; success when `Provisioned` and the job succeeded; notstarted without an edge machine; else running | from `lifecycle`: Registered success, Failed error, NotStarted notstarted, Unknown unknown, else running |
| `percent` | Sonar's estimate: Creating 0, AwaitingConnection 5, Provisioning 15, ReadyForOs 25, InstallingOs 25 + 70 × finished/reported job steps (max 95), Provisioned 100. `reportedPercent` is the job's `percentComplete` (recorded responses showed 50 both mid-run and after success, so it is not drawn) | finished leaf steps / leaf steps (bootstrap + Azure registration, plus the update once it started), at most 99 until Registered (100) |
| `extensions` | from the edge machine's `reportedProperties.extensionProfile.extensions` (by the extension resource name), informational | empty: the extensions are in `extensions` (top level), read once a validation exists; each extension a step `ext.<name>` (`properties.provisioningState`, start `systemData.createdAt`, end `systemData.lastModifiedAt` or `instanceView.status.time`, error `instanceView.status.message`) |

`provisioning.status` rolls the machines up: error if any, success when all, running when any running or done, else notstarted. Timestamps `0001-01-01T00:00:00Z` mean "not set" and the `MM/dd/yyyy HH:mm:ss` form some job steps use is read as UTC. The response shapes are the recorded live responses of the 10 Oct 2026 simplified provisioning run (`tests/fixtures`); the OEM image shapes follow the HybridCompute REST reference and are not yet checked live.

### State timeline (change-only, capped)

Every poll replaces the latest state (`/api/state`, SSE `state`). The timeline keeps a snapshot only when the state **changed**: `polledAt` and the running steps' `durationSeconds` are ignored, so a long deployment does not store thousands of identical snapshots. At most **5000** snapshots are kept; when the cap is reached the oldest snapshot is dropped and counted (`timelineDropped`). The latest state is held separately, so it is always in the export even when the timeline is full.

## Log tailer (read-only)

PowerShell remoting to the seed node (`New-PSSession -ComputerName <address> -Credential`), or SSH with Posh-SSH when WinRM is not reachable (`logs.transport`). Workgroup nodes (Local Identity) need the address in the workstation's WinRM `TrustedHosts`; Sonar checks and tells the user, never sets it. Arc run command and Arc SSH are not used: both write to Azure (research.md, S-3), which breaks read-only. If no session can be opened, the tailer reports `{ state: "unavailable", reason }` and retries every 60 s; the page shows the reason and the phase guidance.

Each poll runs one read-only script on the node (Windows PowerShell 5.1). The node keeps nothing between polls: the per-file state travels with the call.

- **Discovery cadence.** Listing the log folders (`Get-ChildItem -Recurse -Depth recurseDepth`) is the expensive part, so it runs on the first poll, then on every 3rd poll **or** when 60 s have passed since the last listing, whichever comes first, and on the next poll after a tracked file vanished or a session was re-opened. A listing keeps the files matching `include`/`exclude` that were written within `activeWindowMinutes`, newest first (at most 300). Between listings the script only re-checks the files that were active at the last listing (no enumeration); a new file is picked up at the next listing, and a log path that does not exist yet (`C:\CloudDeployment\Logs` appears mid-deployment) is reported in `missingPaths` and checked again at each listing.
- **Reading.** For each active file: keep a byte offset; read the new bytes since the offset with `FileShare.ReadWrite|Delete` (the writer and rotation are never blocked), split complete lines (an incomplete last line waits for the next poll), at most `maxLinesPerPoll` lines per poll and 1 MiB per file. UTF-8, UTF-16 LE/BE (BOM or zero-byte pattern) are detected. A file that already existed when Sonar started is read from 16 KiB before its end; a file that appears later is read from 0.
- **Rotation and re-creation.** Truncation (size < offset) or a new creation time resets the offset to 0. Each tracked file also remembers its first 64 bytes (`head`): when a known path's first bytes change, the file was re-created under the same name (NTFS tunnelling keeps the old creation time for 15 s) and is read again from 0. When a **new** path's creation time and first bytes match a file that just disappeared (or was just re-created), it is the same file renamed by rotation (`Deploy.log` → `Deploy.1.log`): its offset, encoding and state are carried over, so its lines are not sent twice (reported in `renamed`). Best effort: a rename is only recognised at a listing, against files gone since the previous one (a file that vanishes between listings is kept, inactive, until the next listing); a renamed copy of a file whose first bytes were never read, or whose creation time changed, is read from 0 again.
- **State cap.** At most 2000 files are tracked (offsets of files outside the active window are kept so they continue, not restart, if written again). Beyond that the least recently written entries are evicted, inactive before active (`stateEvicted`).
- **Node clock.** The script reports the node's current UTC offset (`utcOffsetMinutes`, from `[TimeZoneInfo]::Local`) so node-local timestamps can be converted.

Every line gets a level: `error` (`\b(error|exception|failed|fatal)\b`, case-insensitive), else `warning` (`\bwarn(ing)?\b`), else `info`. Zero-count summaries are removed before matching, so `error=0`, `Failed: 0`, `0 failed`, `warning count=0` and `errors: 0` are `info` (another problem word in the same line still counts).

Every line gets an **event time** (`Get-AzlSonarLogEventTime`):

1. a leading timestamp in the line (optional `[` or `(` first): ISO 8601 with or without fraction and `Z`/offset (`2026-10-10T16:16:42.123Z`, `2026-10-10T16:16:42+02:00`, `2026-10-10T16:16:42`), `yyyy-MM-dd HH:mm:ss(.fff)` (also `,fff`), `[yyyy-MM-dd HH:mm:ss]`, `MM/dd/yyyy HH:mm:ss` (also `h:mm:ss AM/PM`), and the PowerShell transcript header `Start time: yyyyMMddHHmmss`;
2. else the timestamp in the file name (`Name_20261010-161642.log`, `Name_20261010-234335Z.log`, `PowerShell_transcript.NODE.x.20261010161642.txt`);
3. else the receive time.

Times with `Z` or an offset are exact. Times without one are node-local and converted with the node's UTC offset (when the offset is unknown they are not used). A time more than a day after the receive time is ignored. The offset is the node's offset now, so a timestamp written on the other side of a daylight-saving change is off by that hour.

## Phase guidance (`data/phase-guidance.json`)

Per phase and identity model: which account reads the node logs, where the logs are, when they exist, and the source. Phases: `provisioning`, `arc-registration`, `validation`, `deployment`, `post-deployment`. Documented sources only; anything not confirmed in a lab is marked `"verified": false` (an `observed` note may say what was seen live short of confirming the entry).

## HTTP API (localhost only, `http://localhost:{port}/`)

| Route | Returns |
| --- | --- |
| `GET /` , `/app.js`, `/app.css` | the page |
| `GET /api/config` | config without secrets: cluster, resourceGroup, identityModel, provisioningRoute, nodes (name, seed), log paths, pollSeconds, `startedAt`, `serverId` |
| `GET /api/state` | latest `Get-AzlSonarDeploymentState` result |
| `GET /api/guidance` | phase guidance for the configured identity model |
| `GET /api/logs?since={seq}` | `{ server, lastSeq, tailer: {state, reason, node, activeFiles[], ...}, files[{path, size, offset, lastWriteUtc}], lines[] }` — lines with seq > since (ring buffer of the last 5000) |
| `GET /api/events` | Server-Sent Events, see below |
| `GET /api/export` | one JSON bundle, see below |

A log line is `{ seq, time, received, timeSource, file, level, text }`: `seq` counts from 1 for each back-end instance; `received` is when Sonar got the line (UTC); `time` is the event time (UTC, `yyyy-MM-ddTHH:mm:ss.fffZ`); `timeSource` says where it came from: `line` (the line's own timestamp), `file` (the file name) or `received` (no timestamp: `time` = `received`, approximate). `text` has secrets masked.

`server` is the back end's instance id (a new GUID at every start; also in `/api/config` as `serverId`). `lastSeq` is the last sequence number given out, read together with the lines: after an answer the page has every line up to `lastSeq` (or it fell out of the ring buffer) and uses it as its catch-up cursor.

**Server-Sent Events.** A stream starts with `retry: 5000` and `event: hello` (data `{ server, since }`: the instance id and the seq the stream continues after). Then `event: state` (data = state JSON) on every change, `event: tailer` (tailer status) on every change, `event: log` (data = `{ server, lines[] }`, at most 1000 lines per event) and `: ping` every 15 s. At most **10** streams are served at once; one more gets `503` with `Retry-After: 30` (the page polls meanwhile). The dispatch loop never waits for a client: each client has a bounded queue (4 MiB) and at most one asynchronous write in flight. A client whose write is still in flight gets nothing new that turn (state and tailer coalesce to the latest; log lines wait at its cursor). A client is dropped (connection aborted; the page reconnects and catches up through `/api/logs`) when a write fails or stays in flight longer than 15 s, when its queue would pass the limit, or when the lines it still needs have left the ring buffer.

**Export.** `{ export, config, guidance, state, timeline[], logs }`. `state` is the latest state; `timeline` is the change-only, capped list of state snapshots (see *State timeline*); `logs` is the `/api/logs?since=0` body (the ring buffer). `export` describes the bundle and both caps:

| Field | Meaning |
| --- | --- |
| `tool`, `version`, `server`, `exportedAt` | AzL Sonar, module version, back-end instance id, export time (UTC) |
| `snapshots` | snapshots in `timeline` |
| `timelineMode` | `change-only`: a snapshot is kept only when the state changed (polledAt and running durations ignored) |
| `timelineMax` | the snapshot cap (5000) |
| `timelineDropped` | oldest snapshots dropped because of the cap |
| `latestStateIncluded` | `true`: `state` holds the latest state whatever the cap did |
| `logRingSize` | the log ring buffer size (5000 lines) |
| `logLinesKept`, `logFirstSeq`, `logLastSeq` | lines in `logs.lines` and their seq range |
| `logLinesDropped` | lines that left the ring buffer before the export (`logLastSeq − logLinesKept`) |

The server binds `http://localhost:{port}/` only and answers loopback clients only. No route changes Azure or a node.

## Page

Header: cluster, phase chip (`Provisioning`, `Arc registration`, `Validation`, `Deployment`, `Done`, or `Failed: <phase>`), overall status, elapsed time, last poll, node chips (Arc status; the tooltip names the resolved Arc machine and where its name came from), theme toggle. Left, above the step tree: the **Provisioning** / **Arc registration** panel (S-8), shown while the state has machines: route pill, a *Machines* section (collapsible; collapsed once when validation or deployment starts) with one tree item per machine (lifecycle chip, progress bar with Sonar's percent, Arc machine, extension count on the simplified route, on the OEM image route the *OS image update* / *Bootstrap* step counters and *Rebooting / unreachable since*, lifecycle message, the machine's tree with live timers and errors inline; same keyboard and log-filter behaviour as the step tree). The overall status reads *Ready for Validate* when `provisioning.readyForValidate`. Then the step tree for validation, the *Extensions (installed during Validate)* group (OEM image route, once `extensions.shown`; one item per machine) and deployment (collapsible, status icon, duration, live timer on the running step, errors expanded inline; clicking a step filters the log pane to that step's time window). Right: live log pane (auto-scroll with pause, level filter, text search, file filter, error/warning highlight, count badges). Bottom/side: phase guidance card (account, log location, when available, node commands to check). Export button downloads `/api/export`. Accessible: keyboard navigation, focus visible, ARIA live region for status changes. Works at 1280 px and on a narrow window. Demo mode: `?demo=1` (a running deployment), `?demo=1&route=simplified`, `?demo=1&route=oem`.

**Log sequencing.** The page keeps lines in seq order and deduplicates by seq for one back-end instance. Catch-up (`/api/logs?since=`) and live (SSE `log`) batches are merged in seq order. The catch-up cursor is kept apart from the highest live seq: it moves with `/api/logs` answers (`lastSeq`), and with the live stream only once the stream's `hello.since` is at or before it, so a live line that arrives first never makes the page skip the lines in between. A back-end restart is detected by a new `server` id (log batches, `hello`) or a new `/api/config` `serverId`/`startedAt` (checked on every SSE reconnect and every fallback poll): the page drops what it holds and fetches `since=0`.

**Step filter.** A step's window is its start −1 s to its end +1 s (open-ended while it runs). A line with its own timestamp (`timeSource: line`) matches by event time; a line timed by its file name (`file`) matches by that time or by its receive time; a line with no timestamp (`received`) is approximate and matches only when Sonar received it inside the window (shown with `~` before its time). When the selected step's window changes (running → finished) the log pane is filtered again; when the step disappears from the state the filter is removed.

**File filter.** The options are the files the tailer reports now (`/api/logs` files, tailer `activeFiles`) plus the files of the lines the page still holds. The selection stays only while its file is still offered.
