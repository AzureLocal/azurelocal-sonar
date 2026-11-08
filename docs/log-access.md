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
| Has reported both `DomainJoined` and `DomainAdminsConfigured` | The domain account **you supply** in the master file: `identity.active_directory.domain_join_account` (`username`, and `password` as a `keyvault://<vault>/<secret>` reference), shown as `NETBIOS\username` with `identity.active_directory.netbios_name`. The password is read from Key Vault with Az.KeyVault when the first node needs it, held as a secure string and never kept as plain text (see [the password](#the-domain-accounts-password)). | `domain-joined: using IIC\svc-join` |
| Both reported, but the account is paused (rejected, locked out, not an administrator of that node) | The local account, for the nodes the pause covers, with the reason and the time of the next check. | A warning: `domain-joined, but IIC\svc-join was rejected: using azl-admin` |
| Both reported, but the password cannot be read from Key Vault | The local account, and **not** a rejection of the account; Sonar asks again after 1, 2, then every 5 minutes. | `the domain account is not available (next check 20:15 UTC)`, and the warning names the vault and the secret, never a value |
| Both reported, but the master file has no `domain_join_account` | The local account. | A warning that names `identity.active_directory.domain_join_account` |

**Sonar never uses the LCM user** (`identity.active_directory.lcm_user`) for the domain credential or for anything else: it belongs to the deployment. The key is not read; if it is the only account in the file, there is no domain account and the local account stays.

Sonar reads the logs of the seed node (and, on the OEM image route, probes every node); the **Account in use** row of the Log access window lists the account of every machine, so you see the switch before it happens to the node you read. When the seed node is ready for the domain account, the open connection is closed and opened again with it. The password never appears on the page, in the logs, in the recording or in the export; the account's **name** does, because that is what you need to know. A master file with no `domain_join_account` works as before, with the local account only. A plain password where the reference belongs stops the import with a message that names the key and never repeats the value.

### The domain account's password

- **A pinned version.** `keyvault://<vault>/<secret>/<version>` reads exactly that secret version (32 hexadecimal characters); without it, the current version. The vault name follows Azure's rules (3 to 24 characters, starts with a letter, letters, digits and single hyphens, no hyphen at the end) and the secret name is 1 to 127 letters, digits and hyphens. An invalid reference is refused when the file is read (`Test-AzlSonarConfig`, `-InfrastructureFile`), naming the key, before anything is connected.
- **Kept as a secure string, masked by fingerprint.** To hide the password in text Sonar stores or serves, the shared mask holds a salted fingerprint of it (length, a rolling hash and a salted SHA-256), computed once from the secure string while its characters sit in a buffer that is cleared afterwards. No plain text copy of the password lives in the shared state, so serialising that state cannot leak it. A fingerprint cannot give the password back; it is held in memory only and never served, logged or recorded. The recorder refreshes its list of secrets on every step, so a password registered after a recording started is masked in the recording from the next step on.
- **One lock, and Key Vault outside it.** Deciding who may use the account, publishing the credential and the breaker records happen in critical sections of `Shared.CredentialLock`. The Key Vault read itself does **not** hold the lock: only the node that holds the single probe slot reads it, and it publishes the result under the lock afterwards. The per-node account records are immutable: a new record replaces the old one.

### The lockout circuit breaker

Every wrong password counts towards the account's Active Directory lockout threshold, and it counts for the whole domain, not for one node. So the breaker is **account-wide**, and it is decided under the lock (never from a value read before it):

| State | Meaning | What happens |
| --- | --- | --- |
| **closed, not yet verified** | First use after Sonar starts, and after any reset. | **One** node at a time is the probe: only it is given the account until its connection reports ok. Every other node uses the local account (*another node is checking the account first*). |
| **closed, verified** | A connection with the current password has worked. | The domain account is given to every node that is ready for it. |
| **open** | A node rejected the account (wrong user name or password). | The **first** rejection by any node stops the account for **all** nodes. Every node uses the local account. After a back-off (15 minutes, doubling to 30, 60, then 120 minutes) exactly **one** node, one connection at a time, may try again: the probe. A probe that works closes the breaker and resets the count; a rejected probe doubles the back-off. There is no retry per poll. |
| **latched** | The account was rejected `maxRejections` times (default 2; `logAccounts.domain.maxRejections`, 1 to 5), **or** the domain reported it locked out. | No more probes, however long Sonar runs. Once per back-off (at least every 120 minutes for a lockout) Sonar looks at the secret's **version** in Key Vault (the account is not tried). A new version means the password was changed: the breaker goes back to *closed, not yet verified* and the node that noticed is the one probe; it closes only when that probe reports ok. The operator can also confirm the unlock (`Confirm-AzlSonarAccountUnlock`), and restarting Sonar resets it too. |

How a result is trusted:

- **Tickets and epochs.** The credential is handed out with a ticket (the breaker's epoch when it was given, whether it is the probe). The epoch changes on every rejection, reset and reclaimed probe. A result whose ticket is older than the last change is stale and is ignored: a second node failing in the same wave does not double the back-off or latch the breaker, and a late *ok* from an ordinary connection does not close what another node just opened.
- **Only the probe holder** can close the breaker with *ok* or release the probe slot with any other result.
- **A lease on the probe slot.** A probe that never reports (for example Posh-SSH is missing, or no transport was left to try) loses its slot after 120 seconds; the next node becomes the probe and the old holder's late result is ignored.

A locked-out account (1909, `0x80070775`, "account locked out") latches the breaker at once, with a warning that names the account. Details shows the breaker under **Domain account**: the account name, its state, `1 of 2 rejections`, the next check, the last class and the back-off, never a secret.

### What a failed connection says about the account

Sonar classifies the failure from the Windows error number first (the language of the text is not reliable: `ErrorCode`, the Win32 part of `HResult`, `0x8007xxxx` in the text) and then from specific phrases. A broad word such as "authentication", "credential" or "logon failure" alone is not enough.

| Class | Seen as | Effect on the account |
| --- | --- | --- |
| **rejected** | 1326 (`0x8007052e`), 1331, 1330, 1907, `0x8009030c`, "the user name or password is incorrect", "bad password"; SSH `Permission denied (publickey,password)`; and **access denied (5, `0x80070005`, `AccessDenied`) while the session is being opened** | Counts: opens or advances the breaker. Over Negotiate a wrong password fails at *open* exactly like "Access is denied", so an access denied at open is treated as a rejection. |
| **lockedOut** | 1909 (`0x80070775`), "account locked out", "referenced account is currently locked out" | Latches the breaker. |
| **authorization** | 1385 (`0x80070569`, "logon type not granted": the password was right); or access denied **after** a session opened (a later step) | The account got in but may not do this: that node uses the local account for 5 minutes. The others keep the domain account; the breaker is untouched. |
| **unreachable** | timeouts, network errors, "credential provider" failures | Nothing about the account. A probe that never reached its node gives its slot back. |
| **other** | anything else, "authentication mechanism ... not supported", "the target account name is incorrect" | Nothing about the account. |
| **credentialUnavailable** | Key Vault could not be read (no sign-in, no access, Az.KeyVault missing, an empty secret) | Never marks the account or a node rejected. The local account is used; Sonar asks again after 1, 2, then every 5 minutes. |

**One transport per password.** With the domain account and `logs.transport: auto`, Sonar tries WinRM only: after any WinRM failure the domain password is **not** sent over SSH (the reason says so). Each transport leg of an attempt is classified for its own transport and the worst class wins (an SSH `Permission denied (` is a rejection however the WinRM leg failed).


## The seven modes of the window

Each tab has the same rows: **Account** (who can read), **Where** (every folder), **When** (when the logs exist), **How** (how to reach the node), **This deployment** (a note for your cluster's shape, from `clusterPattern`, `architecture`, `internalDns` and the identity model), **Confidence** and **Source**. Some phases add **How long** and **Commands** (the node commands that check the phase).

| Tab | Used while | Account (the short version) | Folders | Notes |
| --- | --- | --- | --- | --- |
| **Provisioning** (simplified route) | ZTP: the maintenance environment, then bootstrap and Arc registration | In the maintenance environment: the Configurator app user `edgeuser`. After the OS install: the local administrator given when provisioning, the same on every node; not the built-in `Administrator`. | `C:\Windows\System32\Bootstrap\Logs`, `C:\ProgramData\AzureConnectedMachineAgent\Log`, `C:\ProgramData\GuestConfig\ext_mgr_logs`, `C:\ProgramData\GuestConfig\extension_logs` | Before the OS is installed there is nothing for Sonar to read on the node (the maintenance environment keeps its logs under `/var/log`; get them through the Configurator app support package). Sonar runs fine without node access here. |
| **Arc registration** (OEM image or ISO route) | OS image update, bootstrap, registration | The built-in `Administrator` until the deployment local admin exists, then that admin. Deployment renames the built-in account to `ASBuiltInAdmin`, so switch accounts before Validate. | `C:\Windows\System32\Bootstrap\Logs`, `C:\ProgramData\AzureConnectedMachineAgent\Log` | Commands on the node: `Get-ArcBootstrapStatus`, `Get-ArcZeroDaySolutionUpdateStatus`, `Collect-ArcBootstrapSupportLogs`. The tab is shown for the OEM route, and *Provisioning* for the simplified route (Sonar shows the one it follows). |
| **Validation** | Validate | Local Identity: the deployment local admin (`localAdminUserName`). Active Directory: the local administrator. | `C:\CloudContent\MASLogs`, `C:\MASLogs`, `C:\Observability`, `C:\CloudDeployment\Logs` (appears later in the run) | The Environment Checker writes to `C:\CloudDeployment\Logs` and each run overwrites its file. The mandatory Arc extensions install during Validate; their logs are in `C:\ProgramData\GuestConfig\extension_logs`. |
| **Deployment** | Deploy | The deployment local admin (Local Identity); the local administrator (Active Directory: the nodes join the domain during deployment; the domain account you give Sonar is used once it is in local Administrators). | The same four folders. | The one entry confirmed on a live deployment. Fallbacks, both Azure writes and therefore opt-in only, are named in the guidance: Arc run command (output capped at 4 KB) and Arc SSH. |
| **Post-deployment** | The finished cluster (Health mode) | Local Identity: the deployment local admin, `RecoveryAdmin` (its password is in the cluster Key Vault); Active Directory: the local administrator, or the domain account you give Sonar. The built-in account is `ASBuiltInAdmin`. | `C:\CloudDeployment\Logs`, `C:\MASLogs`, `C:\ProgramData\AzureConnectedMachineAgent\Log` | RDP is off after deployment. Collection on demand (`Send-DiagnosticData`, the portal's Send logs) needs the AzureEdgeTelemetryAndDiagnostics extension and the Azure Stack HCI Administrator role. |
| **Update** | A solution update | Local Identity: the deployment local admin. Active Directory: the local administrator, or the domain account you give Sonar. Both must be in local Administrators. | `C:\CloudDeployment\Logs`, `C:\MASLogs`, `C:\Observability` | Sonar follows the Azure update run (steps, times, errors) and shows the seed node's log as it is written. Commands on a node: `Start-MonitoringActionplanInstanceToComplete`, `Get-ActionPlanInstance`, `Get-CauReport`. |
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
| After deployment, update, add node, repair | `-Credential` for the local administrator, as the tab says (Sonar switches to the domain account itself once a node reports it is ready). | See the tab |
| A finished run, or no access to the node | `-Replay <recording>`, or no credential at all. | None |

If the log pane says the live logs are unavailable, the message names the reason and the window's tab for your phase says which account and folders to use. The back end retries every 60 seconds, so a node that was rebooting comes back without a restart of Sonar.

## See also

- [Running Sonar, stage by stage](./stages.md) and [by purpose](./run.md)
- [Tour of the page](./tour.md#log-access-window)
- [Configuration](./config.md): `logs.*` and `credential.*`
