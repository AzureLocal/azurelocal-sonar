# Log access: which account, which folders, for each phase

Reading the node logs needs an account that is allowed to, and the folders change as a deployment goes on. Sonar keeps that guidance for every phase in the **Log access** window, so you do not have to look it up while a run is in progress. This page explains the window, what each of its modes (tabs) tells you, and how to run Sonar so the logs are read. It only describes what Sonar reads; Sonar never changes a node.

## Open it

- **Log access** in the top bar (the dot on the button is the state, see below). It opens a window over the page.
- Close it with **Close**, `Esc` or a click outside the window. `Tab` stays inside the window and the arrow keys move between the phase tabs.
- On a running Sonar, `http://localhost:8642/#logaccess` opens the page with the window already open (`#details` and `#help` do the same for Details and the `?` box).
- The window opens on the phase of the mode you are looking at. The tab of the phase that is happening now carries *(current phase)*.

## The dot and the status line

| Dot | Meaning |
| --- | --- |
| Green | The logs are read live from the seed node. |
| Amber | Azure only: Sonar cannot read the node logs. The step tree and the machine status still come from Azure, and the log pane says why. |
| Red | Nothing answers. |

The line under the title reads, for example, `Log access: Tailing node node01 · as supplied · last line 4 s ago`. *Tailing node ...* means connected; *Tailer unavailable (node ...)* or *Tailer error* says it is not. *as supplied* is the account you gave (`-Credential`, a prompt, or Key Vault names); without a credential Sonar says the account the guidance names for the phase. The identity model (`LocalIdentity` or `ActiveDirectory`) is the chip next to the title; it comes from `scenario.identity` or `identityModel` and decides which guidance you see.

## Which account reads which node: local first, then the domain account

In an Active Directory design the nodes are workgroup machines until the OS configuration joins them to the domain (its `DomainJoin` step, after the name, network, DNS and time) and then adds the domain account to the node's local Administrators group (the event `DomainAdminsConfigured`). A domain account is not an administrator of the node before that, so it cannot read the logs. Sonar follows both events, node by node, and tells you which account it uses and why.

| The node | Account used for its logs | What the window and **Details** say |
| --- | --- | --- |
| Not joined yet, or the identity design is local | The local account: the one you gave with `-Credential` or at the prompt, else `identity.local_admin.username` from the master file (for example `azl-admin`). | `workgroup: using azl-admin` |
| Has reported `DomainJoined` (or a `DomainJoin` plan that found it already joined), but not yet `DomainAdminsConfigured` | Still the local account. | `joined, waiting for domain administrators: using azl-admin` |
| Has reported both `DomainJoined` and `DomainAdminsConfigured` | The domain account built from the master file: `NETBIOS\username`, from `identity.active_directory.netbios_name` and the LCM user `identity.active_directory.lcm_user.username`, or `domain_join_account.username` when that optional override is present. The password is read from the Key Vault reference of the same account (`keyvault://<vault>/<secret>`) with Az.KeyVault, held as a secure string and masked in everything Sonar stores, serves or records. | `domain-joined: using IIC\svc-lcm` |
| Both reported, but the node refuses the domain account (or the Key Vault cannot be read) | The local account again, for that node, until Sonar restarts. | A warning: `domain-joined, but IIC\svc-lcm was rejected: using azl-admin` |
| Both reported, but the master file names neither `lcm_user` nor `domain_join_account` | The local account. | A warning that names the keys to set. |

Sonar reads the logs of the seed node (and, on the OEM image route, probes every node); the **Account in use** row of the Log access window lists the account of every machine, so you see the switch before it happens to the node you read. When the seed node is ready for the domain account, the open connection is closed and opened again with it. The password never appears on the page, in the logs, in the recording or in the export; the account's **name** does, because that is what you need to know. The master file is read defensively: a file with neither `lcm_user` nor `domain_join_account` works as before, with the local account only. There is no mandatory `domain_join_account`: it is an override for the case where another account joins the nodes. A plain password where the reference belongs is ignored, never used.

## The seven modes of the window

