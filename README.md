# AzL Sonar

**Real-time monitor for Azure Local deployments.** Follow a deployment while it runs: every step and its status, and the live deployment logs from the seed node, in a modern local web view. PowerShell back end; nothing to install. Read-only.

Beacon checks the environment before deployment. Sonar listens to the deployment as it happens.

> Status: new. See [repo-intent.md](repo-intent.md) and the [plan](docs/plan.md).

- [Requirements](#requirements)
- [Quick start](#quick-start)
- [Configuration reference](#configuration-reference)
- [What each phase shows](#what-each-phase-shows)
- [Where the logs are](#where-the-logs-are)
- [Which account reads the logs](#which-account-reads-the-logs)
- [Read-only and security model](#read-only-and-security-model)
- [Troubleshooting](#troubleshooting)
- [Screenshots](#screenshots)
- [Further reading](#further-reading)

## Requirements

On the workstation or jump server that runs Sonar:

| Need | Why |
| --- | --- |
| **PowerShell 7.4 or later** | The back end is a PowerShell 7 module (`#Requires -Version 7.4`). Windows PowerShell 5.1 cannot run it. |
| **Az.Accounts, signed in** (`Connect-AzAccount`) | Sonar reads Azure through the signed-in Az PowerShell context (`Invoke-AzRestMethod`). It stops at start if nobody is signed in. |
| **Read access to the resource group** (Reader is enough) | The step tree comes from `deploymentSettings`, the node status from the Arc machines, provisioning from `edgeMachines`. All GETs. |
| **For live logs:** WinRM to the seed node | PowerShell remoting on 5985/5986 with an account in the node's local Administrators. Workgroup (Local Identity) nodes, and any node reached by IP address, need the address in this workstation's WinRM `TrustedHosts` (Sonar checks it and tells you; it never changes it). |
| **or** SSH to the seed node with **Posh-SSH** | When WinRM is blocked, Sonar uses SSH (`Install-Module Posh-SSH -Scope CurrentUser`). `sshd` must run on the node (node preparation enables it) and a credential is required. |
| Az.KeyVault | Only when `credential.source` is `keyvault`. |
| A browser on the same machine | The page is served on `http://localhost:<port>/` and answers this machine only. |

Without log access Sonar still runs: the step tree, phases and node status come from Azure; the log pane shows why the logs are unavailable and which account and location to use.

## Quick start

1. Sign in to Azure with an account that can read the resource group:

   ```powershell
   Connect-AzAccount
   Set-AzContext -Subscription '<subscription id>'
   ```

2. Copy the example config and fill in your values (one file per cluster, kept outside the repo):

   ```powershell
   Copy-Item ./examples/sonar.config.example.json ./config/clus01.json
   ```

   ```json
   {
     "subscriptionId": "00000000-0000-0000-0000-000000000000",
     "resourceGroup": "rg-example-azl",
     "clusterName": "clus01",
     "identityModel": "LocalIdentity",
     "nodes": [
       { "name": "node01", "address": "192.0.2.11", "arcMachineName": "node01", "seed": true },
       { "name": "node02", "address": "192.0.2.12", "arcMachineName": "node02" }
     ],
     "credential": { "source": "prompt" }
   }
   ```

3. For a workgroup node or an IP address, make sure the seed node is in `TrustedHosts` (elevated, appends to the list; Sonar never changes it):

   ```powershell
   Set-Item WSMan:\localhost\Client\TrustedHosts -Value '192.0.2.11' -Concatenate -Force
   ```

4. Start Sonar:

   ```powershell
   ./Start-AzlSonar.ps1 -ConfigPath ./config/clus01.json
   ```

   It asks for the account that reads the logs (`credential.source: prompt`), starts the back end on `http://localhost:8642/` and opens the browser. Press Ctrl+C to stop.

| Parameter | Default | Meaning |
| --- | --- | --- |
| `-ConfigPath` | (required) | The cluster's config file. |
| `-Port` | `8642` | Local port. Pick another if 8642 is taken (Sonar says so). |
| `-Credential` | (none) | The log account; overrides `credential.source`. |
| `-NoBrowser` | off | Do not open the browser. |

Add `?demo=1` to the page URL to see the page with built-in sample data (no API calls).

## Configuration reference

Unknown fields are ignored. Sonar validates the file at start and lists every problem at once.

| Field | Required | Default | Meaning |
| --- | --- | --- | --- |
| `subscriptionId` | yes | | Subscription GUID of the Azure Local instance. |
| `resourceGroup` | yes | | Resource group of the instance (and its Arc machines and edge machines). |
| `clusterName` | yes | | The `Microsoft.AzureStackHCI/clusters` resource name. |
| `apiVersion` | no | `2025-09-15-preview` | api-version for `clusters/deploymentSettings`. |
| `edgeApiVersion` | no | `2025-12-01-preview` | api-version for `edgeMachines` and their `jobs` (they do not exist in older versions). |
| `identityModel` | yes | | `LocalIdentity` or `ActiveDirectory`. Picks the account guidance and whether `TrustedHosts` is needed. |
| `pollSeconds` | no | `20` | Azure poll interval, 5 to 3600 seconds. |
| `nodes` | yes | | At least one node. |
| `nodes[].name` | yes | | Host name, unique. |
| `nodes[].address` | yes | | Host name or IP address Sonar connects to for logs (seed node only). |
| `nodes[].arcMachineName` | no | the node name | Arc resource name; simplified machine provisioning names it after the device (`<device-id>-1`). |
| `nodes[].seed` | no | `false` | The node whose logs are tailed. At most one; when none is marked, the first node is used (with a warning). |
| `logs.paths` | no | `C:\CloudContent\MASLogs`, `C:\MASLogs`, `C:\CloudDeployment\Logs`, `C:\Observability`, `C:\Windows\System32\Bootstrap\Logs` | Folders tailed on the seed node. A folder that does not exist yet is checked again at every folder listing. |
| `logs.include` | no | `*.log`, `*.txt`, `*.xml` | File name patterns to tail (at least one). |
| `logs.exclude` | no | `*.etl` | File name patterns to skip (exclude wins; may be empty). |
| `logs.recurseDepth` | no | `3` | Sub-folder depth, 0 to 10. |
| `logs.activeWindowMinutes` | no | `30` | Only files written within this many minutes are tailed, 1 to 10080. |
| `logs.maxLinesPerPoll` | no | `500` | Lines read per poll across all files, 1 to 10000; the rest come next poll. |
| `logs.pollSeconds` | no | `pollSeconds` | Log poll interval, 1 to 3600 seconds. |
| `logs.transport` | no | `auto` | `auto` (WinRM, then SSH), `winrm` or `ssh`. |
| `credential.source` | no | `prompt` | `prompt` (asks once at start), `parameter` (`-Credential`; without it the current Windows identity is used for WinRM) or `keyvault`. |
| `credential.vault` | for `keyvault` | | Key Vault name. |
| `credential.usernameSecret` | for `keyvault` | | Secret that holds the user name. |
| `credential.passwordSecret` | for `keyvault` | | Secret that holds the password. |
| `credential.password`, `.secret`, `.secretValue` | never | | Rejected: secrets never go in the config file. |

Fixed limits (not configurable): the folders are listed (`Get-ChildItem`) on every 3rd log poll or after 60 s, whichever comes first, and the known active files are tailed in between; at most 300 active files and 2000 tracked files; 1 MiB per file per poll; a file already present at start is read from 16 KiB before its end; the back end keeps the last 5000 log lines and up to 5000 state snapshots; at most 10 browser tabs stream at once.

## What each phase shows

The header shows the current phase, worked out from what Azure reports:

| Phase | When | What Sonar shows |
| --- | --- | --- |
| **Provisioning** | No validation or deployment steps yet | The Arc status of every node (header chips) and the logs from `C:\Windows\System32\Bootstrap\Logs` once the OS is installed. Sonar already reads the edge machines (simplified machine provisioning: provisioning state, machine state, connectivity, the `ProvisionOs` job's step tree and `percentComplete`) into `/api/state` and the export; drawing them on the page is plan task S-8. |
| **Validation** | `reportedProperties.validationStatus` has steps | The validation step tree: each step's status, start, end, duration and error text, the running step with a live timer, progress counts. |
| **Deployment** | `reportedProperties.deploymentStatus` has steps | The nested deployment step tree (steps within steps), with the same detail, and the live logs from the seed node. |
| **Done** | The deployment succeeded | The finished trees with durations; the logs stay on the node. |
| **Failed** | The active phase reports an error | The failed step with its exception text expanded inline; select it to filter the logs to its time window. |

Live logs: every line with its time, level (errors and warnings highlighted; zero-count summaries such as `Failed: 0` are not flagged) and file; filters by level, text, file and step. A line with its own timestamp is placed by that time (converted to UTC with the node's offset); a line without one is placed by the time Sonar received it and marked `~` (approximate). **Export** downloads one JSON bundle: config without secrets, the latest state, the change-only state timeline, the log lines and metadata that says how much the caps dropped.

## Where the logs are

Verified live on 10 Oct 2026 on the `nic26-clus01` seed node during a Local Identity Deploy pass, read as the non-built-in deployment local admin (see [docs/research.md](docs/research.md)):

| Folder | What is there | When |
| --- | --- | --- |
| `C:\CloudContent\MASLogs` (and `ASSecurityOSConfigLogs`) | `BareMetal_*`, `AzureStackOSConfig_*`, `WDAC_*`: one file per step, timestamp in the file name | From the start of Deploy |
| `C:\MASLogs` | `BareMetal_*`, `Install-LCMController_*`, `LCMECELiteLogs\summary.*.log.xml` | From the start of Deploy |
| `C:\Observability` | `OSConfig\*`, `ObsScheduledTaskTranscripts\*`, `CredScanLogs\*` | From the start of Deploy |
| `C:\CloudDeployment\Logs` | Environment Checker and cloud deployment logs (Learn names the folder, not the files) | **Not there** about 10 minutes into Deploy; appears later in the run. Sonar keeps checking. |
| `C:\Windows\System32\Bootstrap\Logs` | `setup.log`, `arcInstallLog-*.txt`, `AzStackHci.ArcConnection.Debug.log\PowerShell_transcript.*`, ETW `*.etl` (skipped) | Provisioning: bootstrap and Arc registration |

Also on the nodes, not tailed by default (add them to `logs.paths` if you need them): `C:\ProgramData\AzureConnectedMachineAgent\Log` (`himds.log`, `azcmagent.log`) and `C:\ProgramData\GuestConfig\ext_mgr_logs`, `extension_logs` (Arc agent and extensions). Before the OS is installed, the maintenance environment keeps its logs under `/var/log`; get them through the Configurator app support package.

## Which account reads the logs

Learn does not document the permissions on these folders; members of the node's local Administrators could read them in the lab. The page's **Log access** card shows the same guidance for your identity model, with sources.

| Phase | Local Identity | Active Directory |
| --- | --- | --- |
| Provisioning (OS installed) | The local admin set when provisioning, or the non-built-in local admin you created with the same credentials on every node | The local administrator (same on every node); if the nodes were joined to the domain before deployment (2604+), the deployment user added to local Administrators |
| Validation | The deployment local admin (`localAdminUserName`), non-built-in | The local administrator |
| Deployment | The deployment local admin | The local administrator; the LCM (deployment) user is added to local Administrators during deployment |
| After deployment | The deployment local admin; `RecoveryAdmin` (password in Key Vault) | The LCM user; the local administrator |

Do not use the built-in `Administrator`: deployment renames it to `ASBuiltInAdmin`, so it stops working mid-run (Sonar warns at start). Azure side: Reader on the resource group is enough for everything Sonar does.

## Read-only and security model

- **Loopback only.** The server binds `http://localhost:<port>/` and answers requests from this machine only (anything else gets 403). Only `GET` is accepted (others get 405). Static files are served from the `web` folder only.
- **Never writes to Azure.** Every Azure call is a `GET` through `Invoke-AzRestMethod`. Arc run command and Arc SSH are not used because both write to Azure.
- **Never writes to a node.** Each poll runs one read-only script that lists and reads log files with shared read access (the writer and log rotation are never blocked). Over SSH the script is streamed through stdin; no file is written on the node. Sonar keeps no state on the node.
- **Never changes the workstation.** Sonar reads `TrustedHosts` and tells you what is missing; it never sets it.
- **Secrets.** No secret is allowed in the config file. Key Vault secrets are read once at start and kept in memory as a `PSCredential`. `/api/config` and the export carry no secrets, no secret names and no node addresses. Log text is redacted before it is stored, served or exported: the log account's password, and common secret formats (`password=`, `secret=`, `token=`, `AccountKey=`, `Bearer ...`, SAS `sig=`, `-Password ...`).
- **SSH host keys.** The SSH fallback accepts the node's host key on first use (Posh-SSH `-AcceptKey`). Use it on a management network you trust.
- **Resource use.** Bounded memory (5000 lines, 5000 snapshots, 2000 tracked files), at most 10 live browser streams, and a slow or stuck browser tab is dropped instead of slowing the others.

## Troubleshooting

| Symptom | Cause and fix |
| --- | --- |
| `No Azure sign-in found in this PowerShell session` | Run `Connect-AzAccount` in the same PowerShell 7 window, then start Sonar again. |
| `Az PowerShell (Az.Accounts) is not installed` | `Install-Module Az.Accounts -Scope CurrentUser`. |
| `GET deploymentSettings ... failed` (403 or 404 on the subscription) | Wrong subscription in the Az context or no access: `Set-AzContext -Subscription <id>` and check you have Reader on the resource group. A 404 on `deploymentSettings` alone is normal before the deployment starts (phase: provisioning). |
| Logs unavailable: `... is not in the WinRM client TrustedHosts list` | Workgroup (Local Identity) nodes and IP addresses use NTLM. In an elevated session: `Set-Item WSMan:\localhost\Client\TrustedHosts -Value '<address>' -Concatenate -Force`. Check with `Get-Item WSMan:\localhost\Client\TrustedHosts`. |
| Logs unavailable: `WinRM: Access is denied` | The account is not a local admin on the node, or it is a local account that is not the built-in Administrator and the node filters its token (`LocalAccountTokenFilterPolicy` must be 1; it was 1 on the lab nodes). Use the deployment local admin, not `Administrator`. |
| Logs unavailable: WinRM cannot connect (timeout, firewall, `5985`) | WinRM is blocked from this workstation. Install Posh-SSH (`Install-Module Posh-SSH -Scope CurrentUser`) and keep `logs.transport` at `auto`, or set it to `ssh`. SSH needs a credential (prompt, `-Credential` or Key Vault) and `sshd` running on the node. |
| `SSH: the Posh-SSH module is not installed` | `Install-Module Posh-SSH -Scope CurrentUser`, then restart Sonar. |
| `Not created yet (checked at every folder listing): C:\CloudDeployment\Logs` | Normal early in Deploy: the folder appears later. The other folders are tailed meanwhile. |
| `Cannot listen on http://localhost:8642/` | The port is in use (another Sonar?). Start with `-Port 9000`. |
| The page says **Polling** instead of **Live** | The live stream dropped or 10 tabs are already open; the page polls every 5 s and reconnects by itself. Close extra tabs. |
| The log account stopped working mid-deployment | It was the built-in `Administrator`, which deployment renames to `ASBuiltInAdmin`. Restart Sonar with the deployment local admin. |
| `credential.source is keyvault but Az.KeyVault is not installed` | `Install-Module Az.KeyVault -Scope CurrentUser`; the signed-in account needs secret get on the vault. |

## Screenshots

<!-- Screenshots go here once the live run (plan task S-7) is complete: the step tree during Deploy, the live log pane with a step filter, the Log access card, and the dark theme. -->

_Screenshots will be added after the live test on the NIC 2026 lab cluster (plan task S-7)._

## Further reading

- [Getting started](docs/getting-started.md) and [How it works](docs/how-it-works.md)
- [Design](docs/design.md): the API, data model and behaviour contract
- [Research](docs/research.md): Microsoft Learn sources and what was verified live
- Tests: `Invoke-Pester -Path tests` (Pester 5; no Azure or node calls). Lint: `Invoke-ScriptAnalyzer -Path . -Recurse`.
