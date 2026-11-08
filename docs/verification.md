# Pre-cluster verification (the gate)

Before the toolkit submits Validate, its **pre-cluster verification gate** checks that the environment is ready for the cluster: Azure (subscription, resource providers), identity (Active Directory, Key Vault secrets), the nodes (reachable, same OS build), the network, the storage (clean drives) and the readiness of the hardware. It writes three files into its report directory (default `<environment data>/arm-report/verification/live`):

| File | What it is | Sonar |
| --- | --- | --- |
| `precluster-verification-events.jsonl` | One JSON object per line: the run starting, every check as it finishes, the run completing with its verdict. | **Follows it** (local, read-only). |
| `report.json` | The finished report, with the file hash the verdict is for. | Not read. |
| `summary.md` | The same in words, for a person. | Not read. |

Sonar follows the events file and shows it as the **Verification** tile and mode, between **OS configuration** and **Validate**. The mode answers one question: *can the cluster deployment start, and if not, what blocks it?*

## What Sonar shows

- **The tile.** *Pass · 12 checks* (green), *Fail · 2 blocking (1 skipped)* (red), *Running · 5 so far* (blue), *Pass expired* (red). Grey when there is nothing to show; its hover text says how to get the data.
- **The verdict banner.** *Verdict: Pass*, *Fail*, *Running* or *Expired* above the checks. For a Fail it lists the checks that block, first; a Pass whose `expiresUtc` has passed is *Expired* and Validate must wait for a new run of the gate.
- **The counts.** The number of checks per status, failed first: Failed, Skipped, Warning, Passed, Fixed, Not applicable, Running. When the gate's own `counts` differ from the checks Sonar read, the summary says so (a line may be missing from the file).
- **The checks, by category.** Azure, Identity, Nodes, Network, Storage, Readiness; inside a category the failed checks come first. Each check shows its status, the machine it ran on, what was found (`message`), what to do (`remedy`) and the `source` of the rule. A source that is an `https` link to a documentation site (learn.microsoft.com, azurelocal.cloud, github.com) is a link; anything else is shown as text.
- **Skipped is its own state.** A **Skipped** check is not *Not applicable*. It means the gate could not check it, so it cannot pass: it is marked *Skipped: blocks the gate*, counted apart, and keeps the verdict at Fail. A *Not applicable* check is grey and does not block.
- **The log pane.** Each event is a line tagged `[verify]` (file `verification-events`) with the event's own time. A Failed check is an error line; Skipped and Warning are warning lines.

## Which run is shown

The events file can hold more than one run, and the gate may write a new file for each run. Sonar reads the whole file whenever it changes and shows **the latest run only**:

- a new run id starts a new run: the checks of the old one go;
- a late line of an older run (a run id seen before, or an unseen one that started before the current run) is ignored and counted, never shown as the current run (*Ignored 2 lines of an older run* appears in the notes);
- one row per check and machine: the line with the highest `seq` wins, so a repeated or older line does not undo a newer result;
- a half-written last line is skipped until the gate finishes writing it; garbage lines are skipped;
- a run with no `RunCompleted` line is **Running**;
- a file that is missing, empty or not there yet is *waiting*, never an error.

Sonar never shows green by accident. If the gate wrote `verdict: Pass` but a check in the same run is Failed (and blocking) or Skipped, Sonar shows **Fail** and says why in the notes: the checks win over the verdict.

## The states

| State | Tile | What it means |
| --- | --- | --- |
| No file, or no event yet | grey, no line | The gate has not run (or Sonar cannot see its folder). |
| Running | blue, *Running · N so far* | The gate is working; checks arrive as they finish. |
| Pass | green, *Pass · N checks* | Every blocking check passed, was fixed or does not apply. Warnings do not block. |
| Fail | red, *Fail · N blocking* | At least one check blocks. The banner lists them; each carries its remedy. |
| Expired | red, *Pass expired* | The pass is older than its `expiresUtc`. Run the gate again before Validate. |

