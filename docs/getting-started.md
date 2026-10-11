# Getting started

::: warning New
AzL Sonar is new and is being tested live on a lab deployment; see the [plan](./plan.md) for status.
:::

## Requirements

- **PowerShell 7.4 or later** on an admin workstation or jump server (Windows PowerShell 5.1 cannot run Sonar).
- **Az.Accounts**, signed in with `Connect-AzAccount`, with **read access** (Reader) to the resource group that holds the Azure Local instance.
- For live logs, one of:
  - **WinRM** to the seed node (5985/5986) with an account in the node's local Administrators. Workgroup (Local Identity) nodes, and any node reached by IP address, must be in this workstation's WinRM `TrustedHosts`.
  - **SSH** to the seed node with the **Posh-SSH** module (`Install-Module Posh-SSH -Scope CurrentUser`), for when WinRM is blocked. `sshd` must run on the node.
- **Az.KeyVault**, only when the log account comes from Key Vault.

Without log access Sonar still shows the step tree, the phase and the node status from Azure, and tells you why the logs are unavailable.

## Run

```powershell
Connect-AzAccount
Copy-Item ./examples/sonar.config.example.json ./config/my-cluster.json   # then edit it
./Start-AzlSonar.ps1 -ConfigPath ./config/my-cluster.json
```

Sonar asks for the account that reads the logs, starts a local back end on `http://localhost:8642/` and opens your browser. Use `-Port` for another port, `-Credential (Get-Credential)` to pass the account, `-NoBrowser` to skip the browser. Press Ctrl+C to stop. Sonar never changes the deployment, Azure or the nodes.

For a workgroup node or an IP address, add the seed node to `TrustedHosts` first (elevated; Sonar checks it but never changes it):

```powershell
Set-Item WSMan:\localhost\Client\TrustedHosts -Value '192.0.2.11' -Concatenate -Force
```

To look at the page without a deployment, open `http://localhost:8642/?demo=1` (built-in sample data).

## Configuration

One JSON file per cluster: subscription, resource group, cluster name, identity model (`LocalIdentity` or `ActiveDirectory`), the nodes (name, address, Arc resource name, which one is the seed), the log folders and limits, and where the log account comes from (`prompt`, `parameter` or `keyvault` with secret names). No secret ever goes in the file.

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

Every field, its default and its limits are in the [README configuration reference](https://github.com/AzureLocal/azurelocal-sonar#configuration-reference). The defaults tail the folders verified live during a deployment: `C:\CloudContent\MASLogs`, `C:\MASLogs`, `C:\CloudDeployment\Logs` (appears later in the run), `C:\Observability` and `C:\Windows\System32\Bootstrap\Logs`.

## Which account

Use the non-built-in deployment local admin (Local Identity) or the local administrator (Active Directory). Do not use the built-in `Administrator`: deployment renames it to `ASBuiltInAdmin`. The page's **Log access** card shows the account, folders and timing for each phase and your identity model.

## If something does not work

The [README troubleshooting table](https://github.com/AzureLocal/azurelocal-sonar#troubleshooting) covers the sign-in, `TrustedHosts`, access denied, WinRM blocked (SSH fallback), a port in use and a log folder that does not exist yet.
