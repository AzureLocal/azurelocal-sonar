# Configuration

Sonar ends up with one configuration object, whichever way you configure it: [from the master `infrastructure.yml`](#from-the-master-infrastructureyml), from [commands that fill in a file](./start-here.md#2-commands-that-fill-in-a-config-file), or from a [file written by hand](./start-here.md#3-a-config-file-by-hand). Look at what Sonar will use with:

```powershell
Import-Module ./src/AzlSonar/AzlSonar.psd1
Get-AzlSonarConfig -InfrastructureFile ./infrastructure.yml     # or: -Path ./config/clus01.json
Test-AzlSonarConfig -Path ./config/clus01.json                  # problems only; empty when valid
```

Unknown keys are ignored. Sonar validates at start and lists every problem at once. A commented example with every key is [`examples/sonar.config.commented.jsonc`](https://github.com/AzureLocal/azurelocal-sonar/blob/main/examples/sonar.config.commented.jsonc) (comments are allowed in config files).

## Key reference

Types are JSON types. "Dashboard" says what the key changes on the page. "Master file" is the `infrastructure.yml` key that fills it when you use `-InfrastructureFile` (a dash means there is no such key: Sonar's default applies, or you give it another way). Every key below can be changed with `Set-AzlSonarConfig` (run it with no `-Key` to list the keys) (the node keys with `Add-AzlSonarNode` and `Remove-AzlSonarNode`); [Update the configuration](#update-the-configuration) shows how.

| Key | Type | Required | Default | Example | Master file | What it changes in the dashboard |
| --- | --- | --- | --- | --- | --- | --- |
| `subscriptionId` | string (GUID) | yes | | `00000000-0000-0000-0000-000000000000` | `azure.subscription_id` | Which subscription every Azure read goes to. Wrong: no data, Azure 403/404 warnings. Details shows only its first 8 characters. |
| `resourceGroup` | string | yes | | `rg-example-azl` | `azure.resource_group` | The resource group of the cluster, its Arc machines and edge machines. |
| `location` | string | no | none | `eastus` | `azure.location` | The region shown in **Details**. Sonar does not use it to reach Azure. |
| `clusterName` | string | yes | | `clus01` | `cluster.name` | The cluster name in the top bar and the `deploymentSettings` that gives the step tree. |
| `identityModel` | `LocalIdentity` or `ActiveDirectory` | yes | | `ActiveDirectory` | `scenario.identity` | The account guidance in the Log access window, the **This deployment** note there, and whether `TrustedHosts` is checked. |
| `provisioningRoute` | `auto`, `simplified`, `oem-image` | no | `auto` | `simplified` | `scenario.os_install` (`simplified`, `iso`) | The first mode: **Provisioning (ZTP)** (edge machines) or **Provisioning (OS image)** (node probe). `oem-image` never reads edge machines; `simplified` never starts the node probe. |
| `accessToken` | `true` or `false` | no | `true` | `false` | - | `false` turns the per-start access token off: any account on the machine can read the page. Single-user machines only. `-NoAccessToken` does the same. |
| `maxEventStreams` | integer 1 to 50 | no | `4` | `4` | - | Live browser streams served at once; more get 429 and the page polls instead. |
| `pollSeconds` | integer 5 to 3600 | no | `20` | `30` | - (use `-PollSeconds`) | How often Azure is read; how fresh the page is. `-PollSeconds` overrides it. |
| `nodes` | list | yes (one or more) | | see below | `nodes[]` | The machine cards, the steps per machine and the log filters. |
| `nodes[].name` | string, unique | yes | | `node01` | `nodes[].name` | The machine's name on the page. |
| `nodes[].address` | string | yes | | `192.0.2.11` | the management port's `ip_address` | Host name or IP address Sonar connects to for logs (seed) and Arc status (OEM route). |
| `nodes[].arcMachineName` | string | no | resolved | `node01` | `nodes[].arc_machine_name` | The Arc machine to follow. Default: simplified route, the Arc machine the edge machine names; OEM route, the node name. |
| `nodes[].seed` | boolean | no | first node | `true` | the first node | The node whose logs are tailed. At most one; none marked means the first node (with a warning). |
| `ztpEvents.path` | string | no | none | `D:\Data\azl-ztp\evidence\ztp-events.jsonl` | `provisioning.simplified.evidence_path` + `ztp-events.jsonl` | The ZTP event file. Without it there are no `[ztp]` log lines and no per-machine ZTP steps. Relative paths are relative to the config file. |
| `discoveryPath` | string | no | none | `D:\Data\azl-ztp\evidence\discovery` | `provisioning.simplified.evidence_path` + `discovery` | The folder the toolkit's `Invoke-HardwareDiscovery.ps1` wrote with `-OutputPath` (one `<ServiceTag>.json` per node and `discovery-summary.json`), or one of those files. Sonar reads it (never an iDRAC) for the **Discovery** stage that comes before ZTP: service tag, ports and MACs, the suggested management port, the BOSS card. Without it the Discovery tile is grey and says how to get its data. Relative paths are relative to the config file. |
| `osConfigEventsPath` | string | no | none | `D:\Data\azl-ztp\evidence\os-configuration-events.jsonl` | `provisioning.simplified.evidence_path` + `os-configuration-events.jsonl` | The OS configuration event file written by the toolkit's `Invoke-AzureLocalOsConfiguration.ps1` (its default is `os-configuration-events.jsonl` in the report directory; `-EventLogPath` moves it). Without it the **OS configuration** mode has no steps and there are no `[osconfig]` log lines. Relative paths are relative to the config file. |
| `armEventsPath` | string | no | `<temp>/azl-arm-<cluster.name>/arm-deployment-events.jsonl` with the master file, else none | `D:\Data\azl-arm\clus01\arm-deployment-events.jsonl` | `cluster.name` (the toolkit's default report directory) | The ARM Validate and Deploy event file written by the toolkit's `Invoke-AzureLocalArmDeployment.ps1` (`-ReportDirectory` moves it). Without it the **Validate** and **Deployment** modes show only what Azure reports and there are no `[arm]` log lines. Relative paths are relative to the config file. See [Validate and Deploy from the toolkit](./arm-run.md). |
| `verificationEventsPath` | string | no | `<evidence folder>/arm-report/verification/live/precluster-verification-events.jsonl` with the master file (without an evidence folder `<temp>/azl-arm-<cluster.name>/arm-report/verification/live/...`), else none | `D:\Data\azl-ztp\evidence\arm-report\verification\live\precluster-verification-events.jsonl` | `provisioning.simplified.evidence_path` (the `arm-report` folder inside it) | The pre-cluster verification gate's event file (or the folder that holds it: the file name is added). Written by the toolkit's gate next to `report.json` and `summary.md`. Without it the **Verification** mode shows nothing and there are no `[verify]` log lines. The file is read whole and the latest run in it is shown; a file the gate replaces for a new run is shown as it is now. Relative paths are relative to the config file. Registered in the toolkit's variables registry as `tools.sonar.config_keys.Config.verificationEventsPath`. |
| `logAccounts` | object | no | none | `{ "local": { "username": "azl-admin" }, "domain": { "netbios": "IIC", "username": "svc-join", "passwordRef": "keyvault://kv-example/svc-join-password" } }` | `identity.local_admin`, `identity.active_directory` (see below) | Which account reads a node's logs: `local` while it is a workgroup machine, `domain` once the OS configuration has reported both `DomainJoined` and `DomainAdminsConfigured`. Names only plus a `keyvault://<vault>/<secret>[/<version>]` reference; a password is refused. `domain.maxRejections` (whole number 1 to 5, default 2) is how many rejections the circuit breaker allows before it stops trying the domain account until its password changes, and also the most connection attempts with the domain account in flight at once: set it below the domain's lockout threshold. Edit the file to change it (`Set-AzlSonarConfig` does not set objects). A reference that is not valid (a plain password, a vault name Azure would not accept, a version that is not 32 hexadecimal characters) is a problem at load, naming `logAccounts.domain.passwordRef`. See [Log access](./log-access.md#the-lockout-circuit-breaker). |
| `recordPath` | string | no | none | `./recordings/clus01.jsonl` | - (use `-Record`) | Record every run (as `-Record`, which overrides it). |
| `credential.source` | `prompt`, `parameter`, `keyvault` | no | `prompt` | `keyvault` | - (always `prompt`) | Who supplies the log account: asked at start; `-Credential`; or Key Vault. |
| `credential.vault` | string | with `keyvault` | | `kv-example` | - | Name of the Key Vault that holds the log account (a name, never a value). Needs Az.KeyVault. |
| `credential.usernameSecret` | string | with `keyvault` | | `log-user` | - | Name of the secret that holds the user name. |
| `credential.passwordSecret` | string | with `keyvault` | | `log-pass` | - | Name of the secret that holds the password. |
| `logs.paths` | list of strings | no | five standard folders | `C:\MASLogs` | - | Folders tailed on the seed node. |
| `logs.include` | list of patterns | no | `*.log`, `*.txt`, `*.xml` | `*.log` | - | Which files are followed. |
| `logs.exclude` | list of patterns | no | `*.etl` | `*.etl` | - | Which files are skipped. May be empty. |
| `logs.recurseDepth` | integer 0 to 10 | no | `3` | `3` | - | Folder levels below each path. |
| `logs.activeWindowMinutes` | integer 1 to 10080 | no | `30` | `30` | - | Only files written this recently are followed. |
| `logs.maxLinesPerPoll` | integer 1 to 10000 | no | `500` | `500` | - | Lines per log poll; the rest come next poll. |
| `logs.pollSeconds` | integer 1 to 3600 | no | `pollSeconds` | `10` | - | How often logs are read. |
| `logs.transport` | `auto`, `winrm`, `ssh` | no | `auto` | `ssh` | - | How the seed node is reached. |
| `clusterPattern` | `Standard`, `RackAware` | no | `Standard` | `RackAware` | - | The **This deployment** note in the Log access window (what Azure Local needs for that shape). |
| `architecture` | `hyperconverged`, `disaggregated` | no | `hyperconverged` | `disaggregated` | - | Same: a note for a SAN (disaggregated) deployment. |
| `internalDns` | `true` or `false` | no | `false` | `true` | - | Same: a note for Internal DNS (preview, release 2609; Local Identity only; ignored, with a warning, for Active Directory). |
| `track` | `auto`, `deployment`, `update`, `add-node`, `repair` | no | `auto` | `update` | - | Which operation is followed after the deployment. `health` is accepted and treated as `auto` (there is no Health mode). |
| `monitor` | `Auto`, `Discovery`, `Provisioning`, `OsConfiguration`, `Verification`, `Validate`, `Deployment`, `Update`, `AddNode`, `Repair` | no | `Auto` | `OsConfiguration` | - | Which stage to watch. `Auto` follows the whole flow; one value shows only that tile and reads only the sources it needs. `Start-AzlSonar.ps1 -Monitor` overrides it. See [Run one stage on its own](./run.md#run-one-stage-on-its-own--monitor). |
| `updateTrack` | `auto`, `off` | no | `auto` | `off` | - | `off` never reads the update resources. |
| `apiVersion` | string `yyyy-mm-dd` | no | `2026-10-01` | | - | The ARM version for the cluster and `deploymentSettings`. Change only if Azure rejects the default. |
| `apiVersionFallback` | string `yyyy-mm-dd` | no | `2025-10-01` | | - | Tried once when Azure rejects `apiVersion`; Sonar warns when it falls back. |
| `edgeApiVersion` | string `yyyy-mm-dd` | no | `2026-10-01` | | - | The ARM version for edge machines and their `ProvisionOs` job. |

`credential.password`, `.secret` and `.secretValue` are refused: secrets never go in the file.

## From the master infrastructure.yml

`-InfrastructureFile` (and `ConvertTo-AzlSonarConfig`) reads the master file (schema 5, azurelocal-toolkit `config/infrastructure/`) with a small reader built into Sonar. It needs neither the toolkit nor a YAML module. It reads only these keys:

| infrastructure.yml (schema 5) | Sonar config | Notes |
| --- | --- | --- |
| `_metadata.schema_version` | (checked) | Must be `5.x`. |
| `azure.subscription_id` | `subscriptionId` | Required. |
| `azure.resource_group` | `resourceGroup` | Required. |
| `azure.location` | `location` | Optional. The region shown in **Details** in the top bar; Sonar does not use it to reach Azure. |
| `cluster.name` | `clusterName` | Required. A ZTP-only file (`_metadata.scope: ztp`) has no cluster section: give it one, or use a config file. |
| `scenario.os_install`: `simplified` or `iso` | `provisioningRoute`: `simplified` or `oem-image` | Required. |
| `scenario.identity`: `active_directory` or `local_identity` | `identityModel`: `ActiveDirectory` or `LocalIdentity` | Required. |
| `nodes[].name` | `nodes[].name` | |
| `nodes[].network_adapters[]` with `roles` containing `management` and `ip_assignment` `static` or `dhcp_reservation`: its `ip_address` | `nodes[].address` | The first such port. A team partner with `ip_assignment: none` is skipped. Files of schema 5.0 and 5.1 without `network_adapters` use `nodes[].management.ip_address`. |
| `nodes[].arc_machine_name` | `nodes[].arcMachineName` | When set. |
| the first node in `nodes` | `nodes[].seed: true` | Schema 5.3 has no seed key, so the first listed node is the seed. |
| `identity.local_admin.username` | `logAccounts.local.username` | The local account that reads a node's logs while it is a workgroup machine (shown as `workgroup: using azl-admin`). Only the name: the password comes from `-Credential`, the prompt or `credential.source`. |
| `identity.active_directory.netbios_name` | `logAccounts.domain.netbios` | Active Directory only. The `NETBIOS` of the domain account `NETBIOS\username` that reads a node's logs once the node has reported both `DomainJoined` and `DomainAdminsConfigured`. |
| `identity.active_directory.domain_join_account.username` | `logAccounts.domain.username` | Active Directory only. The domain account **you supply**: it reads a node's logs once the node has reported both `DomainJoined` and `DomainAdminsConfigured`. Read defensively: absent is fine (the local account stays). |
| `identity.active_directory.domain_join_account.password` | `logAccounts.domain.passwordRef` | Must be a `keyvault://<vault>/<secret>` reference, optionally `/<version>` (32 hexadecimal characters) to pin the secret version. Sonar reads the secret with Az.KeyVault when the first node needs it, keeps it as a secure string and never shows, logs or records it. A value that is not a valid reference stops the import with a message that names this key and does not repeat the value. See [Log access](./log-access.md#which-account-reads-which-node-local-first-then-the-domain-account). |
| `identity.active_directory.lcm_user.*` | (not read) | Sonar never uses the LCM user, for the domain credential or for anything else. If `lcm_user` is the only account in the file, there is no domain account and the local account stays. |
| `provisioning.simplified.evidence_path` + `discovery` | `discoveryPath` | The `discovery` folder inside the evidence folder (run the toolkit's discovery with `-OutputPath <evidence_path>\discovery`). Set whenever `evidence_path` is given. |
| `provisioning.simplified.evidence_path` + `os-configuration-events.jsonl` | `osConfigEventsPath` | The evidence folder next to the ZTP event file. On the simplified route it follows `ztpEvents.path` (same default folder); on the ISO route it is set only when `evidence_path` is given. |
| `provisioning.simplified.evidence_path` + `ztp-events.jsonl` | `ztpEvents.path` | Simplified route only. Without `evidence_path`, ZTP's default `%ProgramData%\AzureLocalZtp\<site_name>\evidence` (needs `provisioning.simplified.site_name`). |

Everything else keeps Sonar's defaults. The credential is never taken from the file: it only holds `keyvault://` references, which Sonar does not read or resolve. Give the log account with `-Credential` or answer the prompt. Override the poll interval with `-PollSeconds`.

Missing or unknown values are reported with the schema path:

```text
Infrastructure file (...\infrastructure.yml) does not give Sonar what it needs:
 - azure.resource_group : is missing; Sonar needs the resource group of the cluster (infrastructure.yml, schema 5)
 - scenario.os_install : is 'pxe'; use simplified or iso (infrastructure.yml, schema 5)
 - nodes[1].network_adapters : node 'node02' has no port with roles management, ip_assignment static or dhcp_reservation and an ip_address (infrastructure.yml, schema 5)
```

### What the YAML reader supports and refuses

Sonar reads `infrastructure.yml` with its own small YAML reader (no YAML module, no toolkit). It reads the subset the schema uses:

- Block maps and block lists (a list may sit at the same indent as its key), flow lists and maps written on one line (`[a, b]`, `{ k: v }`).
- Plain, `'single'` and `"double"` quoted values on one line. A `#` starts a comment only after a space, so `https://example.com#frag` is a value. Keys are always text (`712: storage` is the key `712`).
- Block scalars `|` and `>`, with `-` or `+`: blank lines, indentation and `#` lines inside the block are kept as text.
- Whole numbers up to 9 digits (not `007`) are numbers, `1.5` is a number, `true` and `false` are booleans, `null` and `~` are empty. Everything else, including `yes`, is text.
- A `---` document start (with or without a comment), a CRLF file and a byte order mark.

It refuses these, with `YAML line N: ...` (the message names the line, never its text):

- Duplicate keys in one map.
- A quoted value, a `[ ... ]` or a `{ ... }` that continues on the next line (put it on one line, or use a block list or map), and text after a closing quote or bracket.
- A nested list on one line (`- - a`), anchors, aliases and tags (`&`, `*`, `!`), block scalar headers with an indentation number (`|2`).
- More than one document, or content after `...`; tab indentation.
- Input over 2 MB, and nesting deeper than 40 levels.

## Update the configuration

### Change any one key (without an editor)

`Set-AzlSonarConfig` changes one key of a config file, checks the result with the same rules Sonar applies at start, and refuses (writing nothing, naming the problem) a value that would make the file invalid:

```powershell
Import-Module ./src/AzlSonar/AzlSonar.psd1
Set-AzlSonarConfig                                                     # lists every key it can set, its kind and allowed words
Set-AzlSonarConfig -Path ./config/clus01.json -Key pollSeconds -Value 30
Set-AzlSonarConfig -Path ./config/clus01.json -Key identityModel -Value ActiveDirectory
Set-AzlSonarConfig -Path ./config/clus01.json -Key logs.paths -Value 'C:\MASLogs', 'C:\CloudDeployment\Logs'   # a list takes several values
Set-AzlSonarConfig -Path ./config/clus01.json -Key logs.transport -Remove                                      # back to the default
Set-AzlSonarConfig -Path ./config/clus01.json -Key pollSeconds -Value 60 -WhatIf                               # show, do not write
```

The key is the one in the [key reference](#key-reference), not case sensitive. Number keys take a whole number, `accessToken` and `internalDns` take `true` or `false`. Keys with a fixed list of words take only those words. It refuses secrets (`credential.password` and the like) and `nodes` (use `Add-AzlSonarNode` and `Remove-AzlSonarNode`). Like those, it rewrites the file as plain JSON, so comments in a hand-commented file are lost: to keep comments, edit the file with an editor and run `Test-AzlSonarConfig` afterwards. A running Sonar keeps the old value until it is restarted ([below](#what-happens-to-a-running-sonar)).

With the master file there is nothing to set: change `infrastructure.yml` (the table [above](#from-the-master-infrastructureyml) says which key feeds which setting).

### Add or remove a node

- **Master file:** add the machine to `nodes` in `infrastructure.yml`. The running Sonar logs a notice; restart it to track the node ([below](#what-happens-to-a-running-sonar)).
- **Config file:** `Add-AzlSonarNode -Path ./config/clus01.json -Name node03 -Address 192.0.2.13` and `Remove-AzlSonarNode -Path ... -Name node03`. `-Seed` makes the node the seed node. Removing the seed passes the seed to the first remaining node. These commands rewrite the file as plain JSON, so comments in a hand-commented file are lost.
- **Generated config file:** after the master file changes, `ConvertTo-AzlSonarConfig -InfrastructureFile ./infrastructure.yml -OutFile ./config/clus01.json -Force`. Hand edits in the generated file are replaced.

### Change the route or the identity model

Master file: `scenario.os_install` and `scenario.identity`. Config file: edit `provisioningRoute` (`simplified`, `oem-image`, `auto`) and `identityModel`. Restart Sonar. The route decides which provisioning mode and which workers run; the identity model decides the log-account guidance.

### Point Sonar at a different cluster

Change `subscriptionId`, `resourceGroup` and `clusterName` (master file: `azure.subscription_id`, `azure.resource_group`, `cluster.name`) and the nodes. Or keep one file per cluster and start Sonar with the right `-InfrastructureFile` or `-ConfigPath`. Sign in to the subscription first (`Connect-AzAccount`, `Set-AzContext`). Restart Sonar.

### Move the event file

Master file: `provisioning.simplified.evidence_path`. Config file: `ztpEvents.path`. Restart Sonar. Sonar reads the file from its start after a restart.

### Change the poll interval

`-PollSeconds 30` on the command line (overrides the file), or `pollSeconds` in a config file. Log polling follows it unless `logs.pollSeconds` is set. 5 to 3600.

### Change the credential source

`credential.source` in a config file: `prompt` (asked at start), `parameter` (use `-Credential`), or `keyvault` (with `credential.vault`, `usernameSecret`, `passwordSecret`, names only). With `-InfrastructureFile` the source is `prompt`; `-Credential` always wins over it. To use Key Vault with the master file, generate a config file with `ConvertTo-AzlSonarConfig` and set `credential` in it.

### What happens to a running Sonar

The pollers and the log tailer are built when Sonar starts, so a change to the file does **not** change a running Sonar. What it does:

- **With `-InfrastructureFile`:** Sonar checks the file's modification time every 60 seconds. When it changed and the node set differs (a node added, removed or at a new address) Sonar writes a notice to the log pane, for example `[sonar] The master infrastructure file changed its node set (added: example-n04). Nodes now: ... Restart Sonar to track the change.`, and keeps running with the nodes it has. A file that cannot be read (for example half saved) is reported once and the old nodes stay in use. Restart Sonar to pick the change up.
- **With `-ConfigPath`:** the file is read once at start. Restart Sonar after editing it.

Live re-reading of the node set (adding pollers without a restart) is not built: it would mean rebuilding the workers around the running page and recording.

## Common mistakes

| You see | Cause and fix |
| --- | --- |
| `Sonar config (...) is not valid: - subscriptionId must be a GUID.` | The subscription is a name, not its ID. Use the GUID (`(Get-AzContext).Subscription.Id`). |
| `nodes must list at least one node.` | A new file has no nodes: `Add-AzlSonarNode`. |
| `nodes[0].address is required (host name or IP address).` | A node has a name but no address. |
| `Only one node can be the seed node (seed: true).` | Two nodes marked `seed`. `Add-AzlSonarNode -Seed` clears the old mark. |
| `identityModel must be LocalIdentity or ActiveDirectory.` | The config file wants those words; the master file's `local_identity` and `active_directory` are converted for you. |
| `credential.password is not allowed: never put secrets in the config.` | Remove it. Use the prompt, `-Credential` or Key Vault. |
| `Give -ConfigPath or -InfrastructureFile, not both.` | Choose one. |
| `Infrastructure file (...) is not valid YAML: YAML line N: ...` | Tabs, anchors (`&`, `*`) and several documents are not supported; the message names the line. |
| `_metadata.schema_version : is '4.2.0'; Sonar reads schema 5.x files` | Upgrade the file with the toolkit's migration. |
| `cluster.name : is missing` | A ZTP-only file has no cluster. Add `cluster.name`, or use a config file. |
| `... already exists. Use -Force to replace it.` | `New-AzlSonarConfig` and `ConvertTo-AzlSonarConfig` do not overwrite silently. |
| The new node is not on the page | Sonar was not restarted after the file changed (see above). |
| ZTP lines are missing | `ztpEvents.path` (or `provisioning.simplified.evidence_path`) points to a folder that is not the one ZTP writes to, or Sonar runs on a machine that cannot read it. |
