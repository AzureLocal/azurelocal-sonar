# Running Sonar, stage by stage

Sonar follows a zero-touch provisioning (ZTP) run one stage at a time. This page goes through the stages in the order [azurelocal-ztp](https://github.com/AzureLocal/azurelocal-ztp) runs them: what the stage does, **how to run Sonar for it**, what Sonar shows, what done and failed look like, and the access it needs. The stages after ZTP (OS configuration, Validate, Deployment, Update) are at the end, and the modes of the **Log access** window have [their own page](./log-access.md).

Sonar only reads. It never starts, retries or repairs a stage: ZTP does that. If you only want the commands per purpose, see [Running Sonar, by purpose](./run.md); how the ZTP event file and the edge machines are read is in [Following a ZTP run](./ztp.md).

## One command for every ZTP stage

You do not start Sonar differently for each stage. One Sonar follows the whole run, so start it once, before or during the run, and leave it open:

```powershell
Connect-AzAccount -Tenant <tenant-id>
./Start-AzlSonar.ps1 -InfrastructureFile ./infrastructure.yml          # master file, scenario.os_install: simplified
# or, with a config file:
./Start-AzlSonar.ps1 -ConfigPath ./config/clus01.json                  # provisioningRoute: simplified, ztpEvents.path set
```

Sonar reads two sources at once (see [What Sonar reads](./ztp.md#what-sonar-reads)): the **ZTP event file** (`ztp-events.jsonl`, every 2 seconds) and **Azure** (the edge machines, every `pollSeconds`). Which stage you are in decides which of the two has anything to show:

| Stage | Where Sonar sees it | What you can follow |
| --- | --- | --- |
| Resolve, Media | Event file (stage events only) | Log lines `StageStarted` / `StageCompleted` |
| Boot, Bootstrap, Vouchers | Event file | Per-machine log lines (`Mounted`, `Booting`, `VoucherWritten`, `ReadyForPortal` ...) |
| Device | Event file | A per-machine **step** and its log lines |
| Azure (claim), Ready (Install OS) | Azure (edge machines) | The machine card, the lifecycle stages and the `ProvisionOs` job as steps with **Azure** badges |
| Network | Event file and Azure | A per-machine **step** and its log lines |
| Restore | Event file and Azure | A per-machine **step** and its log lines |
| Handoff | Event file (stage events only) | Log lines; the cards read **ZTP complete** |

Start Sonar on the machine where ZTP runs (or one that can read the event file's folder). The path comes from `provisioning.simplified.evidence_path` in the master file or `ztpEvents.path` in a config file. Sonar reads the whole file when it starts, so it is safe to start Sonar late: every earlier event is shown at its own time.

**Access for all of the ZTP stages:** Reader on the resource group of the edge machines and on the managed resource group that holds their Arc machines (Reader on the subscription covers both); `Az.Accounts` signed in; read access to the event file's folder. No access to the machines is needed: when Sonar asks for the log account, cancel the prompt. There are no node logs to read yet.

The screens below use the page's own demo data (`?demo=1&route=simplified`); see the [tour](./tour.md) for each part of the page.

## Resolve and Media

**ZTP does:** Resolve finds and verifies the maintenance ISO (its version, URL and SHA-256 go in the stage's evidence). Media builds one virtual USB image per node.

**In Sonar:** two log lines each, from the file `ztp-events`: `StageStarted` and `StageCompleted` with ZTP's own evidence text. The machine cards still read *Waiting to start*. Nothing here is a step.

**Done:** the `StageCompleted` line for Resolve and for Media. **Failed:** a `StageFailed` line (level Error) with the error text. Fix it on the ZTP side and run the stage again (`-Stage Media`); Sonar shows the new attempt as more lines.

## Boot

**ZTP does:** sets the node's temporary BIOS values (for example a Fibre Channel HBA off), attaches the node's image to its BMC's virtual media, sets a one-time boot from it and restarts the node. It saves each BIOS attribute's original value, which Restore puts back later.

**In Sonar:** log lines per machine: `BiosChanged` (with each attribute), then, as ZTP's next stage begins to watch, `Mounted` and `Booting`. The card still reads *Waiting to start*: Azure does not know the machine yet.

**Done:** `StageCompleted` for Boot, the nodes show `Mounted` / `Booting`. **Stuck:** a warning line `... no change for 20 minutes` on the current state; `MediaRejected` (error) when the image is not inserted after 3 minutes or is write protected. Check the BMC and the image, then rerun `-Stage Boot`.

## Bootstrap

**ZTP does:** waits for each node to run its maintenance environment and write the ownership voucher back into its image. It reads the BMC (virtual media, power state, log entries) and the image; none of it needs a credential on the node.

**In Sonar:** the node's progress as log lines, in order: `NotStarted`, `Mounted`, `Booting`, `MaintenanceEnvironmentRunning`, `VoucherWritten`, `ReadyForPortal` (a valid voucher in hand and Azure ready to claim it). Choose `ztp-events` in the **file** filter to see only these lines; click a machine's card to see only that machine's.

**Done:** `ReadyForPortal` for every node. **Failed:** `VoucherMissing` (no valid voucher in 90 minutes) or `Failed` (the 120-minute budget ran out), both level Error and shown in red. **Warnings** (amber): no change for 20 minutes; a voucher in an image that this run did not build (the evidence says which).

## Vouchers (and the claim)

**ZTP does:** the Vouchers stage ejects the image, reads the voucher from it exclusively and writes `<media_path>/vouchers/<serial>.pem` for each node. The next stage, **Azure**, **claims** each machine: it submits the voucher to Azure, which creates the site and the edge machine.

**In Sonar:** the Vouchers stage writes only `StageStarted` / `StageCompleted` lines. The claim is visible in Azure terms: when Azure creates the edge machine, the card changes from *Waiting to start* to **Being created in Azure** (`Creating`) and the machine gets its **Azure** steps. Vouchers themselves never appear anywhere, only their SHA-256 in ZTP's lines.

**Done:** the card moves past *Waiting to start*. **Failed:** `StageFailed` on Vouchers (no voucher in 120 minutes: the error names each node's last image status) or on Azure (the claim deployment failed). Sonar needs Reader on the resource group for the edge machines, and shows nothing for them until they exist (a 404 on the edge machine call means "nothing yet", not an error).

## Device

**ZTP does:** before the claim, in the maintenance environment, through the Configurator service on port 20001, sets the static management address on the port with the management MAC (and finds the maintenance environment by scanning for that MAC when the file gives no address). It sends no host name.

**In Sonar:** a per-machine step, **Management address (maintenance environment)**, shown first in the machine's steps, even before the edge machine exists. Its events appear as children: `DeviceConfigurationSubmitted`, `DeviceConfigurationStatus`, `DeviceAddressSet`. The card says *Waiting on the node: management address* while it runs. Click the step: the live logs filter to that machine's Device events.

**Done:** the step is green with *Address set* (or *Address already set*, or *Address reported, not changed* for a DHCP, DHCP-reservation or preconfigured node). *Skipped* is normal when the node has no maintenance address: the Network stage does the job later. **Failed:** `DeviceConfigurationFailed`: the scan did not find the node, no adapter has the management MAC, or the status reported a failure. The step turns red with the text, the machine becomes an error.

## Install OS (Azure and Ready)

**ZTP does:** after the claim, Azure registers the maintenance environment, installs the operating system and connects the machine to Arc. ZTP's Ready stage waits for it (up to 180 minutes) and resubmits the `ProvisionOs` job once if it fails.

**In Sonar:** this is the part where Sonar's own Azure reads do the work. The machine card shows the lifecycle in plain words (*Being created in Azure*, *Waiting to connect to Azure*, *Registering with Azure*, *Ready to install the OS*, **Installing the OS**, *Provisioned*), the Arc connection and a progress bar. The Steps box has Azure's lifecycle stages (`ProvisionMachine`: `RegisterMachine`, `ArcEnableMaintenanceEnvironment`, `InstallExtensions`; `InstallOs`: `Initialize`, `DownloadOs`, `PrepareOs`, `RebootOs`, `InstallExtensions`, `Finalize`) and the **ProvisionOs job** with its steps, each with an **Azure** badge, status, times and error text. Click an Azure step to see what Azure says about it; the logs are left alone because an Azure step writes nothing to a node log.

**Done:** *Provisioned* on the card and the job succeeded. (With the event file, the machine then waits on Network and Restore before it is complete.) **Failed:** the card turns red with the error; Sonar treats a job error as current only while the job reports failure. After ZTP's single resubmit the earlier error moves to `previousErrors` and the machine is running again (see [previousErrors](./ztp.md#how-sonar-decides-running-success-or-failure)). On live runs error 5901 at `SetupHybridComputeRP` was the usual first-attempt failure.

## Network

**ZTP does:** after the OS install (which resets every port to DHCP), checks that the management port, found by MAC, has the file's address. It is verify-only by default: a static address that the install reset is left to OS configuration to set, and ZTP says so.

**In Sonar:** the per-machine step **Management address on the management NIC**, after the `ProvisionOs` job. The card says *Waiting on ZTP: management address check* until it ends. The states: `ManagementAddressSet`, `ManagementAddressAlreadySet`, `ManagementAddressReported` (a warning in the event file when the port does not have the expected address) and `ManagementAddressDeferredToOsConfiguration` all count as done; the step's label for the last one is *Checked; OS configuration sets the address*.

**Done:** the step is green. **Failed:** `ManagementAddressFailed` (no adapter has the MAC, or a job failed): red, with the reason. **Normal, not a problem:** a *Deferred* result with a warning line such as `... has DHCP 192.0.2.116 after the install; expected static 192.0.2.11`. OS configuration (the next step after ZTP) sets the address.

## Restore

**ZTP does:** where it set temporary BIOS values for the install, puts back the final values over Redfish, restarts the node, and waits for Arc to report a new connection and the machine to be ready again. All nodes restart at the same time on purpose.

**In Sonar:** the per-machine step **BIOS restored**, last in the machine's steps: `BiosRestoreStarted` (the attributes), then `BiosRestored` (*BIOS restored and Arc connected again*). The card says *Waiting on ZTP: BIOS restore*. During the restart the node may be unreachable and Arc reads Connected for a while (Sonar waits for ZTP's event, not for Arc alone). Without temporary BIOS values the run writes no Restore event, and once the stage is over the step reads *Not applicable: the run set no temporary BIOS values* (skipped).

**Done:** the step is green or skipped. **Failed:** `BiosRestoreFailed`: red, with the reason and the outcome per node (a node marked Restored has already restarted). Fix the BIOS or the saved original, then run `-From Restore`: a node whose BIOS is already right is left alone.

## Handoff

**ZTP does:** writes the handoff file (the Arc machine names and IDs, the installed build, each machine's management address result and restored BIOS values) and the cluster inputs for OS configuration and the deployment. It ends the run with `ZTP is done` and `Next: OS configuration`. After Handoff, ZTP writes files only.

**In Sonar:** `StageCompleted` for Handoff, and the end of the run on the page: when every machine is Provisioned, its Network step succeeded and its Restore step succeeded or is not applicable, each card reads **ZTP complete** with *Next: OS configuration*, the Provisioning tile reads *ZTP complete*, and the summary says "ZTP is complete: all N machines are provisioned. Next: OS configuration". A link under the header opens the OS configuration guide.

**What to do:** nothing in Sonar. ZTP's job is over. Start OS configuration (OEM drivers, `C:\SBE`, DHCP off, DNS and time, the deployment admin), then Validate. Sonar stays at **ZTP complete** until you start the ARM Validate.

## After ZTP

| Next step | In Sonar | How to run it |
| --- | --- | --- |
| OS configuration | Not followed. The page stays at *ZTP complete*. | Leave Sonar running, or start it again later. |
| **Validate** | The **Validate** mode: Azure's validation steps (`deploymentSettings`), the running step with a live timer, errors expanded. Node logs from the seed node. | `./Start-AzlSonar.ps1 -InfrastructureFile ./infrastructure.yml -Credential (Get-Credential)` with the deployment local admin. [Details](./run.md#watch-os-configuration-and-validate). |
| **Deployment** | The **Deployment** mode: the nested step tree, the live logs, the account and folders in **Log access**. | The same command. [Details](./run.md#watch-a-deployment). |
| **Update** | The **Update** mode: the update run's steps. | `track: update`, or `auto` when Azure reports an update. [Details](./run.md#follow-an-update). |
| **Health** | The **Health** mode: each machine's Arc status. Sonar runs no health checks. | Any run on a deployed cluster. [Details](./run.md#look-at-a-deployed-cluster-health). |

A machine that fails in any stage turns red, the status chip reads **Failed**, and the page stays on the mode that failed so you can read the text.

## Running without a deployment: demo and replay

Neither needs Azure or a node. Use them to learn the page or to review a finished run, stage by stage.

```powershell
./Start-AzlSonar.ps1 -Replay ./recordings/clus01.jsonl -Speed 240 -StartAt deployment
```

Or open `http://localhost:8642/?demo=1&route=simplified` on a running Sonar for the built-in three-machine ZTP sample (`route=oem` for the OEM image route, `?demo=1` for a deployment, `?demo=1&replay=1` for the replay bar). A replay has a transport bar (play, speed, scrubber with markers, jump to a phase); see [Record and share a session](./run.md#record-and-share-a-session).