## Prerequisites

1. **The gate has run** (or is running) from the toolkit and wrote `precluster-verification-events.jsonl`. Sonar does not run the gate and never changes anything it checks.
2. **Sonar can read the report directory.** The file is local to the machine that runs the gate; start Sonar on that machine, or point `verificationEventsPath` at a share or a synced copy. Sonar opens it read-only, shared with the writer.
3. **Sonar knows where the file is.** With the master file (`-InfrastructureFile`) Sonar follows `<evidence folder>/arm-report/verification/live/precluster-verification-events.jsonl`, where the evidence folder is `provisioning.simplified.evidence_path` (without one: `<temp>/azl-arm-<cluster.name>/arm-report/verification/live`). With a config file, or when the gate was given another report directory, set [`verificationEventsPath`](./config.md) to the file or to the folder that holds it:

   ```powershell
   Set-AzlSonarConfig -Path ./config/clus01.json -Key verificationEventsPath -Value 'D:\Data\arm-report\verification\live'
   ```

4. **PowerShell 7.4 or later** for Sonar. No extra module for this mode.
5. **No Azure sign-in and no node access** for `-Monitor Verification`. In the whole flow (`Auto`) Sonar signs in to Azure as it does for the other modes; the Verification mode itself reads only the file.

The variable is registered first in the toolkit's variables registry (`tools.sonar.config_keys.Config.verificationEventsPath`), as every Sonar configuration key must be.

## How to run Sonar for it

The whole flow (Verification is a tile between OS configuration and Validate, and becomes the mode to watch once OS configuration has finished and the gate has written an event):

```powershell
Connect-AzAccount -Tenant <tenant-id>
./Start-AzlSonar.ps1 -InfrastructureFile ./infrastructure.yml
```

The gate alone, with no Azure sign-in:

```powershell
./Start-AzlSonar.ps1 -InfrastructureFile ./infrastructure.yml -Monitor Verification
```

or with a config file that has `verificationEventsPath` (`Set-AzlSonarConfig -Key monitor -Value Verification`). See [Run one stage on its own](./run.md).

## The event contract

One JSON object per line (JSON Lines), schema 1. Sonar reads the fields it knows and ignores the rest, so the gate can add fields.

| Field | On | Meaning |
| --- | --- | --- |
| `schema` | every line | `1`. A newer value is read by the fields Sonar knows, with a note. |
| `runId` | every line | The run. Required. |
| `seq` | every line | Number of the line within the run; the highest `seq` of a check wins. |
| `ts` | every line | UTC time (ISO 8601). |
| `type` | every line | `RunStarted`, `Check` or `RunCompleted`. |
| `checkId` | Check | Stable id of the check. With `node` it names the row. |
| `category` | Check | `azure`, `identity`, `nodes`, `network`, `storage` or `readiness`. |
| `title`, `message`, `remedy`, `source` | Check | What it checks, what was found, what to do, where the rule comes from. Masked again by Sonar. |
| `status` | Check | `Passed`, `Failed`, `Warning`, `Skipped`, `NotApplicable`, `Fixed` or `Running`. |
| `node` | Check | The machine; empty for a check of the whole environment. |
| `blocking` | Check | Whether a failure stops the cluster deployment. A Skipped check blocks whatever this says. |
| `verdict`, `counts`, `fileHash`, `expiresUtc` | RunCompleted | `Pass` or `Fail`; the checks by status; the hash of the infrastructure file the verdict is for; when the verdict stops being valid. |

## What Sonar does not do

- It never runs, fixes or re-runs a check, and never changes a node, Azure or Active Directory.
- It does not decide the verdict: it shows the gate's, except that it never shows a Pass next to a blocking check.
- It does not read `report.json` or `summary.md`, and does not compare `fileHash` with the infrastructure file.
- **Unverified against a live gate run.** This mode is built to the contract above and tested with fixtures written to it; the first run against the real gate may need the field names or the default folder adjusted.