Each tab has the same rows: **Account** (who can read), **Where** (every folder), **When** (when the logs exist), **How** (how to reach the node), **This deployment** (a note for your cluster's shape, from `clusterPattern`, `architecture`, `internalDns` and the identity model), **Confidence** and **Source**. Some phases add **How long** and **Commands** (the node commands that check the phase).

| Tab | Used while | Account (the short version) | Folders | Notes |
| --- | --- | --- | --- | --- |
| **Provisioning** (simplified route) | ZTP: the maintenance environment, then bootstrap and Arc registration | In the maintenance environment: the Configurator app user `edgeuser`. After the OS install: the local administrator given when provisioning, the same on every node; not the built-in `Administrator`. | `C:\Windows\System32\Bootstrap\Logs`, `C:\ProgramData\AzureConnectedMachineAgent\Log`, `C:\ProgramData\GuestConfig\ext_mgr_logs`, `C:\ProgramData\GuestConfig\extension_logs` | Before the OS is installed there is nothing for Sonar to read on the node (the maintenance environment keeps its logs under `/var/log`; get them through the Configurator app support package). Sonar runs fine without node access here. |
| **Arc registration** (OEM image or ISO route) | OS image update, bootstrap, registration | The built-in `Administrator` until the deployment local admin exists, then that admin. Deployment renames the built-in account to `ASBuiltInAdmin`, so switch accounts before Validate. | `C:\Windows\System32\Bootstrap\Logs`, `C:\ProgramData\AzureConnectedMachineAgent\Log` | Commands on the node: `Get-ArcBootstrapStatus`, `Get-ArcZeroDaySolutionUpdateStatus`, `Collect-ArcBootstrapSupportLogs`. The tab is shown for the OEM route, and *Provisioning* for the simplified route (Sonar shows the one it follows). |
| **Validation** | Validate | Local Identity: the deployment local admin (`localAdminUserName`). Active Directory: the local administrator. | `C:\CloudContent\MASLogs`, `C:\MASLogs`, `C:\Observability`, `C:\CloudDeployment\Logs` (appears later in the run) | The Environment Checker writes to `C:\CloudDeployment\Logs` and each run overwrites its file. The mandatory Arc extensions install during Validate; their logs are in `C:\ProgramData\GuestConfig\extension_logs`. |
| **Deployment** | Deploy | The deployment local admin (Local Identity); the local administrator (Active Directory, with the LCM user added to local Administrators during deployment and the nodes joining the domain). | The same four folders. | The one entry confirmed on a live deployment. Fallbacks, both Azure writes and therefore opt-in only, are named in the guidance: Arc run command (output capped at 4 KB) and Arc SSH. |
| **Post-deployment** | The finished cluster (Health mode) | Local Identity: the deployment local admin, `RecoveryAdmin` (its password is in the cluster Key Vault); Active Directory: the LCM user. The built-in account is `ASBuiltInAdmin`. | `C:\CloudDeployment\Logs`, `C:\MASLogs`, `C:\ProgramData\AzureConnectedMachineAgent\Log` | RDP is off after deployment. Collection on demand (`Send-DiagnosticData`, the portal's Send logs) needs the AzureEdgeTelemetryAndDiagnostics extension and the Azure Stack HCI Administrator role. |
| **Update** | A solution update | Local Identity: the deployment local admin. Active Directory: the LCM user (`AzureStackLCMUser` or equivalent), which is in local Administrators. | `C:\CloudDeployment\Logs`, `C:\MASLogs`, `C:\Observability` | Sonar follows the Azure update run (steps, times, errors) and shows the seed node's log as it is written. Commands on a node: `Start-MonitoringActionplanInstanceToComplete`, `Get-ActionPlanInstance`, `Get-CauReport`. |
| **Add node** | Add-Server or Add machine | Run on an existing node with the new node's local administrator credentials; reading logs needs local Administrators on the nodes. | `C:\CloudDeployment\Logs`, `C:\MASLogs`, `C:\Observability` | Azure has no resource for it: set `track: add-node` and Sonar shows this tab, the Arc machines and the node log. The incoming node is still in a workgroup until added: TrustedHosts or HTTPS 5986. |
| **Repair** | Repair-Server | Run on another member node with the repaired node's local administrator credentials (by default the built-in `Administrator`); the node name must be the NetBIOS name. | `C:\CloudDeployment\Logs`, `C:\MASLogs`, `C:\Observability` | `track: repair`. Reimage the node and register it with Arc first. The node being repaired is reachable by IP only until it has rejoined. |

The exact, current text of every cell is in the window itself: it is read from `src/AzlSonar/data/phase-guidance.json` through `/api/guidance`, per identity model.

## Confidence

Each entry says how sure Sonar is: **Confirmed on a real deployment**, or **From Microsoft docs, not yet confirmed**. If the logs are not where an unconfirmed entry says, Sonar still finds them, because it watches every known log folder; please open an issue on GitHub so the entry can be corrected. The **Source** row links to the Microsoft Learn page the entry comes from (only `https` links to `learn.microsoft.com`, `azurelocal.cloud` and `github.com` are followed).

## How Sonar reads the logs (the run modes)

The logs come from the **seed node**: the node marked `seed: true`, or the first node. Choose how with `logs.transport` (a config file; the master file leaves it at `auto`):

| `logs.transport` | How | Needs |
| --- | --- | --- |
| `auto` (default) | WinRM first, then SSH | Either of the two below |
| `winrm` | PowerShell remoting to the node | Port 5985 or 5986 from the Sonar workstation; an account in the node's local Administrators; for an IP address or a workgroup node, the address in this workstation's `TrustedHosts` (Sonar checks it and tells you; it never changes it) |
| `ssh` | Posh-SSH | `Install-Module Posh-SSH -Scope CurrentUser` on the workstation, `sshd` on the node, a credential |

The account:

```powershell
./Start-AzlSonar.ps1 -InfrastructureFile ./infrastructure.yml -Credential (Get-Credential)   # given at start
./Start-AzlSonar.ps1 -InfrastructureFile ./infrastructure.yml                                # asks at start (cancel: your Windows identity)
```

With a config file you can also use Key Vault: `credential.source: keyvault` with the names `credential.vault`, `credential.usernameSecret` and `credential.passwordSecret` (needs `Az.KeyVault`; set them with [`Set-AzlSonarConfig`](./config.md#change-any-one-key-without-an-editor)). Sonar never stores a password.

Which mode to run in, by phase:

| You are in | Run Sonar with | Account to give |
| --- | --- | --- |
| ZTP (before the OS is installed) | No account: cancel the prompt. Sonar reads Azure and the event file only (amber dot). | None |
| ZTP after the install, OEM route registration | `-Credential` for the local administrator (OEM route: the built-in `Administrator` while machines register). | See the tab |
| Validate, Deploy | `-Credential` for the deployment local admin. | See the tab |
| After deployment, update, add node, repair | `-Credential` for the local administrator or LCM user, as the tab says. | See the tab |
| A finished run, or no access to the node | `-Replay <recording>`, or no credential at all. | None |

If the log pane says the live logs are unavailable, the message names the reason and the window's tab for your phase says which account and folders to use. The back end retries every 60 seconds, so a node that was rebooting comes back without a restart of Sonar.

## See also

- [Running Sonar, stage by stage](./stages.md) and [by purpose](./run.md)
- [Tour of the page](./tour.md#log-access-window)
- [Configuration](./config.md): `logs.*` and `credential.*`
