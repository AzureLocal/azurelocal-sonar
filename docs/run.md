# Running Sonar, by purpose

One section per purpose. Each lists the commands, what Sonar shows, what to expect and do, and the access it needs. Sonar only reads: it never changes Azure or the machines. Every section assumes PowerShell 7.4 or later and the repository cloned (see [Getting started](./getting-started.md)).

In every command, `-InfrastructureFile ./infrastructure.yml` (the master file, the default way) can be replaced by `-ConfigPath ./config/clus01.json` (the older option). How the two are configured: [Start here](./start-here.md#three-ways-to-configure-sonar).

Access for each purpose is summarised in its section. The full picture, which roles and network paths a run needs, is in the toolkit's [access and connectivity](https://github.com/AzureLocal/azurelocal-toolkit/blob/main/docs/access-and-connectivity.md) page.

## Watch a ZTP run

**When:** [azurelocal-ztp](https://github.com/AzureLocal/azurelocal-ztp) provisions bare machines with Microsoft's simplified machine provisioning. `scenario.os_install` is `simplified`.

```powershell
Connect-AzAccount -Tenant <tenant-id>
./Start-AzlSonar.ps1 -InfrastructureFile ./infrastructure.yml
```

The ZTP event file is `<provisioning.simplified.evidence_path>/ztp-events.jsonl` in the master file. Sonar finds it from there, so start Sonar on the machine where ZTP runs (or where that folder is shared). With a config file, set `ztpEvents.path`.

**What Sonar shows** (page at `http://localhost:8642/`):

- The phase chip **Provisioning**, one entry per machine in the **Provisioning** panel: lifecycle chip, progress bar, Arc machine, lifecycle message.
- Per machine, three ZTP steps from the event file:
  - **Management address (maintenance environment)** (stage Device): before the Azure claim, ZTP sets the static management address on the port with the management MAC. Shown before the edge machine exists. Skipped when the machine has no maintenance address; the next step does the job then.
  - **Management address on the management NIC** (stage Network): after the OS install, the address is moved to the management NIC through the edge machine's per-NIC API.
  - **BIOS restored** (stage Restore): where ZTP set temporary BIOS values for the install (for example a Fibre Channel HBA off), it puts the final values back, restarts the machine and waits for Arc to reconnect. Not applicable when a machine has no temporary values.
- Live log pane: the `[ztp]` event lines, coloured by level. Choose the file `ztp-events` to see only them.

**What the end looks like.** A machine is done when Azure reports it Provisioned, its Network step succeeded and its Restore step succeeded or is not applicable. When every machine is done the chip reads **ZTP complete** and the status "ZTP complete: N of N machines provisioned. OS configuration next". That means: ZTP's job is over (it writes files only after this), and the next step is OS configuration (OEM drivers, `C:\SBE`, DHCP off, DNS and time, the deployment admin), then Validate. Nothing is wrong when Sonar sits there: start OS configuration. A failed state turns the machine red with the event's text; fix it, rerun that ZTP stage, and the machine goes on from there.

**Access:** Reader on the resource group of the edge machines and on the managed resource group that holds their Arc machines (Reader on the subscription covers both); Az.Accounts signed in; read access to the event file's folder. No access to the machines is needed during provisioning: there are no logs to read yet, so cancel the credential prompt (Sonar uses your Windows identity). Details: [ztp.md](./ztp.md).

## Watch the OEM image or ISO route

**When:** the machines were installed from an OEM image or an ISO and register with Arc themselves. `scenario.os_install` is `iso`.

```powershell
Connect-AzAccount
./Start-AzlSonar.ps1 -InfrastructureFile ./infrastructure.yml
```

**What Sonar shows:** the phase chip **Arc registration**, the same panel per machine with the node's own step groups: *OS image update*, *Bootstrap* and *Azure registration*, with step counters, live timers and the error text. It ends with **Ready for Validate**. Sonar reads the status on each machine (a node probe over WinRM or SSH), so unlike the ZTP route it needs access to the machines.

**What to do:** wait for every machine to reach Ready for Validate; if one fails, the failed step shows its text. Then continue with OS configuration if it is not done, and Validate.

**Access:** Reader on the resource group; WinRM (5985/5986) or SSH to each node from the Sonar workstation with an account in the node's local Administrators (the built-in `Administrator` works while machines register); an IP address or workgroup node must be in this workstation's `TrustedHosts` (Sonar checks and tells you, it never changes it).

## Watch OS configuration and Validate

**What Sonar does here.** Sonar does not follow the OS configuration scripts themselves (OEM drivers, `C:\SBE`, DHCP off, DNS, time, the deployment admin). On the simplified route the page stays at **ZTP complete** with the note that OS configuration is next. Start Sonar again, or leave it running, and when you start the ARM Validate the page switches to the **Validation** phase: Azure's validation step tree (`deploymentSettings`), each step with status, start, end, duration and error text, the running step with a live timer.

```powershell
./Start-AzlSonar.ps1 -InfrastructureFile ./infrastructure.yml -Credential (Get-Credential)   # the deployment local admin
```

**What to expect:** validation steps appear as Azure reports them (a few minutes after the deployment resource is created). A failed step shows its exception text expanded; select it to filter the logs to its time window.

**Access:** Reader on the resource group. For logs from the seed node during Validate, the deployment local admin (`localAdminUserName`), not the built-in `Administrator`, which deployment renames to `ASBuiltInAdmin`. Active Directory: the local administrator.

## Watch a deployment

```powershell
Connect-AzAccount
./Start-AzlSonar.ps1 -InfrastructureFile ./infrastructure.yml -Credential (Get-Credential)
```

**What Sonar shows:** the phase **Deployment** with the nested step tree (steps within steps) with status, times, durations and errors; the **live logs** from the seed node (the first node in the master file, or the node marked `seed: true`), with filters by level, text, file and step; the **Log access** card (which account and folders for this phase). If Azure lags behind the node (the step list says *Deploy not started* while the node is running), Sonar labels the step the node log shows. When the deployment succeeds the phase is **Done**.

**WinRM or SSH.** Logs are read from the seed node with `logs.transport`: `auto` (WinRM first, then SSH), `winrm` or `ssh`. SSH needs the Posh-SSH module on the workstation (`Install-Module Posh-SSH -Scope CurrentUser`), `sshd` on the node and a credential. WinRM needs port 5985/5986 and, for IP addresses or workgroup nodes, `TrustedHosts`. If neither works, Sonar still runs: the step tree and node status come from Azure, and the log pane says why the logs are unavailable.

**Access:** Reader on the resource group; the log account in the seed node's local Administrators; network path from the Sonar workstation to the seed node's management address on 5985/5986 (WinRM) or 22 (SSH).

## Read-only audit and recording of an existing cluster

**When:** you want to look at a cluster that is already deployed (its steps, Arc machines, an update in progress) without any risk, and keep a record.

```powershell
Connect-AzAccount
./Start-AzlSonar.ps1 -InfrastructureFile ./infrastructure.yml -Record ./recordings/clus01.jsonl
```

Add `track` to a config file (`update`, `add-node` or `repair`) to follow that operation after deployment; `auto` follows an update when Azure reports one. Without log access (cancel the credential prompt) Sonar shows what Azure reports. Every Azure call is a GET and nothing is written to the nodes. The recording is the only file Sonar writes, and it only appends.

**Access:** Reader on the resource group. Nothing else if you skip the logs.

## Run from a pipeline or an unattended session

```powershell
Connect-AzAccount -ServicePrincipal -Tenant $tenantId -Credential $spCredential   # an identity with Reader
./Start-AzlSonar.ps1 -InfrastructureFile $infra -Credential $logCredential -NoBrowser -Port 8642 -Record ./recordings/run.jsonl
```

- `-NoBrowser` stops it opening a browser; `-Credential` avoids the prompt (without it, `credential.source: prompt` waits for input); `-Record` keeps the run as the output you collect.
- Sonar runs until it is stopped (Ctrl+C or the job being stopped). Run it as a background job or a separate step and stop it when the pipeline step ends.
- The page answers `localhost` only (anything else gets 403). To look at it from another machine, use an SSH tunnel or a remote desktop session; there is no setting to open it up.
- Give the log credential from the pipeline's secret store, never from the infrastructure file or the config file (the file only holds `keyvault://` references; secrets in the config are refused). `credential.source: keyvault` reads the secret names you give from Key Vault (needs Az.KeyVault).

**Access:** a service principal or managed identity with Reader on the resource group, a network path to the seed node if you want logs, and the log account from the secret store.

## Record and share a session

```powershell
./Start-AzlSonar.ps1 -InfrastructureFile ./infrastructure.yml -Record ./recordings/clus01.jsonl
./Start-AzlSonar.ps1 -Replay ./recordings/clus01.jsonl -Speed 240 -StartAt deployment       # no Azure, no node access

# A copy that can be shared: every identifier replaced by a stable pseudonym, then checked.
./Start-AzlSonar.ps1 -InfrastructureFile ./infrastructure.yml -Record ./recordings/clus01.shareable.jsonl -Publishable
```

A normal recording keeps identifiers (GUIDs, IP addresses, host and cluster names) but masks secrets. Use `-Publishable` (a new file) to share it; the finished file is verified, and a failed check renames it `.NOT-PUBLISHABLE`. A replay needs no sign-in. Details: [README, Record and replay](https://github.com/AzureLocal/azurelocal-sonar#record-and-replay) and [Publishable recordings](./reference/publishable-recordings.md).

**Access:** the same as the live run; none for a replay.

## Restart Sonar mid-run

Stopping Sonar changes nothing in Azure or on the machines. Start it again with the same command.

- **Kept:** a recording is appended to, with a new `session` header, so the replay shows both parts. Everything else is read again: the step tree, the machines and the phase come from Azure at the first poll, and the ZTP event file is read from its start, so the ZTP lines and steps reappear in full.
- **Not kept:** the browser page notices the restart by the instance id and reloads itself; the log pane starts again from the files on the seed node that are still active, and the log account is asked again (use `-Credential` to avoid that).
- **When to restart:** after the master file or the config file changes the node set, the route or the identity model (see [Configuration](./config.md#what-happens-to-a-running-sonar)); when the log account changed (for example after deployment renames `Administrator`).
