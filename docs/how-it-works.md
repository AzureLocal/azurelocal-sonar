# How it works

Sonar has three parts, all started by one script.

| Part | What it does | Source |
|---|---|---|
| Azure poller | Reads the deployment's step tree (validation and deployment), the provisioning lifecycle of each machine, the Arc machines and their extensions, and the activity log | Azure Resource Manager, the same resources the portal reads |
| Log tailer | Follows the deployment log files on the seed node as they grow | PowerShell remoting to the node, or Azure Arc as a fallback |
| Web view | Step tree, timeline, live log stream with filters, node and account panel | Static page served from localhost, live updates over Server-Sent Events |

## Phases Sonar follows

1. **Provisioning** (simplified machine provisioning): machine created → awaiting connection → onboarding to Arc → ready for OS → installing OS → provisioned.
2. **Validation**: every validation step with its result.
3. **Deployment**: every deployment step and sub-step, with live logs from the seed node.

## Read-only

Sonar only reads. It never starts, retries or cancels a deployment.
