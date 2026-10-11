# Repo intent — azurelocal-sonar

**AzL Sonar — real-time monitor for Azure Local deployments. Listens to a deployment while it runs and shows every step, its status and the live deployment logs in a modern local web view. PowerShell back end; nothing to install.**

## What this repo is

The Azure portal shows an Azure Local deployment as a coarse progress view that refreshes slowly and hides the logs. Sonar runs on an admin workstation or jump server, opens a local web page, and follows the deployment end to end:

- the full step tree of validation and deployment (each step, sub-step, status, start and end time, duration, errors) as Azure reports it;
- the live deployment log files on the seed node, streamed as they are written, with filtering and highlighting of warnings and errors;
- which account to use to read those logs at each phase, and when they become available (before, during and after deployment);
- how the machines get ready before it, on either route: simplified machine provisioning (edge machine lifecycle, OS install, Arc onboarding) or OEM image + Arc registration (Arc machine, mandatory extensions).

It is a script you run, not a product you install: `Start-AzlSonar.ps1` starts a local PowerShell back end and opens the browser. Read-only by design: Sonar observes; it never changes the deployment.

## How it relates to other repos

- `azurelocal-beacon` checks the environment **before** deployment (network, DNS, endpoints, target disk). Sonar listens **during** deployment. Beacon sends the signal; Sonar listens for the echo.
- `azurelocal-ztp` automates provisioning the nodes; Sonar shows that provisioning live and then the cluster deployment that follows.
- Complements `azurelocal-ranger` and `azurelocal-s2d-cartographer` (post-deployment ground truth and storage inventory).

## Status

New (10 Oct 2026). Plan: [docs/plan.md](docs/plan.md).
