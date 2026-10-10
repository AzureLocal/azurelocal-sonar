# Getting started

::: warning Under construction
AzL Sonar is new. This page describes the intended experience; see the [plan](./plan.md) for status.
:::

## Requirements

- PowerShell 7.4 or later on an admin workstation or jump server.
- Read access to the Azure resource group that holds the Azure Local instance (signed in with Azure CLI or Az PowerShell).
- Network access to the seed node's management address for live logs (WinRM), or Azure Arc access for the Arc fallback.

## Run

```powershell
./Start-AzlSonar.ps1 -ConfigPath ./config/my-cluster.json
```

Sonar starts a local back end on `http://localhost:<port>` and opens your browser. Close the window or press Ctrl+C to stop. Sonar never changes the deployment.

## Configuration

One file per cluster: subscription, resource group, cluster name, node names, identity model (Local Identity or Active Directory), and the Key Vault secret names that hold the credentials Sonar uses to read node logs. No values are hardcoded.
