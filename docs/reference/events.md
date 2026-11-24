# Event feed

AzL Sonar records a run as **JSON Lines**: one event per line, UTF-8, append-only. The same lines are what `-Replay` plays
back. Any tool that writes lines in this shape to a `.jsonl` (or gzip `.jsonl.gz`) file can be replayed with Sonar, and
Sonar's own recordings can be read by other tools. The contract is [`events.schema.json`](events.schema.json) (JSON
Schema 2020-12). Sonar validates its own recordings and a minimal hand-written feed against it in the test suite.

## The events

Every line has `t` (UTC time, `2026-10-11T08:00:01.000Z`; never goes backwards in a file) and `k` (kind).

| `k` | Body | Meaning |
| --- | --- | --- |
| `session` | `format`, `tool`, `version`, `server`, `cluster`, `config`, `guidance` | One per start of the producer. The first valid line of a file. `format` is `1`; a reader refuses a newer format. Appending a new session to an existing file is allowed. |
| `state` | `full` (a keyframe) or `ops` (a delta) | The state the page shows: phase, step trees, nodes, warnings. A keyframe is the whole state; a delta is a list of `["s", path, value]` (set; an index equal to the array length appends), `["d", path]` (delete) and `["t", path, length]` (truncate an array). A delta before the first keyframe of its session is skipped. |
| `tailer` | `tailer` | The status of the log reader: `state`, `reason`, `node`, `activeFiles[]`. |
| `log` | `lines[]`, `lost?` | Log lines in order: `seq`, `time`, `received`, `timeSource`, `file`, `level` (`info`, `warning`, `error`), `text`. |
| `end` | | The producer stopped cleanly. |

