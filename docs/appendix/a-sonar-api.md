# Appendix A: Sonar's API and commands

This appendix lists everything Sonar itself offers: the HTTP routes the running Sonar serves, the PowerShell commands the module exports, the configuration keys, the files it reads and writes, and what it reads from Azure and from the nodes. It is the reference to use when you want to script against Sonar, or want to know for certain what Sonar can and cannot touch.

Sonar is read-only by design. It never changes the cluster, the nodes or Azure. The only things it writes are local files you ask for (a config file, a recording, an export). [What Sonar can and cannot do](#what-sonar-can-and-cannot-do) shows where that is enforced.

[Appendix B](./b-configurator-app-api.md) covers a different interface: the one Microsoft's Configurator app uses to configure a machine.

## Evidence labels

Every item here says how we know. In this appendix the labels are:

| Label | Meaning |
| --- | --- |
| **From the source** | Read from Sonar's own code in this repository (`src/AzlSonar/`). The page is checked against that code by `tests/Appendix.Tests.ps1`. |
| **Verified live** | Called against a running Sonar in replay mode on the repository's sample recording (`tests/fixtures/recording-sample.jsonl`; example names only). The response shown is the real one. |
| **Tested** | Covered by a Pester test that is named. |

Live Sonar routes that need Azure (`/api/events`, `/api/export`) were not called for this page, because replay mode refuses them; their shape is from the source and the tests.

## Contents

- [HTTP routes](#http-routes)
  - [Rules that apply to every route](#rules-that-apply-to-every-route)
  - [GET / and the static files](#get-and-the-static-files)
  - [GET /api/config](#get-api-config)
  - [GET /api/state](#get-api-state)
  - [GET /api/guidance](#get-api-guidance)
  - [GET /api/logs](#get-api-logs)
  - [GET /api/events](#get-api-events)
  - [GET /api/export](#get-api-export)
  - [GET /api/replay](#get-api-replay)
  - [Health check](#health-check)
  - [Which routes the page uses](#which-routes-the-page-uses)
- [PowerShell commands](#powershell-commands)
  - [Start-AzlSonar.ps1](#start-azlsonarps1)
  - [Start-AzlSonarServer](#start-azlsonarserver)
  - [Configuration commands](#configuration-commands)
  - [State and guidance commands](#state-and-guidance-commands)
  - [Recording and report commands](#recording-and-report-commands)
  - [Helper scripts](#helper-scripts)
- [Configuration keys](#configuration-keys)
- [Environment variables and files](#environment-variables-and-files)
- [What Sonar can and cannot do](#what-sonar-can-and-cannot-do)
- [Keeping this page current](#keeping-this-page-current)

## HTTP routes

Sonar serves one local web server (`http://localhost:<Port>/`, default port 8642). There are **7 API routes** plus the static page. All are `GET`.

| Route | Live | Replay | Returns | Used by the page |
| --- | --- | --- | --- | --- |
| `GET /api/config` | yes | yes | The public config (no secrets) | yes |
| `GET /api/state` | yes | yes | The latest deployment state | yes |
| `GET /api/guidance` | yes | yes | Which account reads which logs, where and when | yes |
| `GET /api/logs?since=<seq>` | yes | yes | Log lines after a sequence number, plus tailer status | yes |
| `GET /api/events` | yes | 404 | Server-Sent Events stream | yes |
| `GET /api/export` | yes | 404 | One JSON file: config, timeline, latest state, logs | yes (Export button) |
| `GET /api/replay` | 404 | yes | The whole recording as events | yes (replay mode) |

Source: `Invoke-AzlSonarHttpRequest` in `src/AzlSonar/Private/Server.ps1`. **From the source.**

### Rules that apply to every route

- **Read-only.** Any method other than `GET` gets `405 Only GET is supported.` with `Allow: GET`. No route writes to Azure, a node or a file. Tested: `tests/Server.Tests.ps1` ("`<Method> /api/state is a 405 with Allow: GET`"). **Verified live**: a `POST` to `/api/state` returned `HTTP/1.1 405 Method Not Allowed`, `Allow: GET`.
- **This machine only.** The listener binds `http://localhost:<Port>/`, and the handler refuses any request whose remote address is not loopback with `403 AzL Sonar only answers requests from this machine.` There is no authentication, because nothing leaves the machine. Do not publish the port through a proxy or tunnel.
- **No caching.** API responses carry `Cache-Control: no-store`, `X-Content-Type-Options: nosniff` and `Referrer-Policy: no-referrer`.
- **Errors are JSON.** An unknown `/api/...` path is `404 {"error":"Unknown API route: /api/nope"}` (**Verified live**). A bad `since` is `400 {"error":"since must be a whole number."}` (**Verified live**). An internal failure is `500 {"error":"Internal error."}`.
- **Replay mode.** In replay mode `/api/events` and `/api/export` return `404 {"error":"Replay mode: /api/export is not available; the page plays /api/replay."}` (**Verified live**) and `/api/replay` is served. In live mode `/api/replay` returns `404 {"error":"Not replaying. Start Sonar with -Replay <recording> to play a recording."}`.
- **Secrets.** Secrets are masked in node text (`Shared.Redact`) and never serialized. Config secret names and node addresses are not in `/api/config` (see below).

<a id="get-and-the-static-files"></a>

### GET / and the static files

Serves `index.html` for `/`, and the files under `src/AzlSonar/web/` by name (`app.js`, `app.css`, `azurelocal-sonar-icon.svg`). Anything outside that folder is refused (a path-traversal guard, `Resolve-AzlSonarStaticPath`; tested in `tests/Server.Tests.ps1`). Content types are fixed by extension. Not an API route; listed for completeness. **Verified live**: `GET /` returned `200 text/html; charset=utf-8`.

<a id="get-api-config"></a>

### GET /api/config

**For:** the cluster name, route, nodes (names and seed flag only), log folders, poll interval, and when this Sonar instance started. The page reads it first and again after a connection loss: a changed `serverId` or `webVersion` means Sonar restarted and the page reloads itself.

**Query parameters:** none.

**Response:** JSON built by `ConvertTo-AzlSonarPublicConfig`. Fields: `clusterName`, `cluster`, `resourceGroup`, `identityModel`, `provisioningRoute`, `nodes[]` (`name`, `seed`), `logs.paths[]`, `pollSeconds`, `profile` (when the config sets a cluster pattern), `startedAt`, `serverId`, and in live mode `recording.file` and `webVersion`. It never carries the subscription ID, node addresses, credential settings or Key Vault names (tested in `tests/Server.Tests.ps1`, "secret" cases). In replay mode it also carries a `replay` object.

**Verified live** (replay of the sample recording):

```json
{"clusterName":"clus01","cluster":"clus01","resourceGroup":"rg-example-azl","identityModel":"LocalIdentity","provisioningRoute":"oem-image","nodes":[{"name":"node01","seed":true},{"name":"node02","seed":false}],"logs":{"paths":["C:\\CloudDeployment\\Logs"]},"pollSeconds":20,"startedAt":"2026-10-11T08:10:00Z","serverId":"f93fda188af6491c9683e131d22b8ba8","replay":{"cluster":"clus01","file":"recording-sample.jsonl","recordedFrom":"2026-10-11T08:00:00.000Z","recordedTo":"2026-10-11T09:06:00.000Z","sessions":2,"invalid":0,"speed":60.0,"startAt":"2026-10-11T08:00:00.000Z","startAtPhase":null,"autoplay":false}}
```

**Read-only:** yes.

```powershell
Invoke-RestMethod -Uri 'http://localhost:8642/api/config'
```

<a id="get-api-state"></a>

### GET /api/state

**For:** the latest normalised deployment state: phase, provisioning panel, validation and deployment step trees, per-node Arc status, warnings, and the time of the last poll. It is the same object the poller builds with `Get-AzlSonarDeploymentState`.

**Query parameters:** none.

**Response:** the state JSON. Top-level fields include `cluster`, `resourceGroup`, `mode`, `provisioningState`, `phase`, `activePhase`, `provisioning`, `extensions`, `validation`, `deployment`, `nodes[]`, `current`, `warnings[]`, `pollError`, `polledAt`. Step trees are made by `ConvertTo-AzlSonarStepTree`; each step is `{ id, name, description, status, rawStatus, start, end, durationSeconds, errors[], children[] }` and `status` is one of `notstarted`, `running`, `success`, `error`, `skipped`, `unknown`. Before the first poll finishes the value is the initial state, and `null` is possible only before startup completes.

**Verified live** (replay):

```json
{"cluster":"clus01","resourceGroup":"rg-example-azl","mode":null,"provisioningState":null,"phase":"arc-registration","activePhase":"arc-registration","provisioning":{"route":"oem-image","routeSource":"config","phase":"arc-registration","status":"running","readyForValidate":false,"nodes":[{"name":"node01","status":"running","start":"2026-10-11T07:50:00Z","lifecycle":"Bootstrapping"},{"name":"node02","status":"running","start":"2026-10-11T07:51:00Z","lifecycle":"Bootstrapping"}]},"extensions":{"shown":false,"status":"notstarted","nodes":[]},"validation":{"status":"notstarted","tree":[],"counts":{}},"deployment":{"status":"notstarted","tree":[],"counts":{}},"nodes":[{"name":"node01","arcStatus":"Connected"},{"name":"node02","arcStatus":"Connected"}],"current":{"phase":"arc-registration","stepPath":[],"stepName":null},"warnings":[],"pollError":null,"polledAt":"2026-10-11T08:00:01Z"}
```

**Read-only:** yes.

```powershell
(Invoke-RestMethod -Uri 'http://localhost:8642/api/state').phase
```

<a id="get-api-guidance"></a>

### GET /api/guidance

**For:** which account reads which logs in each phase, where the logs are and when they appear, for the configured identity model. Drives the page's "Log access" card. The data comes from `src/AzlSonar/data/phase-guidance.json` through `Get-AzlSonarPhaseGuidance`.

**Query parameters:** none.

**Response:** `{ identityModel, available, version, phases: { <phase>: { account, logPaths[], when, how, timing, commands[], verified, source } } }`. `available` is `false` (and `phases` empty) when the data file is missing.

**Verified live** (replay of the sample recording; the recording carries a short guidance object):

```json
{"available":true,"identityModel":"LocalIdentity","phases":{"validation":{"account":"The deployment local admin","where":["C:\\CloudDeployment\\Logs"]},"deployment":{"account":"The deployment local admin","where":["C:\\CloudDeployment\\Logs"]}}}
```

**Read-only:** yes.

<a id="get-api-logs"></a>

### GET /api/logs

**For:** the log lines Sonar has kept in its in-memory ring buffer (default 5000 lines), plus the log tailer's status. The page uses it to catch up after a reconnect or when streaming is unavailable.

**Query parameters:**

| Parameter | Type | Required | Default | Meaning |
| --- | --- | --- | --- | --- |
| `since` | integer (whole number) | no | `0` | Return lines with `seq` greater than this. Not a whole number: `400`. |

**Response:** `{ server, lastSeq, tailer, files[], lines[] }`. `server` is this Sonar instance's id (new on every start). `lastSeq` is the last sequence number given out when the lines were read, the page's catch-up cursor. `tailer` is the tailer status object (`state`, `reason`, `node`, `activeFiles[]`, and `transport`, `computer` when connected), `files` the files being followed, `lines[]` the lines, each `{ seq, time, received, timeSource, file, level, text }` with `level` one of `info`, `warning`, `error`.

**Verified live** (replay, which has no tailer): `{"server":"f93fda188af6491c9683e131d22b8ba8","lastSeq":0,"tailer":null,"files":[],"lines":[]}`. A line, from the sample recording:

```json
{"seq":1,"time":"2026-10-11T08:00:01.000Z","received":"2026-10-11T08:00:01.000Z","timeSource":"received","file":"C:\\Windows\\System32\\Bootstrap\\Logs\\setup.log","level":"info","text":"Bootstrap started on node01."}
```

**Read-only:** yes.

```powershell
(Invoke-RestMethod -Uri 'http://localhost:8642/api/logs?since=0').lines | Select-Object -Last 5
```

<a id="get-api-events"></a>

### GET /api/events

**For:** a live push stream (Server-Sent Events, `text/event-stream`), so the page updates without polling. Live mode only (404 in replay). If the stream cannot be used the page falls back to polling `/api/state` and `/api/logs` every 5 seconds.

**Query parameters:** none.

**Stream format** (**From the source**: `Open-AzlSonarSseClient`, `Send-AzlSonarSseUpdate`):

```text
retry: 5000

event: hello
data: {"server":"f93fda188af6491c9683e131d22b8ba8","since":0}

event: state
data: { ...the /api/state object... }

event: tailer
data: { ...the tailer object... }

event: log
data: {"server":"f93fda188af6491c9683e131d22b8ba8","lines":[ ...up to 1000 lines... ]}

: ping
```

| Event | When | Data |
| --- | --- | --- |
| `hello` | Once, on connect | `{ server, since }`: the instance id and the log sequence the stream continues from |
| `state` | When the state changed (coalesced to the latest) | The `/api/state` object |
| `tailer` | When the tailer status changed | The tailer object |
| `log` | When there are new log lines | `{ server, lines[] }`, at most 1000 lines per event |
| comment `: ping` | Every 15 seconds | None (keeps the connection alive) |

**Limits:** at most **10** streams at once; the eleventh gets `503` with `Retry-After: 30` (the page polls meanwhile). A client is dropped when a write fails or stays in flight over 15 seconds, when more than 4 MiB is queued for it, or when the log lines it still needs have left the ring buffer. The page reconnects and catches up through `/api/logs`.

**Read-only:** yes.

```powershell
# Prints the raw stream until you press Ctrl+C.
curl.exe -N http://localhost:8642/api/events
```

<a id="get-api-export"></a>

### GET /api/export

**For:** the **Export** button: one JSON file with everything the page holds, to attach to a support case or keep as a record. Live mode only (404 in replay; a recording is the replay-mode record).

**Query parameters:** none. The response has `Content-Disposition: attachment; filename="azlsonar-<cluster>-<UTC yyyyMMdd-HHmmss>.json"`.

**Response:** `{ export, config, guidance, state, timeline[], logs }`.

- `export` is metadata: `tool`, `version`, `server`, `exportedAt`, `snapshots`, `timelineMode` (`change-only`), `timelineMax` (5000), `timelineDropped`, `latestStateIncluded`, `logRingSize`, `logLinesKept`, `logFirstSeq`, `logLastSeq`, `logLinesDropped`.
- `config` is the same public config as `/api/config` (no secrets).
- `timeline[]` is the state snapshots kept only when the state changed, oldest dropped first past the cap.
- `logs` is the `/api/logs?since=0` object.

An export made without `-Publishable` still holds the cluster's identifiers. **From the source** (`Get-AzlSonarExportJson`), **Tested** in `tests/Server.Tests.ps1` (export contents and the secret checks).

**Read-only:** yes.

```powershell
Invoke-RestMethod -Uri 'http://localhost:8642/api/export' | ConvertTo-Json -Depth 50 | Set-Content ./sonar-export.json
```

<a id="get-api-replay"></a>

### GET /api/replay

**For:** replay mode only. Returns the whole recording so the page can rebuild state at any point. In live mode it is `404`.

**Query parameters:** none.

**Response:** `{ replay, events[] }`. `replay` is the metadata (`cluster`, `file`, `recordedFrom`, `recordedTo`, `sessions`, `invalid`, `speed`, `startAt`, `startAtPhase`, `autoplay`). `events[]` are the recording lines: `{ t, k, ... }` where `k` is `session`, `state`, `tailer`, `log` or `end`. The format is described in [the event feed reference](../reference/events.md).

**Verified live** (sample recording): 26 events, first three of kinds `session`, `state`, `tailer`, last `{"t":"2026-10-11T09:06:00Z","k":"end"}`.

**Read-only:** yes.

### Health check

There is **no dedicated health route**. To check that Sonar is up, request `GET /api/config`: a `200` with a `serverId` and `startedAt` means the listener is serving. The poller and tailer can be unhealthy while the listener is fine; their problems show in `/api/state` (`pollError`, `warnings`) and `/api/logs` (`tailer.state`, `tailer.reason`). A worker that stops unexpectedly is reported on the console as a warning (checked every 5 seconds). **From the source.**

### Which routes the page uses

`src/AzlSonar/web/app.js` calls `/api/config`, `/api/guidance`, `/api/state`, `/api/logs`, `/api/events`, `/api/export` (live) and `/api/replay` (replay). Every route in this appendix is used by the page. Nothing else on the server is reachable from the page.

## PowerShell commands

The module exports **14 functions** (the manifest, `src/AzlSonar/AzlSonar.psd1`, `FunctionsToExport`; no cmdlets, aliases or variables), and the repository ships **3 scripts**. Import the module with:

```powershell
Import-Module ./src/AzlSonar/AzlSonar.psd1
Get-Command -Module AzlSonar
```

Requires PowerShell 7.4 or later. Parameter lists below come from `Get-Help` and the parameter attributes (**From the source**). "What it changes" says what is written; nothing here changes the cluster, a node or Azure.

### Start-AzlSonar.ps1

The normal way to start Sonar. Imports the module, builds the configuration, checks the Az sign-in, starts the web server, and opens the browser. Runs until Ctrl+C. With neither `-InfrastructureFile` nor `-ConfigPath` it looks for `./sonar.config.json` or `./config/sonar.config.json`; if there is none it explains the options and offers the guided setup.

| Parameter | Type | Required | Default | Set | Meaning |
| --- | --- | --- | --- | --- | --- |
| `-InfrastructureFile` | string | no | | Live | Path to the master `infrastructure.yml` (schema 5). Cannot be combined with `-ConfigPath`. |
| `-ConfigPath` | string | no | | Live | Path to a Sonar config file (JSON). |
| `-PollSeconds` | int, 5 to 3600 | no | config value, else 20 | Live | Seconds between Azure polls. |
| `-Replay` | string | yes (Replay set) | | Replay | Recording to play (`.jsonl` or `.jsonl.gz`). No Azure sign-in, no node access. |
| `-Port` | int, 1 to 65535 | no | `8642` | both | Local port. |
| `-NoBrowser` | switch | no | off | both | Do not open the browser. |
| `-Credential` | pscredential | no | | Live | Account that reads the logs on the seed node. Overrides `credential.source`. |
| `-Record` | string | no | | Live | Append the run to this recording file (JSON Lines). Overrides `recordPath`. |
| `-Publishable` | switch | no | off | Live | With `-Record`: replace every identifier with a stable pseudonym. Needs a new file. |
| `-ExtraTerm` | string[] | no | | Live | With `-Publishable`: extra strings that must never appear. |
| `-Speed` | double, 0.1 to 3600 | no | `60` | Replay | Starting replay speed (recorded seconds per real second). |
| `-StartAt` | string | no | | Replay | Where to start: an offset (`1:42:10`, `90m`, `1h30m`), a UTC time in the recording, or a phase (`arc-registration`, `validation`, `deployment`). |
| `-Autoplay` | switch | no | off | Replay | Start playing at once instead of paused. |

```powershell
Connect-AzAccount
./Start-AzlSonar.ps1 -ConfigPath ./config/clus01.json -Record ./recordings/clus01.jsonl
./Start-AzlSonar.ps1 -Replay ./recordings/clus01.jsonl -Speed 240 -StartAt deployment
```

**What it changes:** nothing outside the process, except a recording file when you give `-Record`. **Needs:** `Connect-AzAccount` for a live run.

### Start-AzlSonarServer

The function behind the script. It has the same parameters as `Start-AzlSonar.ps1` minus the guided setup, and `-Port` and `-NoBrowser` apply to both sets. Use the script for normal work; call the function when you want to embed Sonar.

```powershell
Start-AzlSonarServer -Replay ./recordings/clus01.jsonl -Speed 240 -StartAt deployment -NoBrowser
```

**What it changes:** as the script. Throws if the port is in use or if both `-ConfigPath` and `-InfrastructureFile` are given.

### Configuration commands

#### New-AzlSonarConfig

Creates a Sonar config file (JSON) from the values you give, or asks for each value with `-Interactive`. The file starts with no nodes; add them with `Add-AzlSonarNode`. It never asks for or stores a password (`credential.source` is `prompt`). Supports `-WhatIf` and `-Confirm`.

| Parameter | Type | Required | Default | Meaning |
| --- | --- | --- | --- | --- |
| `-Path` | string | yes | | Where to write the file, for example `./config/clus01.json`. |
| `-SubscriptionId` | string | no | | The subscription GUID. |
| `-ResourceGroup` | string | no | | The cluster's resource group. |
| `-ClusterName` | string | no | | The cluster name. |
| `-Route` | `auto`, `simplified`, `oem-image` | no | `auto` | Provisioning route. |
| `-IdentityModel` | `LocalIdentity`, `ActiveDirectory` | no | | Identity model. |
| `-ZtpEventsPath` | string | no | | The `ztp-events.jsonl` file azurelocal-ztp writes (simplified route). |
| `-PollSeconds` | int, 5 to 3600 | no | | Poll interval. |
| `-Interactive` | switch | no | off | Ask for each value; a signed-in Az context pre-fills the subscription and resource group. |
| `-Force` | switch | no | off | Replace an existing file. Without it an existing file is an error. |

```powershell
New-AzlSonarConfig -Path ./config/clus01.json -SubscriptionId '00000000-0000-0000-0000-000000000000' `
    -ResourceGroup rg-example-azl -ClusterName clus01 -Route simplified -IdentityModel LocalIdentity
```

**What it changes:** writes one JSON file (and its folder). Returns the `FileInfo`.

#### Add-AzlSonarNode

Adds a node to a config file. `-Seed` makes it the seed node (the one whose logs are read) and clears the mark on the old one. Rewrites the file as plain JSON, so comments in a hand-commented file are lost.

| Parameter | Type | Required | Default | Meaning |
| --- | --- | --- | --- | --- |
| `-Path` | string | yes | | The config file. |
| `-Name` | string | yes | | Node name (unique). |
| `-Address` | string | yes | | Host name or IP address Sonar connects to. |
| `-ArcMachineName` | string | no | resolved | The Arc machine to follow, when it is not the node name. |
| `-Seed` | switch | no | off | Make this the seed node. |

```powershell
Add-AzlSonarNode -Path ./config/clus01.json -Name node01 -Address 192.0.2.11 -Seed
Add-AzlSonarNode -Path ./config/clus01.json -Name node02 -Address 192.0.2.12
```

**What it changes:** rewrites the config file.

#### Remove-AzlSonarNode

Removes a node from a config file. When the seed node is removed, the first remaining node becomes the seed.

| Parameter | Type | Required | Meaning |
| --- | --- | --- | --- |
| `-Path` | string | yes | The config file. |
| `-Name` | string | yes | The node to remove. |

```powershell
Remove-AzlSonarNode -Path ./config/clus01.json -Name node02
```

**What it changes:** rewrites the config file.

#### Get-AzlSonarConfig

Returns the configuration Sonar would run with, from a config file or from the master `infrastructure.yml`. Defaults applied, nodes normalised, seed marked.

| Parameter | Type | Required | Set | Meaning |
| --- | --- | --- | --- | --- |
| `-Path` | string | yes (position 0) | Path | A Sonar config file. |
| `-InfrastructureFile` | string | yes | InfrastructureFile | The master `infrastructure.yml`. |

```powershell
Get-AzlSonarConfig -InfrastructureFile ./infrastructure.yml | Select-Object -ExpandProperty nodes
```

**What it changes:** nothing (read-only). Throws one error listing every problem when the config is invalid.

#### Test-AzlSonarConfig

Validates a config and returns the list of problems; **empty when valid**. A pure check: no Azure or node access.

| Parameter | Type | Required | Set | Meaning |
| --- | --- | --- | --- | --- |
| `-Config` | object | yes | Config | A parsed config object. |
| `-Path` | string | yes | Path | A config file. |
| `-InfrastructureFile` | string | yes | InfrastructureFile | The master file. |

```powershell
Test-AzlSonarConfig -Path ./config/clus01.json
```

**What it changes:** nothing.

#### Read-AzlSonarConfig

Reads, validates and normalises a config. This is the single entry every other way of configuring Sonar ends in. Applies the documented defaults; never reads secrets (Key Vault secret names stay names). Throws one error listing every problem.

| Parameter | Type | Required | Set | Meaning |
| --- | --- | --- | --- | --- |
| `-Path` | string | yes | Path | A config file. |
| `-Json` | string | yes | Json | The config as a JSON string (useful in tests). |
| `-InfrastructureFile` | string | yes | InfrastructureFile | The master `infrastructure.yml`. |
| `-PollSeconds` | nullable int | no | all | Overrides `pollSeconds`. |

```powershell
$config = Read-AzlSonarConfig -Path ./config/clus01.json
```

**What it changes:** nothing.

#### ConvertTo-AzlSonarConfig

Generates a Sonar config file once from the master `infrastructure.yml` (schema 5), with the same mapping as `-InfrastructureFile`. The file says `credential.source` is `prompt`; secrets are never read. Supports `-WhatIf` and `-Confirm`.

| Parameter | Type | Required | Default | Meaning |
| --- | --- | --- | --- | --- |
| `-InfrastructureFile` | string | yes | | The master file. |
| `-OutFile` | string | yes | | Where to write the config. |
| `-PollSeconds` | int, 5 to 3600 | no | | Poll interval to write. |
| `-Force` | switch | no | off | Replace an existing file. |

```powershell
ConvertTo-AzlSonarConfig -InfrastructureFile ./infrastructure.yml -OutFile ./config/clus01.json -Force
```

**What it changes:** writes one JSON file.

### State and guidance commands

#### Get-AzlSonarDeploymentState

Reads the deployment state of an Azure Local instance from Azure and normalises it. It makes **read-only ARM `GET`s** through the signed-in Az context (listed in [What Sonar can and cannot do](#what-sonar-can-and-cannot-do)). A 404 on `deploymentSettings` is not an error: the machines are still being prepared. The phase is `deployment` over `validation` over `provisioning` (simplified) or `arc-registration` (OEM image).

| Parameter | Type | Required | Set | Meaning |
| --- | --- | --- | --- | --- |
| `-Config` | object | yes | Config | A config from `Read-AzlSonarConfig`. |
| `-ConfigPath` | string | yes | Path | A config file (read with `Read-AzlSonarConfig`). |
| `-Now` | datetime | no | now | The poll time (UTC), for `polledAt` and running-step durations. |
| `-NodeProbe` | IDictionary | no | | OEM route: the node probe records by node name. |
| `-ZtpStages` | IDictionary | no | | Simplified route: the Device and Network events per node. |
| `-Secret` | string[] | no | | Exact secret values to mask in node text. |
| `-LogHint` | IDictionary | no | | What the newest node log lines say, to label an Azure state that lags the node. |

```powershell
Connect-AzAccount
Get-AzlSonarDeploymentState -ConfigPath ./config/clus01.json | ConvertTo-Json -Depth 20
```

**What it changes:** nothing. **Needs:** a signed-in Az context with read access.

#### ConvertTo-AzlSonarStepTree

Converts an Azure Local status object (`{ status, steps[] }`) into the normalised step tree used by `/api/state`. Works for `deploymentSettings` `validationStatus` and `deploymentStatus` and for edge-machine `ProvisionOs` job status. An empty object or `$null` returns an empty tree.

| Parameter | Type | Required | Meaning |
| --- | --- | --- | --- |
| `-StatusObject` | object | no | The status object (or an array of raw steps). |
| `-Now` | datetime | no | Time for running-step durations (UTC); default now. |
| `-ParentId` | string | no | Prefix for generated ids when a step has no `fullStepIndex`. |

```powershell
ConvertTo-AzlSonarStepTree -StatusObject $settings.properties.reportedProperties.validationStatus
```

**What it changes:** nothing (pure).

#### Get-AzlSonarPhaseGuidance

Returns the phase guidance (which account reads which logs, where, when, how) for an identity model, from `data/phase-guidance.json`. This is what `/api/guidance` serves. A missing file returns `available = $false` rather than failing.

| Parameter | Type | Required | Default | Meaning |
| --- | --- | --- | --- | --- |
| `-IdentityModel` | `LocalIdentity`, `ActiveDirectory` | yes | | The identity model. |
| `-Phase` | string | no | all | One of `provisioning`, `arc-registration`, `validation`, `deployment`, `post-deployment`, `update`, `add-node`, `repair`. |
| `-Path` | string | no | module's file | A guidance file other than the module's. |

```powershell
(Get-AzlSonarPhaseGuidance -IdentityModel LocalIdentity).phases.deployment.account
```

**What it changes:** nothing.

### Recording and report commands

A recording is the JSON Lines file Sonar appends while it runs (`-Record`). These commands work on finished recordings. Recordings made without `-Publishable` still hold the cluster's identifiers.

#### Export-AzlSonarPublishableRecording

Rewrites a recording into a publishable one: every identifier (GUIDs, IP and MAC addresses, host and domain names, subscription, resource group, cluster and node names, user names) replaced by a stable pseudonym, then verified. If anything still matches, or the file exceeds `-MaxBytes`, nothing is left at the destination and the function throws (counts per category, never the values). The source file is never changed.

| Parameter | Type | Required | Default | Meaning |
| --- | --- | --- | --- | --- |
| `-Path` | string | yes | | The recording (`.jsonl` or `.jsonl.gz`). |
| `-Destination` | string | yes | | The new file (gzip when it ends in `.gz`). |
| `-ExtraTerm` | string[] | no | | Extra strings that must not survive. |
| `-MaxLogTextLength` | int, 0 to 10000000 | no | | Cut log lines longer than this (0 keeps them whole). |
| `-MaxInfoLinesPerEvent` | int, 0 to 100000 | no | | Keep at most this many info lines per log event (0 all); warnings and errors are always kept. |
| `-MaxIdleSeconds` | double, 0 to 86400 | no | | Close gaps longer than this (0 keeps them). |
| `-MaxBytes` | long | no | | Refuse a destination larger than this (0 no limit). |
| `-Force` | switch | no | off | Replace an existing destination. |

```powershell
Export-AzlSonarPublishableRecording -Path ./recordings/clus01.jsonl -Destination ./recordings/clus01.shareable.jsonl.gz `
    -ExtraTerm 'Example Corp' -MaxIdleSeconds 30
```

**What it changes:** writes the destination file.

#### Test-AzlSonarPublishableRecording

Scans a recording with the identifier detectors and returns the number of surviving original identifiers per category. All zero means nothing a detector knows is left. Returns an object with `Path`, `Lines`, `ByCategory`, `Total` and `Clean`.

| Parameter | Type | Required | Meaning |
| --- | --- | --- | --- |
| `-Path` | string | yes | The recording. |
| `-ExtraTerm` | string[] | no | Strings that must not appear (case-insensitive). |
| `-State` | object | no | Detector state, for repeated scans. |

```powershell
(Test-AzlSonarPublishableRecording -Path ./recordings/clus01.shareable.jsonl.gz).Clean
```

**What it changes:** nothing.

#### Export-AzlSonarBundle

Writes the export bundle of a recording: `<name>-timeline.json` and `<name>-report.html` in `-OutDirectory`. The timeline holds the phases with start, end and duration, every step with status, times, duration and errors, the errors on their own, and the warning and error log lines. The report is plain HTML with inline CSS. Returns an object with `Timeline` and `Report` paths.

| Parameter | Type | Required | Default | Meaning |
| --- | --- | --- | --- | --- |
| `-Recording` | string | yes | | A recording (`.jsonl` or `.jsonl.gz`). |
| `-OutDirectory` | string | yes | | Where to write the two files (created when missing). |
| `-Name` | string | no | recording name | File name prefix. |
| `-MaxLogLines` | int, 0 to 100000 | no | `300` | Warning and error log lines kept (the first ones of the run). |

```powershell
Export-AzlSonarBundle -Recording ./recordings/clus01.shareable.jsonl.gz -OutDirectory ./bundle -Name clus01
```

**What it changes:** writes the two files. A bundle from an unprotected recording holds identifiers; share it only after the recording passed `Test-AzlSonarPublishableRecording`.

### Helper scripts

| Script | Parameters | What it does |
| --- | --- | --- |
| `scripts/Export-SonarBundle.ps1` | `-Recording` (position 0, required), `-OutDirectory` (position 1, required), `-Name`, `-MaxLogLines` (0 to 100000, default 300) | Calls `Export-AzlSonarBundle` and prints the two paths. |
| `scripts/Protect-Recording.ps1` | `-Path` (position 0, required), `-Destination` (position 1, required in the Protect set), `-ExtraTerm`, `-MaxLogTextLength` (default 2000), `-MaxInfoLinesPerEvent`, `-MaxIdleSeconds`, `-MaxBytes`, `-Force`, `-VerifyOnly` | Pseudonymises a recording (`Export-AzlSonarPublishableRecording`), or with `-VerifyOnly` scans one (`Test-AzlSonarPublishableRecording`) and prints counts, never values. |
| `scripts/Test-MarkdownLinks.ps1` | `-Root` | Development tool: checks every relative Markdown link in the repository. |

Run `Get-Help ./scripts/Protect-Recording.ps1 -Full` for the full text of each parameter.

## Configuration keys

One table, abbreviated. [Configuration](../config.md) is the authority: it has the examples, the defaults' reasons, what each key changes on the page, and the `infrastructure.yml` mapping. Types are JSON types. Unknown keys are ignored. `credential.password`, `.secret` and `.secretValue` are refused.

| Key | Type | Required | Default |
| --- | --- | --- | --- |
| `subscriptionId` | string (GUID) | yes | |
| `resourceGroup` | string | yes | |
| `clusterName` | string | yes | |
| `identityModel` | `LocalIdentity` or `ActiveDirectory` | yes | |
| `provisioningRoute` | `auto`, `simplified`, `oem-image` | no | `auto` |
| `pollSeconds` | integer 5 to 3600 | no | `20` |
| `nodes[]` | list (one or more) | yes | |
| `nodes[].name` | string, unique | yes | |
| `nodes[].address` | string | yes | |
| `nodes[].arcMachineName` | string | no | resolved |
| `nodes[].seed` | boolean | no | first node |
| `ztpEvents.path` | string | no | none |
| `recordPath` | string | no | none |
| `credential.source` | `prompt`, `parameter`, `keyvault` | no | `prompt` |
| `credential.vault`, `.usernameSecret`, `.passwordSecret` | string | with `keyvault` | |
| `logs.paths` | list of strings | no | five standard folders |
| `logs.include` / `logs.exclude` | list of patterns | no | `*.log`, `*.txt`, `*.xml` / `*.etl` |
| `logs.recurseDepth` | integer 0 to 10 | no | `3` |
| `logs.activeWindowMinutes` | integer 1 to 10080 | no | `30` |
| `logs.maxLinesPerPoll` | integer 1 to 10000 | no | `500` |
| `logs.pollSeconds` | integer 1 to 3600 | no | `pollSeconds` |
| `logs.transport` | `auto`, `winrm`, `ssh` | no | `auto` |
| `clusterPattern` | `Standard`, `RackAware` | no | `Standard` |
| `architecture` | `hyperconverged`, `disaggregated` | no | `hyperconverged` |
| `track` | `auto`, `deployment`, `update`, `add-node`, `repair` | no | `auto` |
| `updateTrack` | `auto`, `off` | no | `auto` |
| `apiVersion`, `apiVersionFallback`, `edgeApiVersion` | string `yyyy-mm-dd` | no | `2026-10-01`, `2025-10-01`, `2026-10-01` |

The five default log folders are `C:\CloudContent\MASLogs`, `C:\MASLogs`, `C:\CloudDeployment\Logs`, `C:\Observability` and `C:\Windows\System32\Bootstrap\Logs` (**From the source**, `Config.ps1`).

## Environment variables and files

**Environment variables:** Sonar reads **none**. (`$env:COMPUTERNAME` appears only inside the scripts that run on a node, to label the result.) Everything is a parameter or a config key.

**Files Sonar reads:**

| File | When | Notes |
| --- | --- | --- |
| The config file (`-ConfigPath`) | At start | JSON with comments allowed. With no argument Sonar looks for `./sonar.config.json`, then `./config/sonar.config.json`. |
| The master `infrastructure.yml` (`-InfrastructureFile`) | At start, then its modification time every 60 seconds | Read with Sonar's own YAML reader. A changed node set only logs a notice: restart Sonar to track it. |
| `src/AzlSonar/data/phase-guidance.json` | At start | The account-and-log-folder guidance. |
| The ZTP event file (`ztpEvents.path`, or `provisioning.simplified.evidence_path` + `ztp-events.jsonl`) | Every 2 seconds while running | JSON Lines written by azurelocal-ztp. Local, read-only. See [What the ZTP event file gives Sonar](#what-the-ztp-event-file-gives-sonar). |
| A recording (`-Replay`, `Export-*`, `Test-*`) | On request | `.jsonl` or `.jsonl.gz`. |
| `WSMan:\localhost\Client\TrustedHosts` (or the WinRM client policy key) | At start, live mode | **Read** to tell you whether the seed node's address is trusted. Sonar never sets it. |

**Files Sonar writes** (only when you ask):

| File | Written by | Notes |
| --- | --- | --- |
| A config file | `New-AzlSonarConfig`, `Add-AzlSonarNode`, `Remove-AzlSonarNode`, `ConvertTo-AzlSonarConfig` | Plain JSON. |
| A recording | `-Record` / `recordPath` | JSON Lines, appended (created if missing; appended to after a restart). Secrets masked; identifiers kept unless `-Publishable`. A line cut off when Sonar stopped is skipped on replay. |
| A publishable recording | `Export-AzlSonarPublishableRecording`, `-Publishable` | Pseudonymised, verified. A failed check renames it `.NOT-PUBLISHABLE`. |
| A bundle | `Export-AzlSonarBundle` | `<name>-timeline.json` and `<name>-report.html`. |
| An export download | The page's Export button (`/api/export`) | Saved by the browser. |

**Logs:** Sonar writes **no log file of its own**. Its messages go to the PowerShell streams (information, warning, verbose) of the window it runs in; run with `-Verbose` for more. The log lines Sonar shows come from the nodes and are held in memory (ring buffer, 5000 lines by default), not written to disk unless you record.

## What Sonar can and cannot do

**It never changes the cluster, the nodes or Azure.** Where this is enforced:

- The web server answers `GET` only (`405` otherwise) and only from this machine (`403` otherwise): `Invoke-AzlSonarHttpRequest`. Tested in `tests/Server.Tests.ps1`.
- Azure access is a single function, `Invoke-AzlSonarArmGet`, which calls `Invoke-AzRestMethod -Method GET`. There is no other Azure call site in the module (the other Az commands are the local sign-in checks and, if you choose it, the Key Vault read below).
- The node scripts only read (file listing and tailing for logs, two status cmdlets for the node probe).
- Stopping Sonar changes nothing.

**What it does write:** local files you ask for (above).

**Two things that are reads but need care:**

- With `credential.source` `keyvault`, Sonar **reads two secrets** (`Get-AzKeyVaultSecret`: the log account's user name and password) from the vault you name. It holds the password in memory only and masks it in node text. Names only are stored in the config.
- It connects to the seed node (and, on the OEM route, every node) **as the log account you give**, and runs read-only scripts there. That account needs read access to the log folders.

### What it reads from Azure

All are ARM `GET`s through your signed-in Az PowerShell context (`Invoke-AzRestMethod`), **From the source** (`AzurePoller.ps1`, `LiveTracks.ps1`). `{rg}` is `/subscriptions/{subscriptionId}/resourceGroups/{resourceGroup}`.

| Resource | Path (after `{rg}` unless it starts with a full ID) | API version | Used for |
| --- | --- | --- | --- |
| Cluster deployment settings | `/providers/Microsoft.AzureStackHCI/clusters/{cluster}/deploymentSettings/default` | `apiVersion` (default `2026-10-01`; `apiVersionFallback` `2025-10-01` tried once on `InvalidApiVersionParameter`/`NoRegisteredProviderFound`) | Validation and deployment step trees, mode, provisioning state |
| Edge machines | `/providers/Microsoft.AzureStackHCI/edgeMachines` | `edgeApiVersion` (default `2026-10-01`) | Simplified provisioning: machines, lifecycle, Arc machine ID (skipped when the route is `oem-image`) |
| ProvisionOs job | `{edgeMachineId}/jobs/ProvisionOs` | `edgeApiVersion` | The OS-install step tree and job status |
| Arc machine | `/providers/Microsoft.HybridCompute/machines/{name}` | `2026-07-15` | Arc status, last status change, agent version, registration time |
| Arc machine extensions | `{arcMachineId}/extensions` | `2026-07-15` | The four mandatory extensions (`AzureEdgeDeviceManagement`, `AzureEdgeLifecycleManager`, `AzureEdgeRemoteSupport`, `AzureEdgeTelemetryAndDiagnostics`); read once a validation or deployment exists |
| Running ARM deployments | `/providers/Microsoft.Resources/deployments/?$filter=provisioningState eq 'Running'` | `2021-04-01` | Which deployment is running now (live tracks) |
| Update summary | `/providers/Microsoft.AzureStackHCI/clusters/{cluster}/updateSummaries/default` | `apiVersion` | Update track (skipped when `updateTrack` is `off`) |
| Updates | `/providers/Microsoft.AzureStackHCI/clusters/{cluster}/updates` | `apiVersion` | Update track |
| Update runs | `/providers/Microsoft.AzureStackHCI/clusters/{cluster}/updates/{name}/updateRuns` | `apiVersion` | Update track steps |

Only Arc machine IDs that match `/subscriptions/{s}/resourceGroups/{rg}/providers/Microsoft.HybridCompute/machines/{name}` are followed. Sonar also calls `Get-AzContext` (and, in the guided setup, `Get-AzSubscription` and `Get-AzDefault`) locally to check the sign-in and pre-fill answers. The sign-in needs read access to these resources only.

### What it reads from the nodes

| What | How | Where |
| --- | --- | --- |
| Deployment logs, on the **seed node** | A read-only script per poll over PowerShell remoting (WinRM), or over SSH (Posh-SSH) when WinRM is blocked; `logs.transport` chooses (`auto` tries WinRM then SSH). Lists the folders every third poll, tails growing files. | The `logs.paths` folders (defaults above), files matching `logs.include` and not `logs.exclude`, written within `logs.activeWindowMinutes`, to `logs.recurseDepth` levels. |
| Arc bootstrap and zero-day update status, on **each node**, OEM image route only | `Get-ArcBootstrapStatus` and `Get-ArcZeroDaySolutionUpdateStatus` with `-ErrorAction SilentlyContinue`, over the same transports, only while Arc registration runs. | Not run on the `simplified` route. |
| WinRM client trust, on **this workstation** | Reads `TrustedHosts`; reports, never sets. | Local registry/WSMan. |

### What the ZTP event file gives Sonar

When `ztpEvents.path` is set, Sonar follows that local JSON Lines file (every 2 seconds). Each line is one event: `{ timestamp, node, state, evidence, nextAction, level, stage }`. Sonar shows each as a log line (`[ztp]`), and turns the per-node `Device`, `Network` and `Restore` stages into steps of each machine. Lines that are not JSON objects with `node` and `state` are skipped (a half-written line is retried next poll). Events such as `Mounted`, `MaintenanceEnvironmentRunning`, `VoucherWritten`, `ReadyForPortal`, `DeviceAddressSet`, `DeviceAddressAlreadySet` and the failure states are the vocabulary. Sonar never writes this file.

## Keeping this page current

This page is checked by `tests/Appendix.Tests.ps1`. It extracts every `'/api/...'` route from `src/AzlSonar/Private/Server.ps1` and every name in `FunctionsToExport` in the manifest, and fails if a route does not have a `### GET /api/...` heading here, if a command does not have a heading here, or if this page has a route heading the server no longer has. When a route or command is added, the test fails until its section is added.

Run it with:

```powershell
Import-Module Pester -RequiredVersion 5.9.1
Invoke-Pester -Path ./tests/Appendix.Tests.ps1
```
