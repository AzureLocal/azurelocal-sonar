# Start here

Pick what you want to do. Each purpose has its own section in [Running Sonar](./run.md), with the commands, what Sonar shows, what to expect and the access it needs. How to change the configuration afterwards is in [Configuration](./config.md).

| I want to... | Go to |
| --- | --- |
| Watch a ZTP run (simplified machine provisioning), machine by machine | [Watch a ZTP run](./run.md#watch-a-ztp-run) |
| Watch machines come up from an OEM image or an ISO and register with Arc | [Watch the OEM image or ISO route](./run.md#watch-the-oem-image-or-iso-route) |
| Follow OS configuration, then the Validate step in Azure | [Watch OS configuration and Validate](./run.md#watch-os-configuration-and-validate) |
| Follow a deployment: step tree, live logs from the seed node | [Watch a deployment](./run.md#watch-a-deployment) |
| Look at an existing cluster without touching it, and keep a record | [Read-only audit and recording](./run.md#read-only-audit-and-recording-of-an-existing-cluster) |
| Run it from a pipeline or an unattended session | [Pipeline or unattended](./run.md#run-from-a-pipeline-or-an-unattended-session) |
| Record a session and share it | [Record and share](./run.md#record-and-share-a-session) |
| Restart Sonar in the middle of a run | [Restart mid-run](./run.md#restart-sonar-mid-run) |
| Change the config: add a node, change the route, point it at another cluster | [Update the configuration](./config.md#update-the-configuration) |

## Three ways to configure Sonar

All three end in the same configuration object, so everything after the start behaves the same.

### 1. From the master infrastructure file (the default)

One file describes the instance for ZTP, OS configuration, the ARM deployment and Sonar: `infrastructure.yml` (schema 5, azurelocal-toolkit `config/infrastructure/`). Sonar reads it directly. Nothing to write or keep in step.

```powershell
Connect-AzAccount
./Start-AzlSonar.ps1 -InfrastructureFile ./infrastructure.yml
```

Add a machine to the file and Sonar notices (it logs a notice to restart, see [what happens to a running Sonar](./config.md#what-happens-to-a-running-sonar)). To keep a config file that you can commit or edit by hand, generate it once:

```powershell
Import-Module ./src/AzlSonar/AzlSonar.psd1
ConvertTo-AzlSonarConfig -InfrastructureFile ./infrastructure.yml -OutFile ./config/clus01.json
```

Which keys are read, and where they land: [From the master infrastructure.yml](./config.md#from-the-master-infrastructureyml). The file only holds `keyvault://` references and Sonar never reads them: the account that reads the logs comes from `-Credential` or a prompt.

### 2. Commands that fill in a config file

```powershell
Import-Module ./src/AzlSonar/AzlSonar.psd1

# Guided: asks for each value. Signed in to Azure, it offers your subscriptions and pre-fills the resource group.
New-AzlSonarConfig -Path ./config/clus01.json -Interactive

# Or in one go:
New-AzlSonarConfig -Path ./config/clus01.json -SubscriptionId <subscription-id> -ResourceGroup rg-example-azl `
    -ClusterName clus01 -Route simplified -IdentityModel ActiveDirectory
Add-AzlSonarNode -Path ./config/clus01.json -Name node01 -Address 192.0.2.11 -Seed
Add-AzlSonarNode -Path ./config/clus01.json -Name node02 -Address 192.0.2.12

Test-AzlSonarConfig -Path ./config/clus01.json     # says what is missing, naming the key
Get-AzlSonarConfig  -Path ./config/clus01.json     # the configuration Sonar will run with
./Start-AzlSonar.ps1 -ConfigPath ./config/clus01.json
```

The guided setup never asks for or stores a password.

### 3. A config file by hand (the older option)

Copy [`examples/sonar.config.commented.jsonc`](https://github.com/AzureLocal/azurelocal-sonar/blob/main/examples/sonar.config.commented.jsonc): every key is explained in it, with which are required and the defaults. Then `./Start-AzlSonar.ps1 -ConfigPath ./config/clus01.json`. `-ConfigPath` works exactly as before.

### Started with nothing?

`./Start-AzlSonar.ps1` with no arguments uses `./sonar.config.json` or `./config/sonar.config.json` when one exists. Otherwise it prints these three ways with the exact commands and, in an interactive session, offers to run the guided setup.
