# Running Sonar, by purpose

One section per purpose. Each lists the commands, what Sonar shows, what to expect and do, and the access it needs. Sonar only reads: it never changes Azure or the machines. Every section assumes PowerShell 7.4 or later and the repository cloned (see [Getting started](./getting-started.md)).

In every command, `-InfrastructureFile ./infrastructure.yml` (the master file, the default way) can be replaced by `-ConfigPath ./config/clus01.json` (the older option). How the two are configured: [Start here](./start-here.md#three-ways-to-configure-sonar).

The ZTP run has a page of its own for each stage (Boot, Bootstrap, Vouchers and the claim, Install OS, Device, Network, Restore, Handoff): [Running Sonar, stage by stage](./stages.md); the Log access window (which account and folders for each phase) is explained in [Log access](./log-access.md). Access for each purpose is summarised in its section. The full picture, which roles and network paths a run needs, is in the toolkit's [access and connectivity](https://github.com/AzureLocal/azurelocal-toolkit/blob/main/docs/access-and-connectivity.md) page.

## Watch a ZTP run

**When:** [azurelocal-ztp](https://github.com/AzureLocal/azurelocal-ztp) provisions bare machines with Microsoft's simplified machine provisioning. `scenario.os_install` is `simplified`.

```powershell
Connect-AzAccount -Tenant <tenant-id>
./Start-AzlSonar.ps1 -InfrastructureFile ./infrastructure.yml
```

The ZTP event file is `<provisioning.simplified.evidence_path>/ztp-events.jsonl` in the master file. Sonar finds it from there, so start Sonar on the machine where ZTP runs (or where that folder is shared). With a config file, set `ztpEvents.path`.

**What Sonar shows** (page at `http://localhost:8642/`):

- The **Provisioning (ZTP)** mode: a card per machine (its full name, its state in plain words, the Arc connection, what it waits on, a progress bar while it runs) and the Steps box with the machine's steps. See the [tour of the page](tour.md).
- Per machine, three ZTP steps from the event file:
  - **Management address (maintenance environment)** (stage Device): before the Azure claim, ZTP sets the static management address on the port with the management MAC. Shown before the edge machine exists. Skipped when the machine has no maintenance address; the next step does the job then.
  - **Management address on the management NIC** (stage Network): after the OS install, the address is moved to the management NIC through the edge machine's per-NIC API.
  - **BIOS restored** (stage Restore): where ZTP set temporary BIOS values for the install (for example a Fibre Channel HBA off), it puts the final values back, restarts the machine and waits for Arc to reconnect. Not applicable when a machine has no temporary values.
- Live log pane: the `[ztp]` event lines, coloured by level. Click a machine's card to see only its lines, or a ZTP step to see the events of that stage. Choose the file `ztp-events` to see only the event lines.

**What the end looks like.** A machine is done when Azure reports it Provisioned, its Network step succeeded and its Restore step succeeded or is not applicable. When every machine is done the cards read **ZTP complete** with *Next: OS configuration*, and the summary says "ZTP is complete: all N machines are provisioned. Next: OS configuration". That means: ZTP's job is over (it writes files only after this), and the next step is OS configuration (OEM drivers, `C:\SBE`, DHCP off, DNS and time, the deployment admin), then Validate. Nothing is wrong when Sonar sits there: start OS configuration. A failed state turns the machine red with the event's text; fix it, rerun that ZTP stage, and the machine goes on from there.

**Access:** Reader on the resource group of the edge machines and on the managed resource group that holds their Arc machines (Reader on the subscription covers both); Az.Accounts signed in; read access to the event file's folder. No access to the machines is needed during provisioning: there are no logs to read yet, so cancel the credential prompt (Sonar uses your Windows identity). Details: [ztp.md](./ztp.md).

## Watch the OEM image or ISO route

**When:** the machines were installed from an OEM image or an ISO and register with Arc themselves. `scenario.os_install` is `iso`.

```powershell
Connect-AzAccount
./Start-AzlSonar.ps1 -InfrastructureFile ./infrastructure.yml
```

**What Sonar shows:** the **Provisioning (OS image)** mode, the same cards and a Steps box per machine with the node's own step groups: *OS image update*, *Bootstrap* and *Azure registration*, with step counters, live timers and the error text. It ends with **Ready for Validate**. Sonar reads the status on each machine (a node probe over WinRM or SSH), so unlike the ZTP route it needs access to the machines.

**What to do:** wait for every machine to reach Ready for Validate; if one fails, the failed step shows its text. Then continue with OS configuration if it is not done, and Validate.

**Access:** Reader on the resource group; WinRM (5985/5986) or SSH to each node from the Sonar workstation with an account in the node's local Administrators (the built-in `Administrator` works while machines register); an IP address or workgroup node must be in this workstation's `TrustedHosts` (Sonar checks and tells you, it never changes it).

## Watch OS configuration

**When:** after ZTP (or an ISO install) and before Validate, the toolkit's `Invoke-AzureLocalOsConfiguration.ps1` configures every node.

```powershell
Connect-AzAccount -Tenant <tenant-id>
./Start-AzlSonar.ps1 -InfrastructureFile ./infrastructure.yml
```

The event file is `<provisioning.simplified.evidence_path>/os-configuration-events.jsonl` in the master file, next to the ZTP event file; with a config file or when the toolkit run was given `-EventLogPath`, set `osConfigEventsPath`. Start Sonar on the machine that runs the toolkit (or where that folder is shared).

**What Sonar shows:** the **OS configuration** mode: a card per machine (method ZTP or ISO, transport, the step it is on, converged, failed or retrying), the run in one sentence with the wipe list, and the machine's steps with the toolkit's text (*current -> desired*), retries, restarts, the guarded network change with its countdown, the domain join, and the versions. The `[osconfig]` lines are in the log pane (file `os-config-events`). The stages, the method and version display, what a stuck step looks like and what to do are in [Running Sonar, stage by stage](./stages.md#os-configuration).

**What to expect:** the plan fills every machine's steps first (read only, nothing changes), then the apply moves node by node, then the verification marks the steps *Verified* and the machine *Converged*. A run in Plan mode ends with *Plan finished: N changes pending. Nothing was changed.* and the tile stays grey.

**Access:** Reader on the resource group (Sonar reads the Arc machines' run commands, read-only, to show their state); the log account as in [Log access](./log-access.md#which-account-reads-which-node-local-first-then-the-domain-account): the local administrator until a node is domain-joined, then the domain account.

## Watch Validate

**What Sonar does here.** When you start the ARM Validate the page switches to the **Validation** phase: Azure's validation step tree (`deploymentSettings`), each step with status, start, end, duration and error text, the running step with a live timer. The **Validate** tile says it starts after OS configuration has converged on every machine; that is information, not a gate.

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

**What Sonar shows:** the phase **Deployment** with the nested step tree (steps within steps) with status, times, durations and errors; the **live logs** from the seed node (the first node in the master file, or the node marked `seed: true`), with filters by level, text, file and step; the **Log access** window (which account and folders for each phase, opened from the top bar). If Azure lags behind the node (the step list says *Deploy not started* while the node is running), Sonar labels the step the node log shows. When the deployment succeeds the phase is **Done**.

**WinRM or SSH.** Logs are read from the seed node with `logs.transport`: `auto` (WinRM first, then SSH), `winrm` or `ssh`. SSH needs the Posh-SSH module on the workstation (`Install-Module Posh-SSH -Scope CurrentUser`), `sshd` on the node and a credential. WinRM needs port 5985/5986 and, for IP addresses or workgroup nodes, `TrustedHosts`. If neither works, Sonar still runs: the step tree and node status come from Azure, and the log pane says why the logs are unavailable.

**Access:** Reader on the resource group; the log account in the seed node's local Administrators; network path from the Sonar workstation to the seed node's management address on 5985/5986 (WinRM) or 22 (SSH).

## Follow an update

**When:** the cluster is deployed and a solution update is available or installing. The **Update** tile of the page is for this.

```powershell
Connect-AzAccount
./Start-AzlSonar.ps1 -InfrastructureFile ./infrastructure.yml
```

With the default `track: auto` (and `updateTrack: auto`) Sonar reads the update resources once the deployment is done and follows an update when Azure reports one. To follow it from the start, or when Azure has not reported it yet, use a config file with `track: update` (`ConvertTo-AzlSonarConfig -InfrastructureFile ./infrastructure.yml -OutFile ./config/clus01.json`, then `Set-AzlSonarConfig -Path ./config/clus01.json -Key track -Value update`). `updateTrack: off` never reads the update resources.

**What Sonar shows:** the **Update** mode with the update run's steps (status, start and end, duration, error text, from `updateRuns`), a summary of what Azure says about the update (available, preparing, installing, failed, needs attention), and the node log of the seed node as it is written. The tab *Update* of [Log access](./log-access.md) names the account (the deployment local admin, or the LCM user on Active Directory) and the folders. A failed update can be resumed in the portal; Sonar only reports it.

**Access:** Reader on the resource group; for the node logs an account in the seed node's local Administrators.

## Look at a deployed cluster (Health)

**When:** the cluster is deployed and you want to see its state without touching it.

```powershell
./Start-AzlSonar.ps1 -InfrastructureFile ./infrastructure.yml
```

**What Sonar shows:** the **Health** mode: each machine's Azure Arc status (*N of M connected*). Sonar runs no health checks and shows no steps here; the Steps box says so. The status chip says *Done* for a finished deployment.

**Access:** Reader on the resource group.

## Follow add node or repair

Azure has no resource that lists the steps of an Add-Server or Repair-Server, so Sonar follows these by the node log and the Arc machines. Use a config file and set the track, then start Sonar before you run the command on the cluster:

```powershell
Set-AzlSonarConfig -Path ./config/clus01.json -Key track -Value add-node      # or: repair
./Start-AzlSonar.ps1 -ConfigPath ./config/clus01.json -Credential (Get-Credential)
```

**What Sonar shows:** the **Health** mode with the Arc status of each machine, the live logs from the seed node, and the *Add node* or *Repair* tab of [Log access](./log-access.md) with the account, folders and the commands to check progress. **Access:** Reader on the resource group; the account the tab names in the seed node's local Administrators.

## Learn the page without a deployment (demo and replay)

```powershell
./Start-AzlSonar.ps1 -Replay ./tests/fixtures/recording-sample.jsonl -Port 8642     # no Azure, no node
```

Open `http://localhost:8642/?demo=1` (a running deployment), `?demo=1&route=simplified` (a ZTP run of three machines), `?demo=1&route=oem` (the OEM image route) or `?demo=1&replay=1` (the replay controls with a built-in recording). The demo uses built-in sample data and example names, and makes no API calls except for the Help box and Log access text.

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
- The page answers `localhost` only, and only with the access token. `-NoBrowser` still prints the URL with the token (`http://localhost:8642/?t=<token>`; read it from the step's output, it is new at every start). To look at it from another machine, use an SSH tunnel or a remote desktop session; there is no setting to open it up.
- Give the log credential from the pipeline's secret store, never from the infrastructure file or the config file (the file only holds `keyvault://` references; secrets in the config are refused). `credential.source: keyvault` reads the secret names you give from Key Vault (needs Az.KeyVault).

**Access:** a service principal or managed identity with Reader on the resource group, a network path to the seed node if you want logs, and the log account from the secret store.

## Security

### What protects the page

- **Loopback only.** Sonar listens on `localhost` and `127.0.0.1` only, answers requests from this machine only, and accepts only `GET`.
- **An access token, on by default.** At start Sonar makes a random token (32 hex characters). The URL it prints and opens, `http://localhost:<port>/?t=<token>`, carries it once; Sonar answers with a cookie (`sonar_t`, `HttpOnly`, `SameSite=Strict`) and redirects to the same address without the token, so it stays out of the address bar and the history. Every other request, the page and every `/api` route included, needs that cookie and gets 401 without it. The token is new at every start, is never logged, recorded, exported or shown (it is masked like a password), and is compared in constant time.
- **Host and Origin checks.** A request must name `localhost`, `127.0.0.1` or `[::1]` with Sonar's port in its `Host` header (anything else gets 400), and an `Origin` header, when there is one, must be Sonar's own (anything else gets 403). That defeats DNS rebinding, where a web page on the internet gets your browser to talk to a name that points at your own machine.
- **Browser hardening.** Every response carries `Cache-Control: no-store`, `X-Content-Type-Options: nosniff`, `Referrer-Policy: no-referrer`, `X-Frame-Options: DENY` and a `Content-Security-Policy` that allows only Sonar's own files (no inline script or style). The page writes data into the DOM as text, and follows a link from the back end only when it is `https` on `azurelocal.cloud`, `learn.microsoft.com` or `github.com`. Only a fixed list of files is served.
- **Limits.** At most 4 live streams at once (`maxEventStreams`, 429 beyond it), one `/api/logs` answer is capped at 2000 lines and about 2 MB, and `since` must be a whole number.

### What an operator should know

- **Loopback is not a security boundary on a shared host.** On a jump host every signed-in account (and every program they run) can reach `localhost`. The access token is what keeps another account out: do not paste the printed URL into a shared chat, a ticket or a screen share, and do not leave Sonar running unattended. If you start Sonar with `-NoAccessToken` (or `accessToken: false`), any local account can read the page: use that on a single-user machine only.
- **The page shows addresses.** Details lists the nodes' management addresses, the resource group and the first 8 characters of the subscription, and the logs hold whatever the nodes log (secrets are masked, not guaranteed absent). Treat the page and the export like the deployment itself.
- **Remote access** is an SSH tunnel or a remote desktop session, never a changed binding. Open the printed URL on the machine where Sonar runs (or through the tunnel, with the same `?t=` URL).

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
