# Configuration

Sonar ends up with one configuration object, whichever way you configure it: [from the master `infrastructure.yml`](#from-the-master-infrastructureyml), from [commands that fill in a file](./start-here.md#2-commands-that-fill-in-a-config-file), or from a [file written by hand](./start-here.md#3-a-config-file-by-hand-the-older-option). Look at what Sonar will use with:

```powershell
Import-Module ./src/AzlSonar/AzlSonar.psd1
Get-AzlSonarConfig -InfrastructureFile ./infrastructure.yml     # or: -Path ./config/clus01.json
Test-AzlSonarConfig -Path ./config/clus01.json                  # problems only; empty when valid
```

Unknown keys are ignored. Sonar validates at start and lists every problem at once. A commented example with every key is [`examples/sonar.config.commented.jsonc`](https://github.com/AzureLocal/azurelocal-sonar/blob/main/examples/sonar.config.commented.jsonc) (comments are allowed in config files).

## Key reference

Types are JSON types. "Dashboard" says what the key changes on the page.

| Key | Type | Required | Default | Example | What it changes in the dashboard |
| --- | --- | --- | --- | --- | --- |
| `subscriptionId` | string (GUID) | yes | | `00000000-0000-0000-0000-000000000000` | Which subscription every Azure read goes to. Wrong: no data, Azure 403/404 warnings. |
| `resourceGroup` | string | yes | | `rg-example-azl` | The resource group of the cluster, its Arc machines and edge machines. |
| `clusterName` | string | yes | | `clus01` | The cluster name in the top bar and the `deploymentSettings` that gives the step tree. |
| `identityModel` | `LocalIdentity` or `ActiveDirectory` | yes | | `ActiveDirectory` | The account guidance in the Log access window and whether `TrustedHosts` is checked. |
| `provisioningRoute` | `auto`, `simplified`, `oem-image` | no | `auto` | `simplified` | The first mode: **Provisioning (ZTP)** (edge machines) or **Provisioning (OS image)** (node probe). `oem-image` never reads edge machines; `simplified` never starts the node probe. |
| `accessToken` | `true` or `false` | no | `true` | `false` | `false` turns the per-start access token off: any account on the machine can read the page. Single-user machines only. `-NoAccessToken` does the same. |
| `maxEventStreams` | integer 1 to 50 | no | `4` | `4` | Live browser streams served at once; more get 429 and the page polls instead. |
| `pollSeconds` | integer 5 to 3600 | no | `20` | `30` | How often Azure is read; how fresh the page is. `-PollSeconds` overrides it. |
| `nodes` | list | yes (one or more) | | see below | The machine cards, the steps per machine and the log filters. |
| `nodes[].name` | string, unique | yes | | `node01` | The machine's name on the page. |
| `nodes[].address` | string | yes | | `192.0.2.11` | Host name or IP address Sonar connects to for logs (seed) and Arc status (OEM route). |
| `nodes[].arcMachineName` | string | no | resolved | `node01` | The Arc machine to follow. Default: simplified route, the Arc machine the edge machine names; OEM route, the node name. |
| `nodes[].seed` | boolean | no | first node | `true` | The node whose logs are tailed. At most one; none marked means the first node (with a warning). |
| `ztpEvents.path` | string | no | none | `D:\Data\azl-ztp\evidence\ztp-events.jsonl` | The ZTP event file. Without it there are no `[ztp]` log lines and no per-machine ZTP steps. Relative paths are relative to the config file. |
| `recordPath` | string | no | none | `./recordings/clus01.jsonl` | Record every run (as `-Record`, which overrides it). |
| `credential.source` | `prompt`, `parameter`, `keyvault` | no | `prompt` | `keyvault` | Who supplies the log account: asked at start; `-Credential`; or Key Vault. |
| `credential.vault`, `.usernameSecret`, `.passwordSecret` | string | with `keyvault` | | `kv-example`, `log-user`, `log-pass` | Names only, never values. |
| `logs.paths` | list of strings | no | five standard folders | `C:\MASLogs` | Folders tailed on the seed node. |
| `logs.include` / `logs.exclude` | list of patterns | no | `*.log`, `*.txt`, `*.xml` / `*.etl` | `*.log` | Which files are followed. |
| `logs.recurseDepth` | integer 0 to 10 | no | `3` | `3` | Folder levels below each path. |
| `logs.activeWindowMinutes` | integer 1 to 10080 | no | `30` | `30` | Only files written this recently are followed. |
| `logs.maxLinesPerPoll` | integer 1 to 10000 | no | `500` | `500` | Lines per log poll; the rest come next poll. |
| `logs.pollSeconds` | integer 1 to 3600 | no | `pollSeconds` | `10` | How often logs are read. |
| `logs.transport` | `auto`, `winrm`, `ssh` | no | `auto` | `ssh` | How the seed node is reached. |
| `clusterPattern` | `Standard`, `RackAware` | no | `Standard` | `RackAware` | What the page says about the shape of the deployment. |
| `architecture` | `hyperconverged`, `disaggregated` | no | `hyperconverged` | `disaggregated` | Same. |
| `track` | `auto`, `deployment`, `update`, `add-node`, `repair` | no | `auto` | `update` | Which operation is followed after the deployment. |
| `updateTrack` | `auto`, `off` | no | `auto` | `off` | `off` never reads the update resources. |
| `apiVersion`, `apiVersionFallback`, `edgeApiVersion` | string `yyyy-mm-dd` | no | `2026-10-01`, `2025-10-01`, `2026-10-01` | | Change only if Azure rejects the default; Sonar warns when it falls back. |

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
