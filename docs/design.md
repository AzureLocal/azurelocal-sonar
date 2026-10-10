# AzL Sonar — design (v0.1)

This is the contract every part of Sonar is built to (plan task S-4). Back end, page and tests follow it exactly; change it here first.

## Layout

| Path | What |
|---|---|
| `Start-AzlSonar.ps1` | Entry point. `-ConfigPath <file>` (required), `-Port` (default 8642), `-NoBrowser`, `-Credential <pscredential>` (node logs; optional). Imports the module, starts the server, opens the browser, runs until Ctrl+C. |
| `src/AzlSonar/AzlSonar.psd1`, `AzlSonar.psm1` | PowerShell 7 module, `Set-StrictMode -Version Latest`. Public functions: `Start-AzlSonarServer`, `Get-AzlSonarDeploymentState`, `ConvertTo-AzlSonarStepTree`, `Get-AzlSonarPhaseGuidance`, `Read-AzlSonarConfig`. |
| `src/AzlSonar/Private/*.ps1` | Azure poller, log tailer, HTTP/SSE server, helpers. |
| `src/AzlSonar/web/index.html`, `app.js`, `app.css` | The page. Vanilla HTML/CSS/JS, no build step, no CDN, no external fonts. Light and dark theme (`prefers-color-scheme` + toggle). |
| `src/AzlSonar/data/phase-guidance.json` | Which account reads which logs in which phase (see below). |
| `examples/sonar.config.example.json` | Example config with neutral values (zero GUIDs, RFC 5737 / documentation addresses). |
| `tests/*.Tests.ps1` | Pester 5. Mocked ARM and node responses; no live calls. |

## Config (`sonar.config.json`)

```json
{
  "subscriptionId": "00000000-0000-0000-0000-000000000000",
  "resourceGroup": "rg-example-azl",
  "clusterName": "clus01",
  "apiVersion": "2025-09-15-preview",
  "identityModel": "LocalIdentity",
  "pollSeconds": 20,
  "nodes": [
    { "name": "node01", "address": "192.0.2.11", "arcMachineName": "node01", "seed": true },
    { "name": "node02", "address": "192.0.2.12", "arcMachineName": "node02" }
  ],
  "logs": {
    "paths": ["C:\\CloudDeployment\\Logs", "C:\\MASLogs"],
    "include": ["*.log", "*.txt"],
    "maxLinesPerPoll": 500
  },
  "credential": { "source": "prompt" }
}
```

`identityModel`: `LocalIdentity` or `ActiveDirectory`. `credential.source`: `prompt` (Get-Credential at start), `parameter` (`-Credential`), or `keyvault` with `vault`, `usernameSecret`, `passwordSecret` (read once at start with Az.KeyVault; never logged, never sent to the page). `arcMachineName` maps a host name to its Arc resource name (simplified machine provisioning names it `<device-id>-1`).

## Azure poller (read-only)

Uses the signed-in Az PowerShell context (`Invoke-AzRestMethod`). Every `pollSeconds`:

1. `GET .../providers/Microsoft.AzureStackHCI/clusters/{cluster}/deploymentSettings/default?api-version={apiVersion}` → `properties.deploymentMode`, `properties.provisioningState`, `properties.reportedProperties.validationStatus` and `.deploymentStatus`. Each status object is `{ status, steps[] }`; a step is `{ name, description, fullStepIndex, startTimeUtc, endTimeUtc, status, steps[]?, exception[]? }` (steps nest; `exception` is an array of strings). Either status object can be `{}` (not started). Statuses seen: `NotStarted`/`Not Started`, `InProgress`, `Success`, `Error`/`Failed`, `Skipped`.
2. `GET .../providers/Microsoft.HybridCompute/machines/{arcMachineName}?api-version=2024-07-10` per node → `properties.status` (Connected/Disconnected), `properties.lastStatusChange`, `properties.agentVersion`.
3. Optional, best effort (ignore 404): `GET .../providers/Microsoft.AzureStackHCI/edgeMachines?api-version=2025-09-15-preview` in the resource group → each edge machine's `properties.provisioningState` and lifecycle (provisioning phase).

`ConvertTo-AzlSonarStepTree` turns a status object into a flat-or-nested normalized tree:
`{ id (fullStepIndex), name, description, status (normalized: notstarted|running|success|error|skipped), start, end, durationSeconds, errors[], children[] }`. Durations: end−start; running steps use now−start.

`Get-AzlSonarDeploymentState` returns
`{ cluster, mode, provisioningState, phase (provisioning|validation|deployment|done|failed), validation{ status, tree[] , counts{} }, deployment{ status, tree[], counts{} }, nodes[{ name, arcStatus, lastStatusChange }], current { phase, stepPath[] , stepName }, polledAt }`.
`current` = the deepest step with status running (else the last finished step). `phase`: deployment if deploymentStatus has steps, else validation if validationStatus has steps, else provisioning.

## Log tailer (read-only)

PowerShell remoting to the seed node (`New-PSSession -ComputerName <address> -Credential`). Workgroup nodes (Local Identity) need the address in the workstation's WinRM `TrustedHosts`; Sonar checks and tells the user, never sets it. Every poll: list files under `logs.paths` matching `include`, newest first; for each file keep a byte offset; read new bytes since the offset (shared read, `FileShare.ReadWrite`), split lines, cap at `maxLinesPerPoll`. Rotation/truncation (size < offset) resets the offset to 0. Lines are classified `error` (`\b(error|exception|failed|fatal)\b`, case-insensitive), `warning` (`\bwarn(ing)?\b`), else `info`. If the session cannot be opened, the tailer reports `{ state: "unavailable", reason }` and retries every 60 s; the page shows the reason and the phase guidance.

## Phase guidance (`data/phase-guidance.json`)

Per phase and identity model: which account reads the node logs, where the logs are, when they exist, and the source. Documented sources only; anything not confirmed in a lab is marked `"verified": false`.

## HTTP API (localhost only, `http://localhost:{port}/`)

| Route | Returns |
|---|---|
| `GET /` , `/app.js`, `/app.css` | the page |
| `GET /api/config` | config without secrets: cluster, resourceGroup, identityModel, nodes (name, seed), log paths, pollSeconds |
| `GET /api/state` | latest `Get-AzlSonarDeploymentState` result |
| `GET /api/guidance` | phase guidance for the configured identity model |
| `GET /api/logs?since={seq}` | `{ tailer: {state, reason, node}, files[{path, size, offset}], lines[{seq, time, file, level, text}] }` — lines with seq > since (ring buffer of the last 5000) |
| `GET /api/events` | Server-Sent Events: `event: state` (data = state JSON) on every change, `event: log` (data = array of new lines), `event: tailer` (tailer status), `: ping` every 15 s |
| `GET /api/export` | one JSON bundle: config (no secrets), every state snapshot taken (timeline), the log ring buffer |

The server binds `http://localhost:{port}/` only. No route changes Azure or a node.

## Page

Header: cluster, phase chip, overall status, elapsed time, last poll, node chips (Arc status), theme toggle. Left: step tree for validation and deployment (collapsible, status icon, duration, live timer on the running step, errors expanded inline; clicking a step filters the log pane to that step's time window). Right: live log pane (auto-scroll with pause, level filter, text search, file filter, error/warning highlight, count badges). Bottom/side: phase guidance card (account, log location, when available). Export button downloads `/api/export`. Accessible: keyboard navigation, focus visible, ARIA live region for status changes. Works at 1280 px and on a narrow window.
