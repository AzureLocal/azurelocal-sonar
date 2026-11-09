# API reference

Sonar has an HTTP API. The page is built on it: every number, step and log line on screen comes from the routes below. This page documents all of them, from the code (`src/AzlSonar/Private/Server.ps1` and the functions it calls) and from a live Sonar 0.4.0 on a real deployment. The examples are real answers with the identifiers replaced by documentation placeholders (`clus01`, `rg-example-azl`, `node01`, `192.0.2.x`, subscription `00000000-0000-0000-0000-000000000000`).

- [The read-only guarantee](#the-read-only-guarantee)
- [Reaching the API](#reaching-the-api): address, access token, cookie, status codes
- [Conventions](#conventions)
- [Routes](#routes)
- [Route reference](#route-reference): one section per route, with an example
- [The state object](#the-state-object): every top-level key of `/api/state`
- [The log line and the tailer](#the-log-line-and-the-tailer)
- [The live stream](#the-live-stream-apievents): the Server-Sent Events protocol
- [Modes and monitors](#modes-and-monitors): what changes in a replay or with `-Monitor`
- [Recipes](#recipes): curl and PowerShell 7
- [Using the API from automation](#using-the-api-from-automation)

## The read-only guarantee

- **Only `GET`.** Any other method (`POST`, `PUT`, `DELETE`, `PATCH`, `HEAD`) is answered `405 Method Not Allowed` with `Allow: GET`, before the route is looked at. There is no route that starts, retries, cancels or changes a deployment, writes to Azure or a node, or changes Sonar's configuration.
- **A call never reaches Azure or a node.** Every answer is built from what Sonar already holds in memory. Azure is read by Sonar's own poller every `pollSeconds` (default 20), the node logs by its own tailer; how often you call the API changes neither. The only things the handlers touch outside memory are local file-existence checks of the event files, for `/api/details`.
- **No secret is in an answer.** Text from nodes and Azure is masked before it is stored (passwords, tokens, keys, the log account's password, the access token itself). Identifiers are not secrets and are not removed: `/api/state` holds Arc machine resource IDs (with the subscription ID), `/api/details` the node addresses, `/api/logs` the seed node's address (in `tailer`). Treat every answer like the deployment itself. The only file Sonar writes is the recording you ask for.

## Reaching the API

| Item | Value |
| --- | --- |
| Address | `http://localhost:8642/` (`-Port` or the port you started Sonar with). Sonar also listens on `http://127.0.0.1:<port>/`. |
| Who can connect | This machine only. A peer that is not loopback gets `403`. There is no setting to open it up; use an SSH tunnel or a remote desktop session to reach it from elsewhere. |
| TLS | None. Plain HTTP on the loopback interface. |
| Authentication | A random access token per start (32 hex characters), exchanged once for a cookie. Off only with `-NoAccessToken` or `accessToken: false` (a single-user machine). |
| `Host` header | Must be `localhost` or `127.0.0.1` (Sonar's own check also allows `[::1]`) with Sonar's port. Anything else is refused (`400`, by Windows HTTP.sys with an HTML page, or by Sonar with an empty body). Do not call Sonar by its machine name or through a reverse proxy. |
| `Origin` header | A request that has one must send Sonar's own origin (`http://localhost:<port>` or `http://127.0.0.1:<port>`; an IPv6 or https origin is refused), else `403` with an empty body. curl, `Invoke-WebRequest` and scripts send none. There are no CORS headers, so a web page from another origin cannot read the API. |

### The access token and the cookie handshake

1. **Get the token.** The simplest way for automation is `Start-AzlSonar.ps1 -TokenFile ./sonar.token` (or `tokenFile` in the config): Sonar writes the token, and only the token, to that file when it starts, readable by the current user only, and removes it when it stops. [`Invoke-AzlSonarApi`](#invoke-azlsonarapi) reads the file, does steps 2 and 3 for you and starts over after a restart (step 4). Without a token file, Sonar prints the token once at start, inside the URL, and the token is new at every start:

   ```text
   AzL Sonar is listening on http://localhost:8642/?t=0123456789abcdef0123456789abcdef for clus01 (read-only). Press Ctrl+C to stop.
   ```

   The line is written to the information stream, so capture it with all streams redirected, for example `./Start-AzlSonar.ps1 ... -NoBrowser *> ./sonar-run.log`, and read the last `t=` value from that file. `-NoBrowser` still prints it. The token is never logged, recorded, exported or returned by the API (it is masked like a password).
2. **Exchange it.** `GET /?t=<token>` (any path takes `?t=`) answers `302` with `Location` set to the same address without the token and `Set-Cookie: sonar_t=<token>; HttpOnly; SameSite=Strict; Path=/`. The cookie comes with the 302 itself: a client with a cookie jar keeps it whether or not it follows the redirect; a client without a jar has no cookie and gets `401` on the next call.
3. **Send the cookie.** Every later request sends `Cookie: sonar_t=<token>`. curl does it with a cookie jar (`-c` to write, `-b` to read), PowerShell with `-SessionVariable` and `-WebSession`.
4. **After a restart** the token changes: the old cookie gets `401`. Read the new token and repeat from step 2.

Without the cookie, and without a correct `?t=`, every route (and the page) answers `401` with the text `Open the URL Sonar printed.` The token is compared in constant time.

### Status codes

| Code | When | Body |
| --- | --- | --- |
| `200` | The route answered. | The JSON (or event stream) of the route. |
| `302` | A request carries the right `?t=<token>` and no valid cookie. | Empty; `Location` and `Set-Cookie` as above. |
| `400` | `since` of `/api/logs` is not a whole number from 0 (`{"error":"since must be a whole number from 0."}`); or the `Host` header is not Sonar's own (HTTP.sys answers with an HTML page, or Sonar with an empty body). | See left. |
| `401` | No valid cookie and no correct `?t=`. | Text `Open the URL Sonar printed.` |
| `403` | The peer is not loopback (`AzL Sonar only answers requests from this machine.`), or the `Origin` header is not Sonar's own (empty body). | Text. |
| `404` | An `/api/` path that is not a route (`{"error":"Unknown API route: /api/nope"}`, also for `/api/` and a trailing slash such as `/api/state/`); `/api/replay` when not replaying; `/api/events` and `/api/export` in a replay. Any other path that is not one of the page's files: text `Not found.` | JSON `{ "error": "..." }` for `/api/*`. |
| `405` | The method is not `GET`. | Text `Only GET is supported.`, header `Allow: GET`. A `POST` without a body gets `411` from HTTP.sys first. |
| `429` | `/api/events` while `maxEventStreams` (default 4) streams are open. | Text, header `Retry-After: 30`. |
| `500` | A route failed inside Sonar. | `{"error":"Internal error."}` |

## Conventions

- **Format.** JSON, UTF-8, `Content-Type: application/json; charset=utf-8`, `Content-Length` set. The characters `<`, `>` and `&` inside strings are written as `\u003c`, `\u003e` and `\u0026`; any JSON parser reads them unchanged. No compression, no pretty printing.
- **Caching.** Every response carries `Cache-Control: no-store`. There are no `ETag` or conditional requests: ask again, or use the [live stream](#the-live-stream-apievents).
- **Other headers.** `X-Content-Type-Options: nosniff`, `Referrer-Policy: no-referrer`, `X-Frame-Options: DENY` and a strict `Content-Security-Policy` on every response.
- **Time.** UTC, ISO 8601 with a `Z`. State fields have second precision (`2026-11-08T22:01:16Z`); log lines have milliseconds (`2026-11-08T23:55:40.786Z`). A time that is not known yet is `null`.
- **Routes.** Matched case-insensitively (`/api/State` works), without a trailing slash, with no version in the path. Query parameters a route does not know are ignored. Read `version` from `/api/about` to know which Sonar you talk to, and ignore fields you do not know: new fields are added over time.
- **Status words.** Steps, groups and sections use `notstarted`, `running`, `success`, `error`, `skipped` and `unknown` (the last two only on steps). Section `status` values add words of their own (`pass`, `fail`, `expired` for the verification gate), listed where they occur.
- **One request at a time.** Sonar answers requests and pushes the live streams from one loop. A very large answer (`/api/export`) delays the others while it is built.

## Routes

| Method | Path | Purpose | Parameters | Limit and caching | Status codes |
| --- | --- | --- | --- | --- | --- |
| `GET` | [`/api/config`](#apiconfig) | The configuration Sonar runs with, without secrets, addresses or secret names. | none | Small; `no-store` | 200 |
| `GET` | [`/api/about`](#apiabout) | Sonar's name, version and documentation links. | none | Small; `no-store` | 200 |
| `GET` | [`/api/guidance`](#apiguidance) | Which account reads which logs, where and when, per phase, for the identity model. | none | About 14 KB; `no-store` | 200 |
| `GET` | [`/api/details`](#apidetails) | What Sonar collected and is using, each value with its source. | none | About 3 KB; `no-store` | 200 |
| `GET` | [`/api/state`](#apistate) | The latest deployment state: phases, step trees, machines, sections. | none | Hundreds of KB on a long deployment (340 KB measured); `no-store` | 200 |
| `GET` | [`/api/logs`](#apilogs) | Node log lines after a sequence number, the tailer status and the files followed. | `since` (whole number, default 0) | At most 2000 lines and about 2 MB per answer, `truncated` says more remain; the ring buffer holds 5000 lines; `no-store` | 200, 400 |
| `GET` | [`/api/events`](#the-live-stream-apievents) | Server-Sent Events: state, tailer status and new log lines as they happen. | none (`Last-Event-ID` is ignored) | At most `maxEventStreams` (4) streams, one `ping` every 15 s, 1000 lines per `log` event | 200, 429; 404 in a replay |
| `GET` | [`/api/export`](#apiexport) | One bundle: config, guidance, latest state, change-only state timeline, the log ring buffer. | none | Not capped: up to 5000 snapshots plus 5000 log lines (215 MB measured with 666 snapshots); `Content-Disposition: attachment`; `no-store` | 200; 404 in a replay |
| `GET` | [`/api/replay`](#apireplay) | Replay only: the whole recording as one document. | none | The size of the recording; `no-store` | 200 in a replay; 404 when live |

Not API: `GET /`, `/index.html`, `/app.js`, `/app.css` and `/azurelocal-sonar-icon.svg` serve the page from a fixed list; any other path answers `404`.

## Route reference

### /api/config

The public configuration. The poller's other settings, addresses, credentials and Key Vault names are not in it.

| Field | Meaning |
| --- | --- |
| `clusterName`, `cluster` | The cluster name (two names for the same value). |
| `resourceGroup` | The resource group Sonar reads. |
| `identityModel` | `LocalIdentity` or `ActiveDirectory`. |
| `provisioningRoute` | As configured: `auto`, `simplified` or `oem-image`. The route Sonar detected is `provisioning.route` in the state. |
| `nodes[]` | `{ name, seed }`: the machines; `seed` marks the one whose logs are tailed. |
| `logs.paths[]` | The folders on the seed node that are followed. |
| `pollSeconds` | Seconds between Azure polls. |
| `monitor` | The [monitor](#modes-and-monitors): `Auto` or one stage. |
| `monitorPhases[]` | The log-access phases the monitor lists. |
| `profile` | `{ clusterPattern, architecture, internalDns, notes[] }` or `null`. |
| `startedAt` | When this Sonar instance started. |
| `serverId` | The instance id (a new GUID without dashes at every start). Equal to `server` in `/api/logs` and in the stream: a different value means Sonar restarted. |
| `webVersion` | A 12-character fingerprint of the page files; the page reloads when it changes. |
| `recording` | `{ file }` while Sonar records; absent otherwise. |
| `replay` | In a replay only: `{ cluster, file, recordedFrom, recordedTo, sessions, invalid, speed, startAt, startAtPhase, autoplay }`. |

```json
{
  "clusterName": "clus01",
  "cluster": "clus01",
  "resourceGroup": "rg-example-azl",
  "identityModel": "ActiveDirectory",
  "provisioningRoute": "simplified",
  "nodes": [ { "name": "node01", "seed": true }, { "name": "node02", "seed": false }, { "name": "node03", "seed": false } ],
  "logs": { "paths": [ "C:\\CloudContent\\MASLogs", "C:\\MASLogs", "C:\\CloudDeployment\\Logs", "C:\\Observability", "C:\\Windows\\System32\\Bootstrap\\Logs" ] },
  "pollSeconds": 20,
  "monitor": "Auto",
  "monitorPhases": [ "provisioning", "arc-registration", "validation", "deployment", "post-deployment", "update", "add-node", "repair" ],
  "profile": { "clusterPattern": "Standard", "architecture": "hyperconverged", "internalDns": false, "notes": [ "Active Directory: the domain is prepared before deployment (OU, deployment user, naming prefix); ..." ] },
  "startedAt": "2026-11-08T18:11:44Z",
  "serverId": "0123456789abcdef0123456789abcdef",
  "webVersion": "bb8edf857301"
}
```

### /api/about

```json
{
  "name": "AzL Sonar",
  "version": "0.4.0",
  "summary": "Watches an Azure Local build from provisioning and OS configuration through validation to deployment.",
  "links": [
    { "id": "docs", "label": "Documentation", "url": "https://azurelocal.cloud/azurelocal-sonar/" },
    { "id": "github", "label": "Release notes and source on GitHub", "url": "https://github.com/AzureLocal/azurelocal-sonar" }
  ]
}
```

`version` is the module version. `links[]` is `{ id, label, url }` (here shortened to two entries; the live answer also has `run`, `config` and `troubleshooting`).

### /api/guidance

The phase guidance for the configured identity model, from `data/phase-guidance.json`.

| Field | Meaning |
| --- | --- |
| `identityModel` | The model the entries were chosen for. |
| `available` | `false` when the guidance file is missing (then `phases` is empty). |
| `version` | The guidance file's version. |
| `phases` | An object keyed by phase: `provisioning`, `arc-registration`, `validation`, `deployment`, `post-deployment`, `update`, `add-node`, `repair`. |
| `phases.<phase>.account` | Which account reads the logs in that phase. |
| `phases.<phase>.logPaths[]` | Where the logs are. |
| `phases.<phase>.when` | When the logs exist. |
| `phases.<phase>.how` | How to connect (WinRM, TrustedHosts, Kerberos). |
| `phases.<phase>.timing` | How long the phase takes and what to expect. |
| `phases.<phase>.commands[]` | Node commands to check in that phase. |
| `phases.<phase>.verified` | `true` only when confirmed on a live run; `confirmedOn`, `observed` and `source` say by what. |

```json
{
  "identityModel": "ActiveDirectory",
  "available": true,
  "version": 1,
  "phases": {
    "deployment": {
      "account": "The local administrator. During cloud deployment the LCM (deployment) user is added to local Administrators on the nodes, and the nodes are joined to the domain.",
      "logPaths": [ "C:\\CloudContent\\MASLogs", "C:\\MASLogs", "C:\\Observability", "C:\\CloudDeployment\\Logs (appears later in the run)" ],
      "when": "During and after cloud deployment on the seed node. ...",
      "how": "Use WinRM by IP with TrustedHosts (or HTTPS 5986) and -Credential until the domain join completes. ...",
      "timing": "Learn (12.2609 latest): once Deploy mode starts, a limited Environment Checker run ... ",
      "commands": [],
      "verified": false,
      "confirmedOn": null,
      "observed": "Seen live 10 Oct 2026 on a Local Identity Deploy pass: ...",
      "source": "https://learn.microsoft.com/azure/azure-local/deploy/deployment-prep-active-directory?view=azloc-2609#considerations-for-large-scale-deployments"
    }
  }
}
```

(Only the `deployment` phase is shown, with long texts shortened.)

### /api/details

What Sonar collected and is using, for the page's Details pop-down. Every value says where it came from. It shows the node addresses and the first 8 characters of the subscription, never a credential.

| Field | Meaning |
| --- | --- |
| `generatedAt`, `mode` | When the answer was built; `live` or `replay`. |
| `target` | `cluster`, `resourceGroup`, `subscription` (first 8 characters, with `note`) and `region`, each `{ value, source }`. `source` names the config file and key, or says the value is from the recording. |
| `route` | `{ value, label, source }`: the provisioning route, the configured one or the one detected from Azure. |
| `identity` | `{ value, label, meaning, source }`. |
| `nodes[]` | `{ name, address, seed }`. In a replay `address` is empty. |
| `logAccount` | The breaker for the domain log account: `account`, `state` (`closed`, `open`, `probing`), `failures`, `maxRejections`, `backoffMinutes`, `nextProbeAt`, `lastClass`, `verified`, `credential` (`ready`, `not read yet`, `unavailable`), `credentialRetryAt`. Never a secret. |
| `sources.azure` | `{ pollSeconds, lastAnswerAt, ok, message }`: the Azure poll. |
| `sources.ztpEvents`, `osConfigEvents`, `armEvents`, `verificationEvents` | Each `{ configured, file, fileFound, events, lastEventAt }`: the event files Sonar follows and how many events it read. |
| `sources.discovery` | `{ configured, location, found, machines, state }`. |
| `sources.nodeLogs` | `{ state, node, credential, transport, reason, lastLineAt }`: the tailer in one line. |
| `config` | `{ readFrom, file, sourceKind, readAt, checkedAt, checkEverySeconds, lastChangeAt, lastChangeNote, notSet[], version }`. `notSet[]` lists settings that are missing, each `{ setting, label, key, effect }`. `checkEverySeconds` is 60 only for `-InfrastructureFile`, else `null`. |

```json
{
  "generatedAt": "2026-11-09T00:08:29Z",
  "mode": "live",
  "target": {
    "cluster": { "value": "clus01", "source": "from sonar.config.json clusterName" },
    "resourceGroup": { "value": "rg-example-azl", "source": "from sonar.config.json resourceGroup" },
    "subscription": { "value": "00000000...", "source": "from sonar.config.json subscriptionId", "note": "first 8 characters only" },
    "region": { "value": "eastus", "source": "from sonar.config.json location" }
  },
  "route": { "value": "simplified", "label": "Simplified machine provisioning (ZTP)", "source": "from sonar.config.json provisioningRoute" },
  "identity": { "value": "ActiveDirectory", "label": "Active Directory", "meaning": "Machines join your domain at deployment; ...", "source": "from sonar.config.json identityModel" },
  "nodes": [ { "name": "node01", "address": "192.0.2.11", "seed": true }, { "name": "node02", "address": "192.0.2.12", "seed": false } ],
  "logAccount": { "account": "", "state": "closed", "failures": 0, "maxRejections": 2, "backoffMinutes": 0, "nextProbeAt": null, "lastClass": "", "verified": false, "credential": "not read yet", "credentialRetryAt": null },
  "sources": {
    "azure": { "pollSeconds": 20, "lastAnswerAt": "2026-11-09T00:08:24Z", "ok": true, "message": "" },
    "ztpEvents": { "configured": true, "file": "ztp-events.jsonl", "fileFound": true, "events": 80, "lastEventAt": "2026-11-07T21:28:40Z" },
    "discovery": { "configured": true, "location": "discovery", "found": true, "machines": 3, "state": "discovered" },
    "nodeLogs": { "state": "connected", "node": "node01", "credential": "supplied", "transport": "auto", "reason": "", "lastLineAt": "2026-11-09T00:08:09.695Z" }
  },
  "config": { "readFrom": "the config file", "file": "sonar.config.json", "sourceKind": "config", "readAt": "2026-11-08T18:11:44Z", "checkedAt": null, "checkEverySeconds": null, "lastChangeAt": null, "lastChangeNote": "", "notSet": [], "version": "0.4.0" }
}
```

(`nodes` shortened to two entries; `osConfigEvents`, `armEvents` and `verificationEvents` have the shape of `ztpEvents`.)

### /api/state

The latest deployment state, as one JSON object. This is the answer to "where is the deployment now". Its keys are explained in [The state object](#the-state-object). It is replaced as a whole after every poll (every `pollSeconds`), so polling it faster than that returns the same document; the `state` event of the [stream](#the-live-stream-apievents) carries the same JSON.

### /api/logs

Node log lines from the seed node (and lines Sonar adds from the event files), kept in a ring buffer of the last 5000.

**Parameter.** `since` is the sequence number after which you want lines (`seq > since`). A whole number of up to 15 digits, default 0; anything else is `400`. A value above the newest sequence number is lowered to it (an empty answer, not an error).

**Answer.**

| Field | Meaning |
| --- | --- |
| `server` | The instance id. If it differs from the one you saw before, Sonar restarted: sequence numbers start again from 1, so ask again with `since=0`. |
| `lastSeq` | The newest sequence number given out when the lines were read. After the answer you have every line up to `lastSeq` (or it already left the ring buffer). Use it as the next `since`. When `truncated` is `true`, `lastSeq` is the sequence number of the last line in this answer instead. |
| `truncated` | `true` when more lines remain than one answer holds (2000 lines or about 2 MB of JSON, whichever comes first). Ask again with `since=<lastSeq>`; the page does exactly this. |
| `tailer` | The [tailer object](#the-tailer-object), or `null` before the tailer first reports (and always when the monitor does not tail). |
| `files[]` | The files being followed: `{ path, size, offset, lastWriteUtc }`. `offset` is how far Sonar has read; `size` is the file size. Empty before the first poll. |
| `lines[]` | The [log lines](#the-log-line), oldest first, at most 2000. |

```json
{
  "server": "0123456789abcdef0123456789abcdef",
  "lastSeq": 252112,
  "truncated": true,
  "tailer": { "state": "connected", "node": "node01", "...": "see the tailer object" },
  "files": [
    { "path": "C:\\CloudDeployment\\Logs\\CloudDeployment.2026-11-08.17-31-36.0.log", "size": 4414204, "offset": 4414204, "lastWriteUtc": "2026-11-09T00:02:45Z" }
  ],
  "lines": [
    {
      "seq": 250113,
      "time": "2026-11-09T04:55:34.000Z",
      "received": "2026-11-08T23:55:40.786Z",
      "timeSource": "line",
      "file": "C:\\CloudDeployment\\Logs\\CloudDeployment.2026-11-08.17-31-36.0.log",
      "level": "info",
      "text": "2026-11-08 23:55:34 Verbose  [MocArb:DeployArb] InterfaceIndex: Get-NetAdapter -Name 'vManagement(management)' -CimSession node01 | select InterfaceIndex"
    }
  ]
}
```

(`files` and `lines` shortened; a real answer here held 13 files and 2000 lines, 690 KB.)

Keep the cursor on `seq`, not on `time`: `time` is the event time and is not monotonic across files.

Two pitfalls when you page:

- **Gaps are silent.** The ring buffer keeps 5000 lines. If you were away longer than that, the lines that left it are simply absent: no marker, `truncated` stays `false`. Compare the first returned `seq` with `since + 1`; a larger value means you missed lines.
- **A restart clamps your cursor.** After a restart the sequence starts at 1 again, so an old `since` larger than the new newest `seq` is lowered to it and the answer is empty and looks normal. Always compare `server` with the one you stored before you trust a `since`; the size trim never returns fewer than one line, so a single very long line can exceed 2 MB.

### /api/events

Server-Sent Events. See [The live stream](#the-live-stream-apievents).

### /api/export

One JSON document to keep or to hand to someone. The page's **Export** button downloads it. The answer has `Content-Disposition: attachment; filename="azlsonar-<cluster>-<yyyyMMdd-HHmmss>.json"` (characters other than letters, digits, `_`, `.` and `-` in the cluster name become `_`).

| Key | Content |
| --- | --- |
| `export` | Metadata: `tool` (`AzL Sonar`), `version`, `server`, `exportedAt`, `snapshots` (entries in `timeline`), `timelineMode` (`change-only`), `timelineMax` (5000), `timelineDropped` (oldest snapshots lost to the cap), `latestStateIncluded` (always `true`), `logRingSize` (5000), `logLinesKept`, `logFirstSeq`, `logLastSeq`, `logLinesDropped` (`logLastSeq - logLinesKept`: lines that left the ring buffer before the export). |
| `config` | The `/api/config` body. |
| `guidance` | The `/api/guidance` body. |
| `state` | The latest state (always kept, whatever the cap did). |
| `timeline[]` | State snapshots, oldest first. A snapshot is added only when the state changed (`polledAt` and running-step durations are ignored), at most 5000; older ones are dropped first. |
| `logs` | The `/api/logs?since=0` body without the 2000-line cap: the whole ring buffer, `truncated` always `false`. |

**Size.** The export is not capped and is built in memory before it is sent. Each snapshot is a full state: on the live run used for this page, 666 snapshots of about 330 KB made a 215 MB answer. Fetch it once, to a file, when you need it, and expect other calls to wait while it is built.

```jsonc
{
  "export": { "tool": "AzL Sonar", "version": "0.4.0", "server": "0123456789abcdef0123456789abcdef", "exportedAt": "2026-11-09T00:05:55Z",
    "snapshots": 666, "timelineMode": "change-only", "timelineMax": 5000, "timelineDropped": 0, "latestStateIncluded": true,
    "logRingSize": 5000, "logLinesKept": 5000, "logFirstSeq": 250481, "logLastSeq": 255480, "logLinesDropped": 250480 },
  "config": { /* /api/config */ },
  "guidance": { /* /api/guidance */ },
  "state": { /* /api/state */ },
  "timeline": [ /* 666 states */ ],
  "logs": { /* /api/logs?since=0, no cap */ }
}
```

In a replay `/api/export` answers `404`; the recording is the export.

### /api/replay

Only when Sonar was started with `-Replay <recording>`; otherwise `404` (`Not replaying. Start Sonar with -Replay <recording> to play a recording.`). The answer is the recording, whole:

```jsonc
{
  "replay": { "cluster": "clus01", "file": "recording-sample.jsonl", "recordedFrom": "2026-10-11T08:00:00.000Z", "recordedTo": "2026-10-11T09:06:00.000Z",
              "sessions": 2, "invalid": 0, "speed": 60.0, "startAt": "2026-10-11T08:00:00.000Z", "startAtPhase": null, "autoplay": false },
  "events": [ { "t": "2026-10-11T08:00:00.000Z", "k": "session", "format": 1, "tool": "AzL Sonar", "version": "0.1.0", "...": "..." }, ... ]
}
```

| Field | Meaning |
| --- | --- |
| `replay` | The same object as `replay` in `/api/config`: the cluster, the recording's file name, the recorded time range, the number of `session` headers (a restart adds one), `invalid` (lines skipped because they were cut off or malformed), the starting `speed` (recorded seconds per real second), `startAt` (UTC time of the start position, or `null`), `startAtPhase` (a phase name to resolve in the page, or `null`) and `autoplay`. |
| `events[]` | Every valid line of the recording, in file order, exactly as recorded: `{ t, k, ... }` with `k` one of `session`, `state` (a full keyframe or `ops` changes), `tailer`, `log` and `end`. The format is in [Record and replay](./how-it-works.md#record-and-replay) and [design](./design.md#record-and-replay-plan-task-s-11). |

The page plays the recording locally. The whole document is held in memory by Sonar and sent in one answer, so a long recording makes a large answer.

## The state object

`/api/state` (and every `state` event, and `state` in the export) is one object. Keys that are always present are marked **always**; the others appear once the first Azure poll has produced them (see [Modes and monitors](#modes-and-monitors)).

### Top-level keys of the state

| Key | Type | Meaning |
| --- | --- | --- |
| `cluster` | string | The cluster name. **Always.** |
| `resourceGroup` | string | The resource group. **Always.** |
| `mode` | string or `null` | The deployment mode Azure reports in `deploymentSettings`: `Validate` or `Deploy`. `null` until the deployment settings exist. **Always.** |
| `provisioningState` | string or `null` | The ARM provisioning state of the deployment settings (`Provisioning`, `Succeeded`, `Failed`, ...). `null` until they exist. **Always.** |
| `phase` | string | Where the deployment is: `provisioning` (simplified route) or `arc-registration` (OEM image route), `validation`, `deployment`, `done` (deployment succeeded), `failed` (the active phase reported an error), `update`, `add-node` or `repair` (after deployment, see `track`). **Always.** |
| `activePhase` | string | `phase` without `done` and `failed`: the phase that is, or was, active. **Always.** |
| `provisioning` | object | How the machines get ready, see [provisioning](#provisioning). **Always.** |
| `monitor` | string | The monitor Sonar runs (`Auto` or one stage). **Always.** |
| `clusterResource` | object | The cluster resource as Azure reports it, see [clusterResource](#clusterresource). **Always.** |
| `discovery` | object | What the toolkit's hardware discovery found on each machine, see [discovery](#discovery). **Always.** |
| `osConfiguration` | object | The toolkit's OS configuration run, see [osConfiguration](#osconfiguration). **Always.** |
| `arm` | object | The toolkit's ARM Validate and Deploy run, see [arm](#arm). **Always.** |
| `verification` | object | The pre-cluster verification gate, see [verification](#verification). **Always.** |
| `extensions` | object | `{ shown, status, nodes[] }`: the four mandatory Arc extensions per machine. `shown` is `true` only on the OEM image route once a validation or deployment exists; they install during Validate. `status` is `notstarted`, `running`, `success` or `error`. Each `nodes[]` entry has the machine's name and its extensions with `name`, `present`, `rawStatus`, `status`, `message`, `start`, `end`. **Always.** |
| `validation` | object | `{ status, tree[], counts }`: the Validate steps Azure reports in `reportedProperties.validationStatus`, see [step trees](#step-trees). **Always.** |
| `deployment` | object | `{ status, tree[], counts }`: the Deploy steps (`reportedProperties.deploymentStatus`). **Always.** |
| `nodes` | array | One entry per configured machine, its Arc machine, see [nodes](#nodes). **Always.** |
| `edgeMachines` | array | The edge machines of the resource group (simplified route), see [edgeMachines](#edgemachines). Empty on the OEM image route. **Always.** |
| `update` | object or `null` | The update track: `{ verified, status, phase, level, label, ran, nextAction, summary, active, updates[], runs[], run, tree[], counts }`. An object after the deployment is done, or with `track: update`, or with `-Monitor Update`, unless `updateTrack` is `off`; `null` otherwise; the key is absent before the first poll. See [The update object](#the-update-object). Built from the Microsoft Learn reference; `verified` is `false` (a whole update was not yet followed live). |
| `track` | string | The `track` setting in lower case: `auto`, `update`, `add-node` or `repair`. Absent before the first poll. |
| `lag` | object | Whether Azure is behind the node: `{ detected, kind, message, source, nodeStep, since, verified }`. `kind` is `rerun-pending` (an ARM deployment newer than the settings is still running; the steps shown are from the previous attempt) or `deploy-not-reported` (Azure shows no deploy step yet but the seed node log shows the orchestrator running `Role:Interface`, named in `nodeStep`), else `null`. `verified` is `false`. Absent before the first poll. |
| `environmentChecker` | object | Which part of Deploy mode runs: `{ stage, label, source, verified }`. `stage` is `none`, `validate`, `starting`, `limited`, `full` or `cloud-deployment`; `source` is `Azure steps`, `node log` or `Learn`. Absent before the first poll. |
| `current` | object | The step in progress, see [current](#current). **Always.** |
| `warnings` | string[] | Things worth knowing that are not errors (an api-version fallback, a missing resource, an Arc machine that could not be read). **Always.** |
| `pollError` | object or `null` | `{ message, at }` when the last Azure poll failed. The rest of the state is then the previous one, unchanged. `null` otherwise. **Always.** |
| `polledAt` | string or `null` | When the last successful poll finished. `null` before the first poll (and always when the monitor does not read Azure). **Always.** |

Read the headline from `phase`, `activePhase`, `current`, `provisioningState` and the `status` of `validation`, `deployment`, `provisioning`, `osConfiguration`, `arm` and `verification`.

### Step trees

`validation.tree`, `deployment.tree`, `update.tree`, each provisioning machine's `tree`, and the trees inside `discovery`, `osConfiguration`, `arm` and `edgeMachines` share one node shape:

| Field | Meaning |
| --- | --- |
| `id` | The step index Azure reports (`fullStepIndex`, for example `0.44`); a position path (`0.3`) when Azure gives none; a fixed name in the event-file sections (`ztp.device`, `osc.RemoteManagement`). |
| `name`, `description` | The step's name and description. |
| `status` | `notstarted`, `running`, `success`, `error`, `skipped` or `unknown`. |
| `rawStatus` | The status word as the source reported it (`InProgress`, `Success`, `Failed`, ...). |
| `start`, `end` | UTC times, or `null`. |
| `durationSeconds` | End minus start; for a running step, now minus start (it grows on every poll); `null` without a start. |
| `errors[]` | The step's exception texts, masked. |
| `children[]` | The nested steps, with the same shape. |

`counts` is `{ total, notstarted, running, success, error, skipped, unknown }`, counted over every level of the tree. `status` of the section is Azure's own status when it reports one, else it is derived from the top-level steps (`error` if any failed, `running` if any runs, `success` if all finished, else `notstarted`).

```jsonc
"deployment": {
  "status": "running",
  "tree": [
    {
      "id": "0", "name": "Deploy Azure Stack HCI", "description": "Deploy the Azure Stack HCI system.",
      "status": "running", "rawStatus": "InProgress",
      "start": "2026-11-08T22:01:16Z", "end": null, "durationSeconds": 7330, "errors": [],
      "children": [
        { "id": "0.1", "name": "Check and resolve requirements", "description": "Check and resolve deployment requirements.",
          "status": "success", "rawStatus": "Success", "start": "2026-11-08T22:01:22Z", "end": "2026-11-08T22:01:38Z",
          "durationSeconds": 16, "errors": [], "children": [] }
        /* ... 60 more steps */
      ]
    }
  ],
  "counts": { "total": 62, "notstarted": 17, "running": 2, "success": 43, "error": 0, "skipped": 0, "unknown": 0 }
}
```

### current

The step in progress: the deepest running step (the latest started when several run), else the most recently finished one.

```json
{
  "phase": "deployment",
  "stepPath": [ "0", "0.44" ],
  "stepNames": [ "Deploy Azure Stack HCI", "Deploy Arc infrastructure components" ],
  "stepName": "Deploy Arc infrastructure components",
  "stepId": "0.44",
  "status": "running"
}
```

`stepPath` lists the step ids from the top level down, `stepNames` the matching names. During provisioning and Arc registration the first element is the machine name. With an empty tree `stepPath` is `[]` and `stepName`, `stepId` and `status` are `null`. When `lag.kind` is `deploy-not-reported` the object is `{ phase: "deployment", stepNames: [ "<Role:Interface>" ], stepName, status: "running", source: "node log" }`.

### clusterResource

The cluster resource, read once a deployment settings object exists (before that the cluster cannot exist).

```json
{ "name": "clus01", "read": true, "exists": true, "status": "DeploymentInProgress", "connectivityStatus": "NotYetRegistered",
  "provisioningState": "Succeeded", "solutionVersion": "10.0.26100", "nodeCount": 3, "nodesConfigured": 3,
  "deploymentState": "Provisioning", "deploymentMode": "Deploy", "error": "" }
```

| Field | Meaning |
| --- | --- |
| `name` | The cluster name. |
| `read` | `false` when this monitor does not read the cluster (`Discovery`, `Provisioning`, `OsConfiguration`, `Verification`) or Azure has not been asked yet. |
| `exists` | `true` (200), `false` (404: `Validate` creates it) or `null` (not read, or Azure answered something else; see `error`). |
| `status`, `connectivityStatus`, `provisioningState` | The cluster's own status, its connection to Azure and its ARM state. |
| `solutionVersion` | `reportedProperties.clusterVersion`. |
| `nodeCount`, `nodesConfigured` | Machines the cluster reports, and machines in the config. |
| `deploymentState`, `deploymentMode` | `provisioningState` and `deploymentMode` of the deployment settings. |
| `error` | Azure's error text when the read failed, else empty. |

### The update object

`update` is the update track. Its verdict never trusts the cluster's update summary alone: `AppliedSuccessfully` is also what a cluster says before any update ever ran.

```json
{ "verified": false, "status": "notstarted", "phase": "waiting", "level": "warn", "label": "Waiting for content", "ran": false,
  "nextAction": { "text": "The update package must be added (SBE side-load): ...", "guide": "https://learn.microsoft.com/azure/azure-local/update/solution-builder-extension?view=azloc-2610#the-additionalcontentrequired-update-state" },
  "summary": { "state": "AppliedSuccessfully", "healthState": "Success", "currentVersion": "12.2610.1004.50", "currentSbeVersion": "", "currentOemVersion": "",
    "hardwareModel": "", "oemFamily": "", "lastChecked": "2026-11-06T09:14:00Z", "lastUpdated": null,
    "checkCounts": { "total": 3, "failed": 2, "critical": 0, "error": 0, "warning": 0, "informational": 2, "other": 0 },
    "failedChecks": [ { "title": "The CAU clustered role should be installed on the cluster", "severity": "Informational", "description": "", "remediation": "" } ] },
  "active": null,
  "updates": [ { "name": "SBE5.0.2609.1611", "version": "5.0.2609.1611", "displayName": "SBE5.0.2609.1611", "description": "...", "packageType": "SBE",
    "state": "AdditionalContentRequired", "stateWord": "Waiting for content", "phase": "waiting", "level": "warn", "nextAction": { "text": "...", "guide": "https://..." },
    "rebootRequired": "Unknown", "availabilityType": "Online", "progressPercentage": null, "notifyMessage": "", "installedDate": null } ],
  "runs": [], "run": null, "tree": [], "counts": { "total": 0, "notstarted": 0, "running": 0, "success": 0, "error": 0, "skipped": 0, "unknown": 0 } }
```

| Field | Meaning |
| --- | --- |
| `verified` | `false`: the track is built from the Microsoft Learn reference; the readiness checks and `AdditionalContentRequired` were seen on a live cluster, a whole update was not yet followed. |
| `status` | `notstarted`, `running`, `success` or `error`. `success` only when a real update run finished `Succeeded` (or `summary.lastUpdated` is set together with an update in state `Installed` when Azure keeps no run) and `summary.state` is `AppliedSuccessfully`. A summary that says `AppliedSuccessfully` with no run is `notstarted`. |
| `phase` | `idle`, `available` (an update is ready or `UpdateAvailable`), `waiting` (`AdditionalContentRequired` or `HasPrerequisite`: it cannot start yet), `preparing`, `installing`, `failed` or `attention`. |
| `level` | The colour of the Update tab: `neutral`, `run`, `warn`, `error` or `ok`. The worst of `status`/`phase` and the failed checks: Critical and Error checks give `error`, Warning checks `warn`, Informational checks nothing. |
| `label` | The plain-word verdict, for example `No update has run`, `Waiting for content`, `Installing 12.2611.1002.10`, `Update failed`, `Update succeeded (12.2611.1002.10)`. |
| `ran` | `true` when an update run exists, or `summary.lastUpdated` is set with an installed update. |
| `nextAction` | `{ text, guide }` for an update that waits (`AdditionalContentRequired`: add the package, SBE side-load) or failed; `guide` is a Microsoft Learn URL. `null` otherwise. |
| `summary` | The cluster's update summary. `state` is Azure's own word (`AppliedSuccessfully`, `UpdateAvailable`, `UpdateInProgress`, `UpdateFailed`, `PreparationInProgress`, `PreparationFailed`, `NeedsAttention`). `lastUpdated` is `null` when no update has ever run. `failedChecks` are the readiness checks that failed, worst severity first (at most 25); `checkCounts` counts them per severity (`critical`, `error`, `warning`, `informational`, `other`). |
| `active` | The update that installs or failed (`name`, `version`, `displayName`, `state`, `rebootRequired`), else `null`. |
| `updates` | Every update Azure lists, running first, then failed, waiting, ready, others, installed (at most 20). `stateWord` is the state in plain words (an unknown state keeps Azure's word and `level` `neutral`). |
| `runs` | The update runs Sonar read, newest first (at most 10): `name`, `update`, `status`, `timeStarted`, `duration`, `lastUpdated`. The runs of the active update, or of the newest installed updates when none installs. |
| `run`, `tree`, `counts` | The newest run (`name`, `update`, `status`, `timeStarted`, `duration`, `lastUpdated`) and its step tree (see [Step trees](#step-trees)). |

With `-Monitor Update` (see [The `-Monitor` option](#the--monitor-option)) `phase` of the state is `update` (`failed` when the update failed) whatever the cluster's deployment history says.

### provisioning

```jsonc
{ "manualInstall": false, "route": "simplified", "routeSource": "config", "phase": "provisioning", "status": "success",
  "readyForValidate": false, "ztpComplete": true,
  "nextStep": { "name": "OS configuration", "guide": "https://azurelocal.cloud" },
  "nodes": [ /* one entry per machine */ ] }
```

| Field | Meaning |
| --- | --- |
| `route` | `simplified` (edge machines, ZTP) or `oem-image` (Arc registration); `null` while `auto` has nothing to decide on. |
| `routeSource` | `config` (set by `provisioningRoute`) or `auto` (detected: `simplified` when edge machines for the configured nodes exist). |
| `phase` | `provisioning` or `arc-registration`, the name of this stage on the route. |
| `status` | `notstarted`, `running`, `success` or `error`, rolled up over the machines. |
| `manualInstall` | `true` when the OS is installed by hand (no ZTP). |
| `readyForValidate` | OEM image route only: every machine is registered and no validation has started. Always `false` on the simplified route. |
| `ztpComplete` | Simplified route with a ZTP event file: every machine is `Provisioned`, its Network step succeeded and its Restore step succeeded or is not applicable. OS configuration comes next. |
| `nextStep` | `{ name, guide }` when `ztpComplete` is `true`, else `null`. |
| `nodes[]` | One entry per configured machine. |

Each `nodes[]` entry has these keys on both routes: `name`, `route`, `exists`, `status`, `percent`, `lifecycle`, `lifecycleMessage`, `connectivityStatus`, `arcMachineName`, `arcMachineResourceId`, `arcSource`, `arcStatus`, `job`, `extensions[]`, `start`, `end`, `errors[]`, `tree[]`.

- **Simplified route** adds `edgeMachineName`, `reportedPercent`, `provisioningState`, `machineState` (from the edge machine), `previousErrors[]` (errors of an earlier attempt of the `ProvisionOs` job, after it was resubmitted) and, with a ZTP event file, `ztp`: `{ complete, device, network, restore }`, each of the last three `{ status, state, message }`. `lifecycle` is `Creating`, `AwaitingConnection`, `Provisioning`, `ReadyForOs`, `InstallingOs` or `Provisioned`; `job` is `{ status, operationStatus, provisioningState, start, end, error }`.
- **OEM image route** adds `update` and `bootstrap` (each `{ available, state, status, rawStatus, done, total, current, start, end }`: the zero-day OS image update and the bootstrap, read on the node) and `probe` (`{ state, reason, transport, lastProbeUtc, lastSuccessUtc, unreachableSince }`). `lifecycle` is `Unknown` (nothing read yet), `NotStarted`, `UpdatingOsImage`, `Bootstrapping`, `Registered` or `Failed`. `percent` is Sonar's estimate, `reportedPercent` what Azure reports.

See [stages](./stages.md) and [Following a ZTP run](./ztp.md) for what each step means.

### nodes

One entry per configured machine: its Azure Arc machine, whatever the phase.

```json
{ "name": "node01", "arcMachineName": "00000000-0000-0000-0000-000000000001-1",
  "arcMachineResourceId": "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-example-azl/providers/Microsoft.HybridCompute/machines/00000000-0000-0000-0000-000000000001-1",
  "arcSource": "config", "seed": true, "arcStatus": "Connected", "lastStatusChange": "2026-11-08T23:51:57Z",
  "agentVersion": "1.67.03504.3207", "registeredAt": "2026-11-07T18:13:30Z" }
```

| Field | Meaning |
| --- | --- |
| `name` | The machine name from the config. |
| `arcMachineName`, `arcMachineResourceId` | The Arc machine Sonar follows. On the simplified route it is named after the device ID (`<device-id>-1`), not the host. |
| `arcSource` | Where the Arc machine was resolved from (`config`, `edgeMachine.job`, ...). |
| `seed` | The machine whose logs are tailed. |
| `arcStatus` | `Connected`, `Disconnected`, `Expired`, `Error` (as Azure reports), `NotFound` (404) or `Unknown` (not read yet). |
| `lastStatusChange`, `registeredAt` | When the status last changed; when the Arc machine was created. |
| `agentVersion` | The Connected Machine agent version. |

### edgeMachines

Simplified route only (empty otherwise): the edge machines Azure holds for the nodes.

```jsonc
{ "name": "node01", "node": "node01", "hostName": "node01", "provisioningState": "Succeeded", "lifecycle": "Provisioned",
  "lifecycleMessage": "Machine has been successfully provisioned.", "machineState": "Purposed", "connectivityStatus": "Connected",
  "arcMachineName": "...-1", "arcMachineResourceId": "/subscriptions/.../machines/...-1", "targetArcMachineResourceId": "/subscriptions/.../machines/...-1",
  "arcSource": "edgeMachine.job",
  "provisionOsJob": { "exists": true, "status": "DeploymentSuccess", "provisioningState": "Succeeded", "operationStatus": null, "percentComplete": 50,
                      "start": "2026-11-07T18:36:46Z", "end": "2026-11-07T19:12:33Z", "error": "...",
                      "validation": { "status": "notstarted", "tree": [] }, "deployment": { "status": "success", "tree": [ /* 20 steps */ ] } } }
```

`node` is the configured node the edge machine matches (empty when it matches none). `provisionOsJob` is the `ProvisionOs` job; its `deployment.tree` is the OS-install step tree.

### discovery

What the toolkit's hardware discovery found. `configured` is `false` without `discoveryPath`.

| Field | Meaning |
| --- | --- |
| `configured`, `status`, `state` | `status` is `notstarted`, `running`, `success` or `error`. `state` is `notconfigured`, `waiting`, `empty`, `partial`, `discovered` or `failed`. |
| `stateText`, `location` | A sentence for the page; the discovery folder's name. |
| `summaryFound`, `collectedAt`, `ready` | The summary file written after the last machine; when it was collected; every machine discovered. |
| `nodesTotal`, `nodesDiscovered`, `nodesFailed`, `problems[]` | Counts and problem texts. |
| `nodes[]` | Per machine: `name`, `found`, `state`, `status`, `stateText`, `serviceTag`, `serial`, `model`, `biosVersion`, `bmcMac`, `collectedAt`, `management` (`{ name, mac, confirmed, reason }`, the suggested management port), `ports[]` (`{ name, slot, mac, linkUp, speedMbps, adapterModel }`), `boss` (`{ present, driveCount, hasVirtualDisk, needsVirtualDisk }`), `warnings`, `warningTexts[]`, `notes[]`, `errors[]`, `tree[]`. |

See [Discovery](./stages.md#discovery).

### osConfiguration

The toolkit's OS configuration run, read from its event file (`osConfigEventsPath`).

| Field | Meaning |
| --- | --- |
| `configured`, `status`, `state` | `status` is `notstarted`, `running`, `success` or `error`; `state` is `waiting`, `planning`, `planned`, `applying`, `converged`, `failed` or `incomplete`. |
| `ready` | Every machine has converged. |
| `run` | The run: `started`, `completed`, `mode`, `exitCode`, `planCompleted`, `planChanges`, `cluster`, `schemaVersion`, `wrapperVersion`, `lastEventAt`, `events`, `id`, `legacy`, `runsSeen`, `staleIgnored`, `seq`, `timeline[]` (each `{ at, state, label, group, known, status, level, seq, message }`). |
| `remoting`, `unknownStates[]`, `guarded[]`, `warnings[]` | The remoting profile and trusted hosts the run reported; events whose state Sonar does not know yet (counted, with the last message); guarded network changes; warnings. |
| `nodesTotal`, `nodesConverged`, `nodesFailed`, `nodesRetrying` | Counts. |
| `wipe` | `{ published, enabled, count, pending, nodes[], approval }`: the disk wipe step. |
| `nodes[]` | Per machine: `name`, `method` (`Ztp` or `Iso`), `methodSource`, `methodNote`, `declared`, `declaredMethod`, `mismatch`, `transport`, `evidence`, `warnings[]`, `versions` (OS build and the SBE), `status`, `state`, `stateText`, `currentStep`, `domainJoined`, `domainAdminsConfigured`, `logAccount`, `converged`, `retries`, `restarts`, `address`, `lastEvent`, `timeline[]`, `unknownStates[]`, `unknownEvents[]`, `waiting`, `remoting`, `guarded`, `guardedDetail`, `changes`, `blocked`, `errors[]`, `attempt`, `start`, `end`, `lastEventAt`, `runCommands[]`, `tree[]`. |

See [OS configuration](./stages.md#os-configuration) and the [event contract](./reference/events.md).

### arm

The toolkit's ARM Validate and Deploy run, read from its event file (`armEventsPath`).

| Field | Meaning |
| --- | --- |
| `configured`, `hasData` | The file is followed; at least one run was read. |
| `status`, `state` | `status` is `notstarted`, `running`, `success` or `error`; `state` is `waiting`, `checking`, `planned`, `validating`, `validated`, `awaitingapproval`, `deploying`, `deployed` or `failed`. |
| `activePhase` | `validation`, `deployment` or empty. |
| `awaitingApproval` | The run waits for an approval. |
| `run` | `runId`, `mode`, `cluster`, `started`, `completed`, `exitCode`, `state`, `finalState`, `template`, `parameterHash`, `schemaVersion`, `lastEventAt`, `events`, `message`, `nextAction`, `failed`, `planned`, `offline`, `approval`. |
| `validation`, `deployment` | One phase each: `name`, `label`, `status`, `kind`, `text`, `started`, `completed`, `elapsedSeconds`, `deploymentName`, `submitted`, `attached`, `skipped`, `resumed`, `carriedOver`, `runId`, `checkCounts` (`total`, `failed`, `warning`, `skipped`, `passed`), `stepCounts`, `current` (`step`, `name`), `failing`, `knownIssue`, `hint`, `hintSource`, `preventiveHint`, `refused`, `message`, `nextAction`, `pollErrors`, `pollError`, `tree[]` (the checks before the submit, then the ARM steps). |
| `hints[]` | Known-issue hints: `id`, `title`, `text`, `phase`, `preventive`, `step`. |
| `warnings[]`, `guide` | Warnings; the URL of the guide. |

See [Validate and Deploy](./arm-run.md).

### verification

The pre-cluster verification gate, read from its event file (`verificationEventsPath`).

| Field | Meaning |
| --- | --- |
| `configured`, `hasData` | The file is followed; a run was read. |
| `status`, `state` | `notstarted`, `running`, `pass`, `fail` or `expired`. A `Pass` verdict while a check still blocks is shown as `fail`; a `Pass` past `run.expiresUtc` is `expired`. |
| `verdict` | The gate's own word: empty, `Pass` or `Fail`. |
| `run` | `runId`, `started`, `completed`, `lastEventAt`, `events`, `stale`, `schema`, `fileHash`, `expiresUtc`, `expiresInSeconds` (negative once expired). |
| `counts`, `total`, `reportedCounts`, `countsMismatch` | Checks by status (`Passed`, `Failed`, `Warning`, `Skipped`, `NotApplicable`, `Fixed`, `Running`); the number of checks; the counts the gate itself reported; `true` when the two differ. |
| `blockers`, `skippedBlocking` | Checks that block the deployment; skipped checks that block. |
| `categories[]` | `{ id, name, status, blocks, counts, checks[] }`; failed checks first inside a category. Each check: `id`, `title`, `category`, `status`, `node`, `message`, `remedy`, `source`, `sourceUrl`, `blocking`, `blocks`, `seq`, `at`. |
| `attention[]` | The blocking checks, with the same fields as a check. |
| `warnings[]`, `guide` | Warnings; the URL of the guide. |

See [Pre-cluster verification](./verification.md).

### The condensed example

The shape of a whole state, one entry per array and the long sections shortened (a real one from a deployment in its Deploy phase was 340 KB):

```jsonc
{
  "cluster": "clus01",
  "resourceGroup": "rg-example-azl",
  "mode": "Deploy",
  "provisioningState": "Provisioning",
  "phase": "deployment",
  "activePhase": "deployment",
  "provisioning": { "manualInstall": false, "route": "simplified", "routeSource": "config", "phase": "provisioning", "status": "success", "readyForValidate": false, "ztpComplete": true, "nextStep": { "name": "OS configuration", "guide": "https://azurelocal.cloud" }, "nodes": [ /* 3 */ ] },
  "monitor": "Auto",
  "clusterResource": { "name": "clus01", "read": true, "exists": true, "status": "DeploymentInProgress", "connectivityStatus": "NotYetRegistered", "provisioningState": "Succeeded", "solutionVersion": "10.0.26100", "nodeCount": 3, "nodesConfigured": 3, "deploymentState": "Provisioning", "deploymentMode": "Deploy", "error": "" },
  "discovery": { "configured": true, "status": "success", "state": "discovered", "stateText": "All 3 machines discovered; 3 to check before ZTP", "location": "discovery", "summaryFound": true, "collectedAt": "2026-11-08T06:05:18Z", "ready": true, "nodesTotal": 3, "nodesDiscovered": 3, "nodesFailed": 0, "problems": [], "nodes": [ /* 3 */ ] },
  "osConfiguration": { "configured": true, "status": "success", "state": "converged", "ready": true, "nodesTotal": 3, "nodesConverged": 3, "nodesFailed": 0, "nodesRetrying": 0, "nodes": [ /* 3 */ ], "warnings": [] },
  "arm": { "configured": true, "hasData": true, "status": "running", "state": "deploying", "activePhase": "deployment", "awaitingApproval": false, "validation": { /* ... */ }, "deployment": { /* ... */ }, "hints": [ /* 2 */ ], "warnings": [] },
  "verification": { "configured": true, "hasData": true, "status": "fail", "state": "fail", "verdict": "Fail", "total": 183, "blockers": 24, "categories": [ /* 6 */ ], "attention": [ /* 24 */ ], "warnings": [] },
  "extensions": { "shown": false, "status": "notstarted", "nodes": [] },
  "validation": { "status": "success", "tree": [ /* 24 steps */ ], "counts": { "total": 31, "notstarted": 0, "running": 0, "success": 30, "error": 0, "skipped": 1, "unknown": 0 } },
  "deployment": { "status": "running", "tree": [ /* 1 step, 61 children */ ], "counts": { "total": 62, "notstarted": 17, "running": 2, "success": 43, "error": 0, "skipped": 0, "unknown": 0 } },
  "nodes": [ /* 3 */ ],
  "edgeMachines": [ /* 3 */ ],
  "update": null,
  "track": "auto",
  "lag": { "detected": true, "kind": "rerun-pending", "message": "An ARM deployment started at 2026-11-08T22:00:40Z is still running in Azure (a new deployment). The steps below are from the previous attempt until Azure rewrites them.", "source": "ARM deployment", "nodeStep": null, "since": "2026-11-08T22:00:40Z", "verified": false },
  "environmentChecker": { "stage": "cloud-deployment", "label": "Cloud deployment (the limited and full Environment Checker runs are done)", "source": "Azure steps", "verified": false },
  "current": { "phase": "deployment", "stepPath": [ "0", "0.44" ], "stepNames": [ "Deploy Azure Stack HCI", "Deploy Arc infrastructure components" ], "stepName": "Deploy Arc infrastructure components", "stepId": "0.44", "status": "running" },
  "warnings": [],
  "pollError": null,
  "polledAt": "2026-11-09T00:03:26Z"
}
```

## The log line and the tailer

### The log line

Each entry of `lines[]` in `/api/logs`, `/api/events` (`log` event) and `/api/export`:

| Field | Meaning |
| --- | --- |
| `seq` | Sequence number, from 1, unique and increasing within one Sonar instance (the `server` id). It restarts at 1 when Sonar restarts. This is the cursor for `since`. |
| `time` | The event time, UTC with milliseconds. See `timeSource` for how it was found. A node-local time (no `Z`, no offset) is converted with the node's UTC offset (`tailer.nodeUtcOffsetMinutes`); a log that writes UTC without saying so is therefore shifted by that offset. Compare with `received` if a file looks hours off. |
| `received` | When Sonar received the line, UTC. |
| `timeSource` | `line` (the line's own leading timestamp), `file` (the timestamp in the file name) or `received` (neither: `time` equals `received`, approximate). |
| `file` | The full path of the file on the node. Lines Sonar adds from an event file carry that file's name. |
| `level` | `info`, `warning` or `error`, worked out from the text. Zero-count summaries such as `Failed: 0` are not flagged. |
| `text` | The line, with secrets masked. |

Lines of one file are in file order; across files `time` is not monotonic. Order and page by `seq`.

### The tailer object

The status of the reader that follows the seed node's logs. `/api/logs` has it as `tailer`, the stream as the `tailer` event. It is `null` until the tailer first reports.

| Field | Meaning |
| --- | --- |
| `state` | `connecting`, `connected` or `unavailable`. |
| `reason` | Why it is not working, or a note (for example folders that do not exist yet); empty when all is well. |
| `node`, `address` | The seed node and the address Sonar connects to. |
| `credential` | `supplied` (a prompt, `-Credential` or Key Vault account) or `current Windows identity`. Never the account's secret. |
| `trustedHosts` | `{ required, trusted, message }`: whether this workstation's WinRM `TrustedHosts` has to list the address, and whether it does. |
| `missingPaths[]` | Configured folders that do not exist yet. |
| `fileErrors[]` | Files that could not be read. |
| `filesTracked` | Files followed now. |
| `lastPollUtc` | The last successful poll. |
| `retryInSeconds` | Only when `unavailable`: seconds until the next attempt. |
| `transport` | `winrm` or `ssh`. Only when connected. |
| `activeFiles[]` | Paths of the files read in the last poll. |
| `stateEntries`, `renamedFiles` | Files remembered (offsets kept for rotation) and renames recognised so far. |
| `nodeUtcOffsetMinutes` | The node's UTC offset, used to convert node-local times (`-300` for UTC-5). |
| `lastDiscoveryUtc` | When the folders were last listed (the expensive part, every 3rd poll or 60 s). |

```json
{ "state": "connected", "reason": "", "node": "node01", "address": "192.0.2.11", "credential": "supplied",
  "trustedHosts": { "required": true, "trusted": true, "message": "192.0.2.11 is in the WinRM client TrustedHosts list." },
  "missingPaths": [], "fileErrors": [], "filesTracked": 13, "lastPollUtc": "2026-11-09T00:03:37Z", "transport": "winrm",
  "activeFiles": [ "C:\\CloudDeployment\\Logs\\CloudDeployment.2026-11-08.17-31-36.0.log" ],
  "stateEntries": 154, "renamedFiles": 1004, "nodeUtcOffsetMinutes": -300, "lastDiscoveryUtc": "2026-11-09T00:02:56Z" }
```

## The live stream (/api/events)

`GET /api/events` is a [Server-Sent Events](https://html.spec.whatwg.org/multipage/server-sent-events.html) stream (`Content-Type: text/event-stream; charset=utf-8`, chunked, kept open). The page uses it; so can you (`EventSource` in a browser on the same origin, or any SSE client that sends the cookie).

| Part | Content |
| --- | --- |
| Start | `retry: 5000` (a client reconnects after 5 s), then `event: hello`. |
| `hello` | `{ "server": "<instance id>", "since": <seq> }`: the instance id, and the log sequence number the stream continues after. Lines up to `since` are not sent on the stream; fetch them with `/api/logs?since=<your last seq>` if you need them. |
| `state` | `data:` is the whole state JSON ([the state object](#the-state-object)). Sent right after `hello`, then after every poll (every `pollSeconds`), including a failed one (`pollError` set). Successive events replace each other: keep the latest. |
| `tailer` | `data:` is the [tailer object](#the-tailer-object). Sent once the tailer has reported, then after each of its polls (`lastPollUtc` changes every time). Never sent when the monitor does not tail. |
| `log` | `data:` is `{ "server": "<instance id>", "lines": [ ... ] }`, at most 1000 [log lines](#the-log-line) per event, in order. Only lines after `since` are sent, as they arrive. |
| `: ping` | A comment line every 15 seconds so idle connections stay open and a dead peer is noticed. Ignore it. |

```text
retry: 5000

event: hello
data: {"server":"0123456789abcdef0123456789abcdef","since":255348}

event: state
data: {"cluster":"clus01","resourceGroup":"rg-example-azl","mode":"Deploy", ...}

event: tailer
data: {"state":"connected","reason":"","node":"node01","address":"192.0.2.11", ...}

: ping

event: log
data: {"server":"0123456789abcdef0123456789abcdef","lines":[{"seq":255349,"time":"2026-11-08T22:28:59.000Z","received":"2026-11-09T00:05:20.248Z","timeSource":"file", ...}]}
```

**Reconnecting.** Events carry no `id:`, so `Last-Event-ID` is not supported and a reconnect is not resumed. After you reconnect (`EventSource` does it after `retry`), do what the page does: read `server` and `since` from `hello`; if `server` differs from the one you had, Sonar restarted, so drop what you hold and read `/api/logs?since=0`; otherwise read `/api/logs?since=<your last seq>` (repeat while `truncated` is `true`) to close the gap, and take `/api/state` once.

**Limits and dropping.**

- At most `maxEventStreams` streams at once (default 4, 1 to 50). One more gets `429` with `Retry-After: 30`. A browser tab holds one.
- Sonar never waits for a client. A client whose last write is still in flight gets nothing new that turn (state and tailer events coalesce to the latest; log lines wait). A client is dropped, its connection aborted, when a write fails or has not finished in 15 seconds, when more than 4 MiB are queued for it, or when the lines it still needs have left the 5000-line ring buffer. Reconnect and catch up as above.
- In a replay `/api/events` answers `404`.

## Modes and monitors

What the API returns depends on how Sonar was started.

### Live and replay

| | Live (`-ConfigPath` or `-InfrastructureFile`) | Replay (`-Replay <recording>`) |
| --- | --- | --- |
| `/api/state` | Current, replaced every poll. | The state at the start position, fixed. The page rebuilds the state at any other time from `/api/replay`. |
| `/api/logs` | The ring buffer; `tailer` and `files` fill in. | `{ lastSeq: 0, truncated: false, tailer: null, files: [], lines: [] }`: nothing is live. |
| `/api/events`, `/api/export` | Available. | `404` (`Replay mode: <path> is not available; the page plays /api/replay.`). |
| `/api/replay` | `404`. | The recording. |
| `/api/config` | The live configuration; `recording` while recording. | The recorded configuration (without `monitor`, `monitorPhases`, `profile`, `webVersion`) plus `replay`; `serverId` is a new id. |
| `/api/details` | `mode: "live"`. | `mode: "replay"`; the facts come from the recording, so `subscription`, `region` and the node `address` values are empty. |
| `/api/about`, `/api/guidance` | Available. | Available (the guidance from the recording when it has one). |
| Token | Per start. | Per start (unless `-NoAccessToken`). No Azure sign-in or node access. |

### The `-Monitor` option

`-Monitor` (or `monitor` in the config) limits Sonar to one stage. The API keeps all its routes. What changes is which workers run, so which parts of the state are filled in: a section whose worker does not run keeps its empty form (`configured`, `status: "notstarted"`, empty arrays), it is never absent. The hardware discovery folder is read by the poll itself, so `discovery` is filled whenever `discoveryPath` is set.

| Monitor | Azure polled | Other workers | What the API shows |
| --- | --- | --- | --- |
| `Auto` (default) | yes | ZTP, OS configuration, ARM and verification event files, the node probe, the seed node log tailer | Everything. |
| `Discovery` | no | none | The initial form of the state: no `update`, `track`, `lag` or `environmentChecker`; `polledAt` stays `null`; `nodes[].arcStatus` is `Unknown`; `/api/logs` has no `tailer` or `files`. |
| `Provisioning` | yes | ZTP events, the node probe | No cluster read (`clusterResource.read` is `false`), no ARM, OS configuration or verification data, no log tailer. |
| `OsConfiguration` | yes (also the Arc run commands) | OS configuration events | As `Provisioning`, without ZTP events or the node probe. |
| `Verification` | no | verification events | Like `Discovery`; the `verification` section is filled. |
| `Validate` | yes | ARM events, the log tailer | The cluster, `validation`, `arm` and the tailer. |
| `Deployment` | yes | ARM events, the log tailer | The cluster, `deployment`, `arm` and the tailer. |
| `Update` | yes | the log tailer | The cluster resource, the Arc machine of each node and the update track; `phase` is `update` (`failed` when the update failed). No deployment settings, edge machines, ARM events or event files are read: `deployment` and `validation` stay empty. |
| `AddNode`, `Repair` | yes | the log tailer | The cluster (or the Arc machines and the node log for add node and repair); no ARM events. |

`/api/config` reports the monitor in `monitor` and the log-access phases it lists in `monitorPhases`; `/api/state` repeats it in `monitor`.

## Recipes

All recipes read only. `$token` is the token from the launch output; do not paste it into a shared place.

### curl

```bash
# 1. Exchange the token for the cookie (once per Sonar start).
curl -s -o /dev/null -c cookies.txt "http://localhost:8642/?t=$TOKEN"

# 2. Call the routes with the cookie.
curl -s -b cookies.txt http://localhost:8642/api/state | jq '{phase, activePhase, current: .current.stepName}'
curl -s -b cookies.txt http://localhost:8642/api/about | jq -r .version

# Newest log lines, errors only (jq). since = the last seq you saw.
curl -s -b cookies.txt "http://localhost:8642/api/logs?since=250000" | jq -r '.lines[] | select(.level=="error") | "\(.time) \(.text)"'

# The Verification verdict and what blocks.
curl -s -b cookies.txt http://localhost:8642/api/state | jq '.verification | {status, verdict, blockers, counts}'

# Save an export (can be very large).
curl -s -b cookies.txt -OJ http://localhost:8642/api/export

# Watch the stream (Ctrl+C to stop). -N turns buffering off.
curl -s -N -b cookies.txt http://localhost:8642/api/events
```

### PowerShell 7

The recipes use [`Invoke-AzlSonarApi`](#invoke-azlsonarapi), which ships with the module (it does the cookie handshake). Start Sonar with `-TokenFile ./sonar.token`, import the module once and tell the helper where the token is; every recipe then runs as written. Dates in the parsed JSON arrive as `[datetime]`.

```powershell
Import-Module ./src/AzlSonar/AzlSonar.psd1
$PSDefaultParameterValues['Invoke-AzlSonarApi:TokenFile'] = './sonar.token'
```

**Get the state.**

```powershell
$state = Invoke-AzlSonarApi '/api/state'
'{0} / {1} / {2} (polled {3:u})' -f $state.phase, $state.deployment.status, $state.current.stepName, $state.polledAt
```

**Follow the logs with `since` / `lastSeq` paging.** `-All` pages for you: it asks again with `since=<lastSeq>` while `truncated` is `true`, and returns one object with the lines, the new cursor (`LastSeq`), the instance id (`Server`) and the gap and restart checks described under [two pitfalls](#apilogs). Keep `LastSeq` and `Server`, and give them back next time.

```powershell
# New lines every 5 seconds. A huge -Since is lowered to the newest seq: an empty page that gives the cursor.
$cursor = (Invoke-AzlSonarApi '/api/logs' -Since 999999999999999 -All).LastSeq
$server = $null
while ($true) {
    $page = Invoke-AzlSonarApi '/api/logs' -Since $cursor -ServerId $server -All
    if ($page.Gap) { "Missed seq $($page.MissedFrom) to $($page.MissedTo)" }
    foreach ($line in $page.Lines) { '{0:HH:mm:ss} {1,-7} {2}' -f $line.time, $line.level, $line.text }
    $cursor = $page.LastSeq; $server = $page.Server
    Start-Sleep -Seconds 5
}
```

The first call has no `-ServerId`, so it cannot tell whether Sonar restarted; every later call does. After a restart the helper warns, sets `Restarted` and reads from `0` (the old cursor means nothing to the new instance).
**Filter errors** (lines Sonar rated `error`, from the ring buffer):

```powershell
(Invoke-AzlSonarApi '/api/logs' -All).Lines | Where-Object level -eq 'error' |
    Select-Object seq, time, @{ n = 'file'; e = { Split-Path $_.file -Leaf } }, text
```

**Watch the deployment step tree.** Flatten the nested steps and show what runs or failed:

```powershell
function Get-AzlSonarStep {
    param([Parameter(Mandatory)][object[]]$Tree, [string[]]$Path = @())
    foreach ($step in $Tree) {
        $here = @($Path + $step.name)
        [pscustomobject]@{ Id = $step.id; Status = $step.status; Seconds = $step.durationSeconds; Path = $here -join ' > ' }
        if ($step.children) { Get-AzlSonarStep -Tree $step.children -Path $here }
    }
}

$state = Invoke-AzlSonarApi '/api/state'
$steps = Get-AzlSonarStep $state.deployment.tree
$steps | Where-Object Status -in 'running', 'error' | Format-Table -AutoSize
$state.deployment.counts        # total, notstarted, running, success, error, skipped, unknown
```

**Read the Verification monitor result.**

```powershell
$v = (Invoke-AzlSonarApi '/api/state').verification
if (-not $v.hasData) { 'No verification run yet.'; return }
'{0}: {1} checks, {2} failed, {3} blocking, expires in {4} s' -f $v.verdict, $v.total, $v.counts.Failed, $v.blockers, $v.run.expiresInSeconds
$v.attention | Select-Object id, status, node, title | Format-Table -AutoSize -Wrap
```

`status` is `pass`, `fail`, `running` or `expired`; a negative `run.expiresInSeconds` means the pass is no longer valid.

**Save an export** (the file can be hundreds of MB):

```powershell
$file = Invoke-AzlSonarApi '/api/export' -OutFile (Join-Path $PWD 'sonar-export.json')
'{0:N0} MB' -f ($file.Length / 1MB)

# Read the metadata without loading the file: the first bytes hold the "export" object.
$stream = [System.IO.File]::OpenRead($file.FullName)
try { $buffer = [byte[]]::new(700); $null = $stream.Read($buffer, 0, $buffer.Length) } finally { $stream.Dispose() }
[System.Text.Encoding]::UTF8.GetString($buffer)
```

**Follow the live stream** (`/api/events`). `-Follow` writes one object per event, `{ Event, Data }`, as it arrives; `-EventName` keeps the events you want and `-DurationSeconds` stops it (without it, Ctrl+C or the end of the stream does):

```powershell
Invoke-AzlSonarApi '/api/events' -Follow -EventName state -DurationSeconds 120 |
    ForEach-Object { '{0:u} {1} {2}' -f $_.Data.polledAt, $_.Data.phase, $_.Data.current.stepName }
```

**Wait for a phase** (for a pipeline step):

```powershell
do { Start-Sleep -Seconds 30; $state = Invoke-AzlSonarApi '/api/state' }
until ($state.phase -in 'done', 'failed')
if ($state.phase -eq 'failed') { throw "Deployment failed at: $($state.current.stepName)" }
```

## Using the API from automation

Sonar is a local tool on the workstation or runner that started it. Anything that runs there and has the token can use the API: a CI step, a script, an agent such as Claude Code.

- **Start Sonar with a token file.** `./Start-AzlSonar.ps1 -InfrastructureFile ./infrastructure.yml -NoBrowser -TokenFile ./sonar.token` writes the access token to `./sonar.token` (or set `tokenFile` in the config) and removes it when Sonar stops, so nothing has to read the launch output. Give `-Credential` (or a Key Vault credential) so nothing prompts. See [Run from a pipeline](./run.md#run-from-a-pipeline-or-an-unattended-session) and [the token file](#the-token-file).
- **Call it with the helper.** [`Invoke-AzlSonarApi`](#invoke-azlsonarapi) does the handshake, the paging and the stream, and its errors say what to do. Do not write your own cookie handling.
- **Treat the token as a secret** for as long as Sonar runs. The token file is readable by the current user only and the helper never prints the token; do not copy it into artifacts, tickets or chat. It dies with Sonar; there is no long-lived credential. Do not start Sonar with `-NoAccessToken` on a shared host.
- **One session per Sonar start.** The helper does the handshake once and reuses the cookie. When Sonar restarts the token changes: the helper reads the token file again and continues. With a token it was given directly (`-Token`) it reports `401` instead.
- **Poll sensibly.** The state changes at most every `pollSeconds`, so poll `/api/state` no faster than that, or hold a stream open with `-Follow`. Page `/api/logs` with `-Since`/`-All`; do not fetch `/api/export` in a loop.
- **Do not depend on the page.** Use the routes, not the DOM or `app.js`. Ignore unknown fields.
- **An agent** can answer "where is the deployment" with `GET /api/state` (`phase`, `current`, the `status` of each section) and "what failed" with `deployment.tree` (steps with `status: "error"` and their `errors[]`), `arm.deployment.failing`, `verification.attention` and the `error` log lines. It changes nothing, so it needs no approval beyond reading the token file.

### The token file

`Start-AzlSonar.ps1 -TokenFile <path>` (or `tokenFile` in the config; the parameter wins) writes the per-start access token, and only the token, to `<path>`, with no URL and no newline.

- **Private.** The file is created with its permissions already set, so there is no moment when others can read it. On Windows its access control list has one allow entry, the current user, and inherits nothing; on Linux and macOS the mode is `600`. Sonar checks the result and stops with an error (removing the file) when it is not private.
- **Removed at stop.** Sonar deletes the file when it stops (Ctrl+C included), but only while it still holds that token. If the delete fails it empties the file. A crash or a killed process leaves a token that no longer works; the next start replaces it.
- **Never over a foreign file.** A path that is a folder, a link, or an existing file that is not a Sonar token file (not empty and not just a token) is refused before anything starts, unless `-Force`. The folder must exist.
- **Shown without the token.** The launch output names the file (`Access token file: ...`) and prints the address without `?t=`. The browser, when it opens, still gets the token in its address.
- **Needs the token on.** `-TokenFile` or `tokenFile` together with `-NoAccessToken` or `accessToken: false` is an error.

### Invoke-AzlSonarApi

Ships with the module (`Import-Module ./src/AzlSonar/AzlSonar.psd1`) and as `./scripts/Invoke-AzlSonarApi.ps1` for callers that do not import modules. It sends only `GET`, only to this machine (`-BaseUrl` must be `localhost` or `127.0.0.1`; the token is never sent to another host), keeps one session cookie container per Sonar address, and never prints, logs or returns the token, not even in an error.

```powershell
Import-Module ./src/AzlSonar/AzlSonar.psd1
$PSDefaultParameterValues['Invoke-AzlSonarApi:TokenFile'] = './sonar.token'   # or pass -TokenFile / -Token every time

Invoke-AzlSonarApi '/api/about' | Select-Object name, version
Invoke-AzlSonarApi '/api/state' | Select-Object phase, activePhase, @{ n = 'step'; e = { $_.current.stepName } }
```

| Parameter | Meaning |
| --- | --- |
| `-Route` (position 0) | One of the nine routes, checked: `/api/config`, `/api/about`, `/api/guidance`, `/api/details`, `/api/state`, `/api/logs`, `/api/events`, `/api/export`, `/api/replay`. Any case. |
| `-Since`, `-All`, `-ServerId` | `/api/logs`. `-Since` is the cursor (default 0). `-All` pages until caught up and returns one result object (below). `-ServerId` is the `Server` of your last call. |
| `-Follow`, `-EventName`, `-DurationSeconds` | `/api/events` (needs `-Follow`). One `{ Event, Data }` object per event as it arrives; only the events named by `-EventName` (`hello`, `state`, `tailer`, `log`); stop after `-DurationSeconds` (0: until the stream ends or you stop it). |
| `-BaseUrl` | `http://localhost:8642` by default. |
| `-TokenFile`, `-Token` | The access token. Prefer `-TokenFile` (the file Sonar wrote with its own `-TokenFile`); it is read again after a restart. `-Token` is the 32 hex characters only, not the URL. A Sonar started with `-NoAccessToken` needs neither. |
| `-Raw` (alias `-AsJson`) | Return the body as text instead of objects. With `-All` or `-Follow`: one compact JSON text per result or event. |
| `-OutFile` | Save the answer to a file and return it (for `/api/export`; written through a `.part` file, so a failed call leaves nothing). |
| `-TimeoutSeconds` | Seconds one request may take (default 30). For `-Follow`: the longest quiet time on the stream (Sonar pings every 15 seconds). |
| `-MaxRetry` | Retries after `429` (default 2). |

**The handshake.** On the first call (and whenever the token changes) the helper sends `GET /?t=<token>`, takes the `302` and its `sonar_t` cookie into the session's cookie container, and sends the cookie from then on. When Sonar answers `401` later (it restarted) and `-TokenFile` now holds another token, the helper opens a new session and repeats the call once.

**`/api/logs -All`.** Returns one object:

| Property | Meaning |
| --- | --- |
| `Server` | The instance id of the last page. Give it back as `-ServerId`. |
| `Since`, `LastSeq`, `Pages` | The cursor you gave, the cursor to use next time, and the number of requests it took. |
| `Lines` | The log lines, oldest first, from every page. |
| `Gap`, `MissedFrom`, `MissedTo`, `MissedCount` | `true` when lines left the 5000-line ring buffer before they were read: the first returned `seq` was above the cursor + 1 (or every line was gone). `MissedFrom` and `MissedTo` span the first to the last missing line (several gaps in one call are one span); `MissedCount` is the exact number of lines missed. A warning says which. |
| `Restarted` | `true` when the instance id differs from `-ServerId`, or changes between two pages: Sonar restarted and its sequence numbers start again. The helper warns and reads again from `0`; `Lines` then holds only the new instance's lines. |

**Errors.** Each error is a normal PowerShell error whose message says what happened and what to do, with the HTTP status in `$_.Exception.StatusCode` and the id `AzlSonarApi.<status>`. No message holds the token.

| Status | The message says |
| --- | --- |
| `401` | The token is missing, wrong, or Sonar restarted (every start has a new token): pass the current `-Token`, or `-TokenFile` of a Sonar started with `-TokenFile`. |
| `403` | Sonar only answers this machine, and requests without a foreign `Origin`: call it from the machine Sonar runs on. |
| `404` | No such route; `/api/replay` exists only with `-Replay`; a replay does not serve `/api/events` or `/api/export`. Sonar's own text is added. |
| `405` | Sonar is read-only and only answers `GET` (the helper never sends anything else). |
| `429` | Too many event streams (`maxEventStreams`). The helper waits `Retry-After` seconds (at most 120) and tries again up to `-MaxRetry` times, then reports the status and the time to retry. |
| `400`, `5xx` | Sonar's own error text. |
| no status | `Cannot reach Sonar at ...` (not running, wrong port), `did not answer within N second(s)`, or `went silent` on a stream. |

```powershell
# Everything at once: errors in the log since the last call, the verdict, and a saved export.
$page = Invoke-AzlSonarApi '/api/logs' -Since $cursor -ServerId $server -All
$page.Lines | Where-Object level -eq 'error' | Select-Object seq, time, text
(Invoke-AzlSonarApi '/api/state').verification | Select-Object status, verdict, blockers
Invoke-AzlSonarApi '/api/export' -OutFile ./sonar-export.json
```

The script form takes the same parameters: `./scripts/Invoke-AzlSonarApi.ps1 /api/state -TokenFile ./sonar.token`.

## Tests

`tests/ApiDocs.Tests.ps1` keeps this page and the code together: it fails when a route registered in `Server.ps1` is missing from the [routes table](#routes) (or the reverse), when a top-level key of the state is missing here (or the reverse), when a stream event name, a log line field or a limit differs from the code, and when a relative link on the page is dead.
