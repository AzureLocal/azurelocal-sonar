# How it works

Sonar has three parts, all started by one script (`Start-AzlSonar.ps1`) in one PowerShell 7 process. The full contract is in [design.md](./design.md).

| Part | What it does | Source |
| --- | --- | --- |
| Azure poller | Every `pollSeconds` (20 s): reads the deployment's step trees (validation and deployment) from `deploymentSettings/default`, the edge machines of the resource group with their `ProvisionOs` job (simplified machine provisioning), the Arc machine of every node and, on the OEM image route once a validation exists, each Arc machine's mandatory extensions | Azure Resource Manager GETs through the signed-in Az PowerShell context, the same resources the portal reads |
| Log tailer | Follows the deployment log files on the seed node as they grow | One read-only script per poll over PowerShell remoting (WinRM), or over SSH with Posh-SSH when WinRM is blocked |
| Web view | Step tree, live log stream with filters, phase and node status, log access guidance, export | Static page served from `http://localhost:<port>/`, live updates over Server-Sent Events, polling fallback |

## Phases Sonar follows

1. **Provisioning** or **Arc registration**: before any validation step is reported, how each machine gets ready. Sonar follows both routes (`provisioningRoute`, `auto` by default):
   - **Simplified machine provisioning** (preview, phase *Provisioning*): each machine is an edge machine. Sonar shows its lifecycle (`Creating` → `AwaitingConnection` → `Provisioning` → `ReadyForOs` → `InstallingOs` → `Provisioned`), the lifecycle stages, and the `ProvisionOs` job's steps with their errors (for example `InstallExtensions` failing because an extension could not be downloaded). The Arc machine is named after the device (`<device-id>-1`); Sonar reads the name from the edge machine, so the config does not need it.
   - **OEM image + Arc registration** (phase *Arc registration*): no edge machines. The node is registered with `Invoke-AzStackHciArcInitialization` and its Arc machine carries the host name. Sonar shows what the registration does, per machine: the **OS image update** (zero-day solution update, only when the OEM image is not the latest: Scan, Download, Install; 40-45 minutes, then a reboot) and the **Bootstrap** (NetworkConfig ... ArcConfiguration > ArcRegistration, ArcExtensionInstall), both read on the node with `Get-ArcZeroDaySolutionUpdateStatus` and `Get-ArcBootstrapStatus` by the node probe, and the **Azure registration** (the Arc machine appears and turns `Connected`). A node that reboots shows *Rebooting / unreachable since*; when every machine is registered the status reads *Ready for Validate*. The four mandatory extensions (`AzureEdgeDeviceManagement`, `AzureEdgeLifecycleManager`, `AzureEdgeRemoteSupport`, `AzureEdgeTelemetryAndDiagnostics`) install during Validate, so they appear only then, in their own *Extensions (installed during Validate)* group.

   The panel collapses once validation starts and can be opened again.
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

**Export** downloads one JSON bundle: the config (no secrets), the guidance, the latest state, the change-only state timeline (a snapshot only when something changed, at most 5000; the latest state is always included) and the log lines, with metadata that says how many snapshots and lines the caps dropped.

## Read-only

Sonar only reads. It never starts, retries or cancels a deployment, never writes to Azure (no Arc run command, no Arc SSH), never writes to a node, and never changes the workstation's `TrustedHosts`. The page is served to this machine only, and secrets are masked in everything it shows or exports.
