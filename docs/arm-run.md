# Validate and Deploy from the toolkit (ARM run)

The toolkit's `Invoke-AzureLocalArmDeployment.ps1` checks that the instance is ready, generates the ARM parameters, submits **Validate**, waits for it, asks for approval, submits **Deploy** and waits for that too. While it runs it appends what it does to an event file, `arm-deployment-events.jsonl`. Sonar follows that file (local, read-only) and shows it inside the **Validate** and **Deployment** modes, next to the steps Azure reports itself.

Azure's own step list only exists once a deployment is submitted. The event file covers the part Azure cannot show: the checks before the submit, a run that was refused, the toolkit's words for a failure, and the elapsed time of the run.

## What Sonar shows

- **The Validate and Deployment tiles.** While Azure has no steps of its own for the mode, the tile follows the toolkit's run: *Checking*, *2 checks failed*, *Step 0.4 · 3m 10s*, *Passed*, *Failed at 0.41.2*, *Timed out*, *Not started* (the toolkit refused the phase) and, for a Plan that found nothing wrong, a grey *Plan ready*. Once Azure reports steps for the mode, Azure's status drives the tile, as before. The page moves to **Validate** or **Deployment** by itself when the run is ahead of Azure (for example when a check failed and nothing was submitted); a Plan alone never moves it.
- **The summary box.** One sentence about the phase, then facts: the toolkit run (mode and state), the checks (*15 passed, 2 failed, 1 with a warning*), the steps reported, the elapsed time, the template and parameter hash, whether the validation was skipped because it already passed with these parameters, whether a Deploy was resumed, whether the run waits for approval, the known failure, and the next action the toolkit gives.
- **The Steps box.** For Validate: *Toolkit run: checks and validation results*. The checks come first, failures first, then warnings, skipped and passed; each failed check carries its text and the toolkit's next action. Under them, the validation results with the steps in error (or with an error below them) first. For Deployment: *Toolkit run: checks and deployment progress*, with the checks (the toolkit repeats them before a Deploy) and the deployment steps in the order Azure reports them, nested by depth, each with its status, start, end and duration. Step numbers are the portal's (for example `0.41`). Azure's own list follows under *Validation steps reported by Azure* or *Deployment steps reported by Azure*.
- **Known failures.** When the run matched a failure to the toolkit's known-issues list, the failing step carries a hint with the title and the cause, and the same hint shows under the header. The hint for step 0.41 is the device-ID Arc name problem: simplified provisioning names each Arc machine `<device-id>-1`, on build 2690 the Arc infrastructure step looks it up by the host name and stops with `ParentResourceNotFound`. Validate passes and Deploy fails; resubmitting does not fix it. The full remediation is the run's next action (shown in the facts). A check named `ArcMachineNaming` that warns shows the same problem as a heads-up *before* the Deploy.
- **The Details panel.** *ARM run events* under Sources (events read, the newest one, whether the file exists yet) and an *ARM Validate and Deploy* group with the run, the template and parameter hash, the state of each phase and the known failure.
- **The log pane.** Each event is a line tagged `[arm]` (file `arm-events`), with the event's own time.

## The states

| State | Tile | What it means |
| --- | --- | --- |
| No file, or the file has no event yet | grey, no line | Waiting for a run. The hover text says how to get the data. |
| Checking | blue, *Checking* | The toolkit is running its read-only checks. |
| Plan ready | grey, *Plan ready* | A Plan found nothing wrong and submitted nothing. |
| Blocked | red, *N checks failed* | A check failed; nothing was submitted. The failed checks and their next actions are first in the Steps box. |
| Validating / Deploying | blue, *Step X · elapsed* | Azure is working; the steps arrive as the toolkit reads them. |
| Passed / Done | green | Validation passed (or was already passed), or the deployment succeeded. |
| Waiting for approval | the summary says so | The validation passed and the approval mode is `stop`; run Mode Deploy to go on. |
| Failed | red, *Failed at step* | The failing step, the known failure if there is one, and the next action. |
| Timed out | red | The toolkit stopped waiting; Azure keeps working. Run the same command again to attach. |
| Not started | red | The toolkit refused the phase (for example a Deploy of a failed instance without `-Resume`). The earlier failure stays in view. |

## How to run Sonar for it

Start the toolkit run with a report directory you can reach, and point Sonar at its event file.

```powershell
Connect-AzAccount -Tenant <tenant-id>
./Start-AzlSonar.ps1 -InfrastructureFile ./infrastructure.yml
```

With the master file, Sonar follows the toolkit's default: `arm-deployment-events.jsonl` in `<temp>/azl-arm-<cluster.name>/`. If the toolkit run was given `-ReportDirectory`, or you use a config file, set [`armEventsPath`](./config.md) (`Set-AzlSonarConfig -Key armEventsPath -Value <file>`). Sonar tails the file every 2 seconds. Start Sonar on the machine that runs the toolkit, or where the report directory is shared. The file may not exist yet; Sonar waits for it.

## What Sonar does not do

- It never submits, resumes or cancels anything. It reads the event file and the Azure status it already read.
- It never uses the LCM account for the toolkit run or for the logs. The domain account that reads node logs is the one described in [Log access](./log-access.md), unchanged. The optional update account, supplied by you, reads only the cluster's update service (see [updateAccount](./config.md#updateaccount-the-clusters-own-update-service)).
- The event file holds references and names only; Sonar masks anything that looks like a secret before it stores or serves a line.
- The event file contract is the toolkit's (`docs/design/arm-validate-deploy.md`, section 11). The step numbers and times the toolkit reports come from `deploymentSettings`; whether the real payload carries them as assumed is not verified here.

See also [Running Sonar, stage by stage](./stages.md#validate-and-deployment-the-toolkit-run) and the demo (`?demo=1&route=arm`).
