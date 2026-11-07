# Following a zero-touch provisioning run

> What Sonar reads while [azurelocal-ztp](https://github.com/AzureLocal/azurelocal-ztp) provisions machines with Microsoft's simplified machine provisioning (preview), how it decides that a machine is running, ready or failed, and how to start it for a ZTP run.

A ZTP run takes bare machines to "ready for OS configuration". It boots each machine from a virtual USB over its BMC, reads the ownership voucher back, sets the management address in the maintenance environment, claims the machine in Azure as an edge machine, and waits for the OS install. Then it moves the management address to the management NIC and puts back the final BIOS values. OS configuration (drivers, `C:\SBE`, DHCP off, DNS, time, the deployment admin) follows. Validate comes after that. Sonar follows two sources at once during that time: the event file the ZTP scripts write, and the edge machines in Azure. Once the cluster exists, it follows Validate and Deploy as usual.

Each ZTP stage on its own, with how to run Sonar for it and what done and failed look like, is on [Running Sonar, stage by stage](./stages.md). The ZTP side, with what each ZTP stage checks, is in the ZTP docs: [Monitoring a run](https://azurelocal.cloud/azurelocal-ztp/monitoring). The full state contract is in [design.md](./design.md).

## What Sonar reads

| Worker | What it reads | How | How often |
| --- | --- | --- | --- |
| Azure poller | The deployment, the edge machines and their `ProvisionOs` job, the Arc machine of every node | Read-only ARM GETs through `Invoke-AzRestMethod` under your Az PowerShell sign-in | Every `pollSeconds` (default 20) |
| ZTP event worker | The ZTP event file named in `ztpEvents.path` | Reads the file on this machine, shared with the writer | Every 2 seconds |
| Log tailer | The deployment logs on the seed node | WinRM or SSH, as for any deployment | Every `logs.pollSeconds` |
| Node probe | Not used | Not started when `provisioningRoute` is `simplified`. It reads Arc registration status on the nodes, which is the OEM image route only. | |

### The Azure poller

Each poll makes these GETs. A 404 or 400 on the edge machine calls means "nothing yet" and isn't an error.

| Call | api-version | What Sonar takes from it |
| --- | --- | --- |
| `.../providers/Microsoft.AzureStackHCI/clusters/<clusterName>/deploymentSettings/default` | `apiVersion`, default `2026-10-01`; `apiVersionFallback` (`2025-10-01`) is tried once if Azure rejects the version | The validation and deployment step trees. A 404 means the cluster isn't there yet: during provisioning, that's expected. |
| `.../providers/Microsoft.AzureStackHCI/edgeMachines` (the list in the resource group) | `edgeApiVersion`, default `2026-10-01` | Each edge machine: name, host name, lifecycle status and message, lifecycle stages, `provisioningState`, `machineState`, `connectivityStatus`, `arcMachineResourceId`, the extensions it reports |
| `<edge machine id>/jobs/ProvisionOs` | `edgeApiVersion` | The job's status, provisioning state, start and end, `error`, `percentComplete`, and its validation and deployment steps. Before the job exists, `operationDetails` entry `ProvisionOs` on the edge machine stands in. |
| `<Arc machine id>` (`Microsoft.HybridCompute/machines`) | `2026-07-15` | Arc status, last status change, agent version, creation time |
| `.../providers/Microsoft.Resources/deployments/?$filter=provisioningState eq 'Running'` | `2021-04-01` | While the deployment hasn't succeeded: the newest running ARM deployment, used to say that Azure lags behind the node |

The poller skips the edge machine calls only when `provisioningRoute` is `oem-image`.

### The ZTP event worker

The ZTP scripts append one JSON object per line: `timestamp`, `node`, `state`, `evidence`, `nextAction`, `level`, `stage`. Every 2 seconds the worker reads the complete lines added since its last read:

- It opens the file read-only and shares it for reading, writing and deleting, so the writer is never blocked.
- A half-written last line is left for the next read.
- A file that got smaller (replaced or truncated) is read again from the start. A missing file gives no lines until it appears.
- A line that isn't a JSON object with `node` and `state` is skipped.

Each event becomes a log line in the log pane, from the file `ztp-events`:

```text
2026-11-05T14:24:41.900Z [ztp] node-01 ReadyForPortal: valid voucher in hand and Azure prerequisites verified; voucher SHA256 <hash> -> next: Collect the voucher (Wait-ZtpVoucher.ps1), then create the site and edge machine (Invoke-ZtpAzureProvisioning.ps1).
```

The line starts with the event's own UTC time, so the log pane orders it by event time. An event with level `Error` or `Warning` ends with `(error)` or `(warning)` when its text has no such word, so the pane colours it. The worker reads the whole file the first time, so it shows the events of earlier runs in the same file too, each at its own time.

The event file covers the ZTP stages before Azure knows the machines: the boot from the virtual USB and the voucher (`Mounted`, `Booting`, `MaintenanceEnvironmentRunning`, `VoucherWritten`, `ReadyForPortal`, and the failure states), plus `StageStarted`, `StageCompleted` and `StageFailed` for every ZTP stage (Resolve, Media, Boot, Bootstrap, Vouchers, Device, Azure, Ready, Network, Restore, Handoff). Sonar doesn't interpret these states: they are log lines. The per-node Device, Network and Restore events are the exception: they become steps, as the next section describes.

### The per-node ZTP steps: management address and BIOS

Three ZTP stages work on each machine, and their events become steps in that machine's tree. Each event is a child step; the last one runs until the next event arrives. The ZTP run ends with these stages: Handoff, after them, only writes files.

| Step | ZTP stage (`stage`) | Where it sits | What it does |
| --- | --- | --- | --- |
| **Management address (maintenance environment)** | `Device`, `Set-ZtpDeviceConfiguration.ps1` | First, before the lifecycle stages. Shown before the edge machine exists, too. | Before the Azure claim, in the maintenance environment, through the Configurator service on port 20001: sets the static management address on the port with the management MAC. It sends no host name: the Azure claim sets the host name (see [the ZTP Configurator app reference](https://github.com/AzureLocal/azurelocal-ztp/blob/main/docs/appendix/configurator-app-api.md#the-host-name-and-the-arc-resource-name)). |
| **Management address on the management NIC** | `Network`, `Set-ZtpManagementAddress.ps1` | After the `ProvisionOs` job | After the OS install, through the edge machine's per-NIC API (`networkAdapters`, `jobs/ApplyConfiguration`): moves the management address to the adapter with the management MAC, after releasing it from any other adapter. |
| **BIOS restored** | `Restore` | Last | Where ZTP set temporary BIOS values for the install (for example, the FC HBA off), it puts back the final ones: a Redfish PATCH, a restart, then a wait until Arc reconnects. |

| Step | Succeeded | Failed | Running |
| --- | --- | --- | --- |
| Device | `DeviceAddressSet`, `DeviceAddressAlreadySet`, `DeviceAddressReported` (DHCP, DHCP reservation or preconfigured: reported, not changed), `DeviceConfigurationSkipped` (no maintenance address; Network sets the address later) | `DeviceConfigurationFailed` | `DeviceConfigurationSubmitted`, `DeviceConfigurationStatus` |
| Network | `ManagementAddressSet`, `ManagementAddressAlreadySet`, `ManagementAddressReported`, `ManagementAddressDeferredToOsConfiguration` (ZTP verified the port; a static address the install reset to DHCP is set by OS configuration) | `ManagementAddressFailed` | `NetworkJobSubmitted`, `NetworkJobStatus`, `ManagementAddressReleased` |
| Restore | `BiosRestored` | `BiosRestoreFailed` | `BiosRestoreStarted` |

With no events, a step is **not started**. Only a failed state is an error. Sonar never reads one from the evidence text, so a Network job that waits with "Job is not yet triggered as other jobs are still running" shows as running.

A run with no temporary BIOS values writes no Restore event. Once the Restore stage is over (the orchestrator's `StageCompleted` for `Restore`, or any `Handoff` event), a machine with no Restore events shows the step as **skipped** (not applicable) instead of waiting.

The ZTP event worker keeps each machine's latest attempt of each stage. An event after a finished attempt (succeeded or failed) starts a new attempt. The orchestrator's `StageStarted` for a stage clears that stage on every machine, so a rerun replaces the earlier attempt.

When the config has `ztpEvents.path`:

- A machine that Azure reports Provisioned stays **running**, at 95%, until its Network step succeeds and its Restore step succeeds or is not applicable. Then it's done (`ztp.complete` on the machine).
- A failed Device, Network or Restore step makes the machine an error, with the reason in its errors.
- `provisioning.ztpComplete` is true when every machine is done. The phase chip then reads **ZTP complete**, and the status reads "ZTP complete: 2 of 2 machines provisioned. OS configuration next". A note under the header links the OS configuration guide named in `provisioning.nextStep` ([azurelocal.cloud](https://azurelocal.cloud)).
- `provisioning.readyForValidate` stays false on this route. After ZTP comes **OS configuration**, not Validate: the OEM drivers, `C:\SBE`, DHCP off, DNS and time, and the deployment admin (azurelocal-toolkit Phase 03). Validate follows that.

Without `ztpEvents.path`, a Provisioned machine is done, as before, and none of these steps is shown.

Event files from older ZTP runs can hold `Prepare` events (`PrepareStarted` … `ReadyForValidate`). ZTP no longer has that stage, and Sonar now shows those events only as log lines.
## How Sonar maps machines

On the simplified route, three names belong to one machine:

| Name | Where it comes from |
| --- | --- |
| Host name | `nodes[].name` in the config. ZTP names each edge machine after its node. |
| Edge machine | `Microsoft.AzureStackHCI/edgeMachines/<name>` in the config's resource group |
| Arc machine | Named by the service `<device-id>-1`, in the site configuration's managed resource group |

An edge machine maps to a configured node when one of these matches the node's `name`:

1. the edge machine's name;
2. its host name: `siteDetails.deviceConfiguration.hostName`, or else the job's `provisioningRequest.deviceConfiguration.hostName`;
3. its Arc machine name, but only against an explicit `nodes[].arcMachineName`.

The Arc machine Sonar reads for a node is, in this order:

| Source (`arcSource`) | Arc machine |
| --- | --- |
| `config` | `nodes[].arcMachineName`, when you set it |
| `edgeMachine.job` | The `ProvisionOs` job's target, `provisioningRequest.onboardingConfiguration.resourceId`: the `<device-id>-1` machine |
| `edgeMachine` | The edge machine's `properties.arcMachineResourceId`. While the OS installs, this can be the maintenance environment's Arc machine. |
| `nodeName` | No edge machine yet: the node name in the config's resource group |

Leave `arcMachineName` out of the config for a ZTP run. Sonar reads the `<device-id>-1` name from Azure. An ID read from Azure is used only when it has the form `/subscriptions/*/resourceGroups/*/providers/Microsoft.HybridCompute/machines/*`.

## How Sonar decides running, success or failure

For each node, from its edge machine and its job:

| Status | When |
| --- | --- |
| Not started | No edge machine for the node yet. The lifecycle reads `NotCreated`: "No edge machine for this node in the resource group yet." |
| Failed | A ZTP Device, Network or Restore step failed (with `ztpEvents.path`); the lifecycle status contains `Fail`; the edge machine's `provisioningState` or `machineState` is `Failed`; the job's `provisioningState` is `Failed`; the job's status maps to failed; or any lifecycle stage, sub-stage or job step is in error. The job's `error` counts only while the job itself reports failure. |
| Succeeded | The lifecycle is `Provisioned` and the job succeeded (`DeploymentSuccess`), or there's no job to read. With `ztpEvents.path`, the Network step must have succeeded too, and the Restore step must have succeeded or be not applicable. |
| Running | Anything else |

**`previousErrors`.** After a `ProvisionOs` job is resubmitted, Azure keeps the earlier attempt's error in the job's `properties.error`, while the new attempt runs and after it succeeds. Sonar treats that error as current only while the job reports failure: its `provisioningState` is `Failed`, or its status maps to failed. Otherwise the error goes into the node's `previousErrors` as "ProvisionOs, earlier attempt (the job was resubmitted): `<error>`", and the node stays running. `previousErrors` is in `/api/state`, the export and a recording. The page doesn't draw it.

On the live ZTP runs (two Dell AX-760 nodes, iDRAC 7.30, build `12.2690.1003.15`), each node's first install attempt failed at the step `SetupHybridComputeRP` with error 5901, and ZTP's single automatic resubmit passed it in about 2 minutes. By the rules above, the node shows as failed while the job reports the failure, until the resubmitted job starts. After that the 5901 error is in `previousErrors`, and the node is running again.

**The progress bar** is Sonar's estimate: `Creating` 0, `AwaitingConnection` 5, `Provisioning` 15, `ReadyForOs` 25, `InstallingOs` 25 plus 70 times the share of finished job steps (at most 95), `Provisioned` 100. With `ztpEvents.path`, a Provisioned machine stays at 95 until it is ZTP-complete. The job's own `percentComplete` is kept as `reportedPercent` but not drawn: recorded responses showed 50 both mid-run and after success.

**The phase.** The machines roll up: failed if any node failed, succeeded when all did, running when any runs or is done. The phase is **Provisioning** until Azure reports validation steps for the cluster, then **Validation**, then **Deployment**, then **Done**. A failure in the active phase shows as **Failed:** and the phase.

## Config keys for a ZTP run

| Key | Value |
| --- | --- |
| `subscriptionId`, `resourceGroup` | The subscription and resource group of the edge machines |
| `clusterName` | The cluster you will deploy. Sonar reads `clusters/<clusterName>/deploymentSettings/default` in the same resource group, so this name decides whether it follows Validate and Deploy. |
| `identityModel` | `LocalIdentity` or `ActiveDirectory` (required) |
| `provisioningRoute` | `simplified`. With `auto`, Sonar picks simplified only once an edge machine maps to a configured node, and the node probe is started. |
| `nodes[]` | `name` (the host name), `address` (the management address, for the logs later), one `seed: true`. No `arcMachineName`. |
| `ztpEvents.path` | The ZTP event file. A relative path is relative to the config file. |
| `pollSeconds` | Azure poll interval, 5 to 3600, default 20 |
| `edgeApiVersion` | Default `2026-10-01` |
| `credential` | `prompt`, `parameter` or `keyvault` with `vault`, `usernameSecret`, `passwordSecret`. Never a password. |
| `recordPath` | Optional; see [Recording](#recording) |

```json
{
  "subscriptionId": "00000000-0000-0000-0000-000000000000",
  "resourceGroup": "rg-example-azl",
  "clusterName": "clus01",
  "identityModel": "LocalIdentity",
  "provisioningRoute": "simplified",
  "pollSeconds": 20,
  "nodes": [
    { "name": "node-01", "address": "192.0.2.11", "seed": true },
    { "name": "node-02", "address": "192.0.2.12" }
  ],
  "ztpEvents": { "path": "D:\\azurelocal-ztp\\_media\\ztp-state\\ztp-events.jsonl" },
  "credential": { "source": "prompt" }
}
```

A ZTP run started with its environment file writes the event file to `_media\ztp-state\ztp-events.jsonl` at the root of the ZTP clone.

## Start it

You need PowerShell 7.4 or later, Az.Accounts signed in with `Connect-AzAccount`, and read access to the resource group of the edge machines and to the managed resource group that holds their Arc machines. Reader on the subscription covers both. See [Getting started](./getting-started.md) for the rest.

### From ZTP: `Start-ZtpMonitor.ps1`

The ZTP repository's `scripts/simplified-provisioning/Start-ZtpMonitor.ps1` writes the config from its node list and starts Sonar. Without `-Execute` it prints the config and the command only.

```powershell
Connect-AzAccount -Tenant <tenant-id>
./scripts/simplified-provisioning/Start-ZtpMonitor.ps1 -SonarPath D:\git\azurelocal-sonar `
    -SubscriptionId <subscription-id> -ResourceGroupName <resource-group> `
    -NodesFile ./config/simplified-provisioning/nodes.json `
    -EventLogPath ./_media/ztp-state/ztp-events.jsonl -ClusterName <cluster-name> -Execute
```

It writes `provisioningRoute: simplified`, `pollSeconds: 20`, `credential.source: prompt`, the first node as the seed, and each node's `management_ip` (or its `bmc_address`) as the address. Its other parameters are `-NodeName`, `-IdentityModel` (default `ActiveDirectory`), `-SonarConfigPath` (default `./ztp-sonar.config.json`), `-Port`, `-NoBrowser` and `-Record`. Its `-ClusterName` defaults to `ztp-provisioning`; pass the real cluster name so Sonar follows Validate and Deploy.

### Directly

```powershell
Connect-AzAccount -Tenant <tenant-id>
./Start-AzlSonar.ps1 -ConfigPath ./config/ztp.json
```

Sonar asks once for the account that reads the seed node's logs (`credential.source: prompt`). During provisioning there are no logs to read on the node; cancel and Sonar uses your Windows identity. For Validate and Deploy, give an account that can read the node logs: see [Which account](./getting-started.md#which-account).

## What the page shows

Open `http://localhost:8642/` (or the `-Port` you chose).

| Part | During a ZTP run |
| --- | --- |
| Top bar | The cluster name, a status chip (*Running*, *Done*, *Failed*), the elapsed time and "updated N s ago". The **Provisioning (ZTP)** tile reads *2 of 3 machines ready*, then *ZTP complete*. **Details** lists the nodes, the ZTP event file with its event count and last event, and what Sonar read from the config. |
| Summary and steps | A card per node (full name, plain-word state with Azure's value in the tooltip, Arc connection, progress bar, what it waits on or *Next: OS configuration*), and in the Steps box one group per node. Expanded: with `ztpEvents.path` first **Management address (maintenance environment)**, then the lifecycle stages and sub-stages, a **ProvisionOs job** item with the job's steps, then **Management address on the management NIC** and **BIOS restored**, with live timers and errors inline. Azure steps carry an **Azure** badge and show their details when clicked; the ZTP stages filter the logs to their event lines. |
| Live logs | The `[ztp]` event lines, ordered by their time, coloured by level. Choose `ztp-events` in the file filter to see only them. The seed node's logs join them once the node answers. |
| Steps | Validation and deployment, once Azure reports them |
| Log access | The account, folders and timing for each phase |

## Recording

Recording is off by default. Sonar records only with `-Record <file>` or `recordPath` in the config, and `Start-ZtpMonitor.ps1 -Record <file>` passes the file on. The ZTP events are recorded like any other log line, so a replay shows them in place. A recording masks secrets but keeps identifiers. To share one, record into a new file with `-Publishable` (start Sonar directly for that; `Start-ZtpMonitor.ps1` doesn't pass it), or rewrite it later: see [Publishable recordings](reference/publishable-recordings.md).

## Read-only

Sonar never resubmits a job or changes Azure, the event file or the nodes. ZTP does the single `ProvisionOs` resubmit itself. Sonar only reports what it reads.