A reader skips a line that is not a JSON object with `t` and `k` (and counts it), and **ignores an unknown `k`**. That is the
extension point: another tool may write its own kinds into the same file (for example a provisioning tool's step events);
Sonar's replay shows only the kinds above, and a tool that wants them shown in the step tree maps them into `state`.

The step tree a page needs is described in the schema (`step`: `id`, `name`, `status`, `start`, `end`, `durationSeconds`,
`errors[]`, `children[]`; `status` is one of `notstarted`, `running`, `success`, `error`, `skipped`, `unknown`).

## The toolkit's feeds in the events folder (input to Sonar)

These are not Sonar's recording format above. They are the files azurelocal-toolkit appends to the one events folder (`deployment.events_directory`, else `%ProgramData%\AzureLocalToolkit\<cluster.name>\events`) and Sonar follows, read only. They share one envelope (`toolkitEvent` in the schema): `timestamp`, `node` (`*` for the run), `stage`, `step`, `state`, `evidence`, `level`, `nextAction`, `runId`, `mode`, `cluster`, then the fields of the event (`exitCode`, `result`, `verdict`, `updateName`, `version`, `applies`, `total`, `blocking`).

| File | Written by | `stage` / `mode` | Sonar shows |
| --- | --- | --- | --- |
| `update-events.jsonl` | `Get-AvailableSolutionUpdate.ps1`; `Start-AzureLocalSolutionUpdate.ps1` | `SolutionUpdate` / `Check`, `WhatIf` or `Install` | The **Update** tile and mode with no Azure: a Check or `-WhatIf` run as *update available / up to date, nothing was installed*, an install as started. [Stages](../stages.md#update). |
| `precluster-plan-events.jsonl` | `Invoke-AzureLocalPreClusterVerification.ps1 -Mode Plan` | `PreClusterVerification` / `Plan` | The **Verification** tile as *Planned*: which checks would run. A plan has **no verdict** and is never shown as Fail. [Verification](../verification.md#the-plan-before-the-gate-has-run). |

`update-events.jsonl`: `RunStarted` (step `Run`), `EnvironmentRead` (step `Environment`), `DiscoveryPolled` (step `Discovery`), one `Update<Next>` (`UpdateStart`, `UpdateFollow`, `UpdateImportSbe`, `UpdateWouldStart`, `UpdateStarted` ...) or `UpdateAttention` line per update (step `Update`, with `updateName` and `version`), `EnvironmentAttention`, then `RunCompleted`, or `RunFailed`, with `exitCode` and, for a Check, `verdict` (`UpToDate`, `UpdateAvailable`, `AdditionalContentRequired`, `UpdateRunning`, `AttentionNeeded`).

`precluster-plan-events.jsonl`: `RunStarted` (step `Run`), one `CategoryPlanned` per category (step `azure`, `identity`, `nodes`, `network`, `storage`, `readiness`; `applies`, `total`, `blocking`), then `RunCompleted` (`exitCode` 0, `result` `Planned`). The gate's own file, `precluster-verification-events.jsonl`, is a different feed (it has `runId`, `seq`, `ts`, `type`, `checkId`, `status` and a verdict) and is described in [Verification](../verification.md).

```json
{"timestamp":"2026-11-24T21:16:07.2388664Z","node":"*","stage":"SolutionUpdate","step":"Run","state":"RunStarted","evidence":"Checking the update state of cluster 'clus01' (read only; nothing is started or changed).","level":"Info","nextAction":"","runId":"df286b74e419","mode":"Check","cluster":"clus01","result":"Running"}
{"timestamp":"2026-11-24T21:16:13.8195578Z","node":"*","stage":"PreClusterVerification","step":"azure","state":"CategoryPlanned","evidence":"23 of 24 checks apply (22 blocking).","level":"Info","nextAction":"","runId":"afe9c07e45d1","mode":"Plan","cluster":"clus01","applies":23,"blocking":22,"total":24}
```

Sonar's tests read the toolkit's real output of both feeds (`tests/fixtures/toolkit-events`) and validate every line against `toolkitEvent`.

## A minimal feed

```json
{"t":"2026-10-11T08:00:00.000Z","k":"session","format":1,"tool":"my-tool","version":"1.0.0","cluster":"clus01","config":{"clusterName":"clus01","nodes":[{"name":"node-01","seed":true}]}}
{"t":"2026-10-11T08:00:01.000Z","k":"state","full":{"cluster":"clus01","phase":"validation","validation":{"status":"running","tree":[{"id":"0","name":"Validate Network","status":"running"}]}}}
{"t":"2026-10-11T08:00:21.000Z","k":"state","ops":[["s",["validation","tree",0,"status"],"success"]]}
{"t":"2026-10-11T08:00:22.000Z","k":"log","lines":[{"seq":1,"time":"2026-10-11T08:00:22.000Z","file":"setup.log","level":"info","text":"hello"}]}
{"t":"2026-10-11T08:00:30.000Z","k":"end"}
```

```powershell
./Start-AzlSonar.ps1 -Replay ./my-feed.jsonl -Autoplay
```

Rules a producer should keep: never rewrite or truncate earlier lines, flush each line, write a keyframe at the start of every
session and again from time to time (a reader seeks by the last keyframe plus its deltas), mask secrets before writing, and use
pseudonyms or [make the file publishable](publishable-recordings.md) before it leaves the machine. Additive changes to the
format (a new optional field, a new kind) do not change `format`; a change that breaks a reader does.

**Not yet:** Sonar reads a feed when it starts a replay. It does not follow a file that is still growing. A tool that wants a
live view runs Sonar's own recorder (below) or restarts the replay.

## Following a run from a pipeline (Trailwright and other automation)

Sonar is a script, so a deployment pipeline can run it beside the deployment and keep the evidence.

```powershell
# 1. start Sonar for the run, recording, without a browser; the page stays available on localhost for whoever is watching
$sonar = Start-Process pwsh -PassThru -ArgumentList @(
    '-NoProfile', '-File', './Start-AzlSonar.ps1',
    '-ConfigPath', './config/clus01.json',
    '-Record', "./recordings/$runId.jsonl", '-Publishable', '-NoBrowser')

# 2. ... start the deployment (Validate, then Deploy) ...

# 3. when the run ends, stop Sonar. Ctrl+C lets it write the end event and run the publishable check; a killed process
#    leaves a recording without an end event (the reader copes) and without the check
Stop-Process -Id $sonar.Id

# 4. check the recording yourself and fail the pipeline unless it is clean, then make the evidence: a timeline JSON and a
#    self-contained HTML report
./scripts/Protect-Recording.ps1 -Path "./recordings/$runId.jsonl" -VerifyOnly
./scripts/Export-SonarBundle.ps1 -Recording "./recordings/$runId.jsonl" -OutDirectory "./artifacts/$runId"
```

- `-Publishable` makes the recording safe to attach to a pipeline run or a ticket; without it the recording keeps the
  identifiers of the cluster. A recording that fails the check is renamed `.NOT-PUBLISHABLE`; the pipeline should fail on that name.
- The exit of Sonar is a stop request, not a result: read the result from the timeline JSON (`summary.phase`, `errors[]`).
- The security model stays as it is: the server listens on `http://localhost:<port>/` only, answers `GET` only, and Sonar
  never writes to Azure or to a node. A pipeline agent that runs Sonar needs the same Azure sign-in (`Connect-AzAccount`) and
  node access a person would.
- An example consumer: `scripts/Export-SonarBundle.ps1` reads any file that follows this contract.

## What Sonar does not promise

- Field names inside `config` and `state` that are not in the schema can change between versions; the schema lists the ones
  the page reads.
- The update, add node and repair tracks (`state.update`, `state.track`) are built from the Microsoft Learn REST reference only
  and are unverified against a live run.
