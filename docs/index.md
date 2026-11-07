---
layout: home

hero:
  name: AzL Sonar
  text: Listen to your Azure Local deployment
  tagline: Every step, its status and the live deployment logs, in real time. PowerShell back end, modern local web view, nothing to install. Read-only.
  actions:
    - theme: brand
      text: Start here
      link: /start-here
    - theme: alt
      text: Getting started
      link: /getting-started
    - theme: alt
      text: How it works
      link: /how-it-works

features:
  - title: The whole deployment, live
    details: Provisioning, validation and deployment as one step tree with status, timestamps, durations and errors, refreshed faster than the portal.
  - title: Live logs from the seed node
    details: Stream the deployment log files while they are written, with search, filters and warning/error highlighting, linked to the step that produced them.
  - title: Knows which account and when
    details: For Local Identity and Active Directory deployments, Sonar shows which account reads the logs in each phase and when each log appears.
  - title: Pairs with Beacon
    details: Beacon checks the environment before deployment. Sonar listens while it runs.
---

## Run it and configure it

- [Start here](/start-here): pick your purpose; the three ways to configure Sonar (the master `infrastructure.yml`, guided prompts, a file by hand).
- [Running Sonar, by purpose](/run) and [stage by stage](/stages): the commands, what the page shows, what done and failed look like and the access needed, for each ZTP stage, Validate, Deployment, Update, Health, add node and repair, and replay.
- [Log access](/log-access): the account and folders for every phase, and how Sonar reaches the node.
- [Configuration](/config): every key, the master-file mapping, and how to update the file (`Set-AzlSonarConfig`).

## Reference

- [What Sonar reads](/how-it-works#what-sonar-reads): the read-only Azure calls and node reads Sonar makes.
- The Azure, Redfish and Configurator app calls of a ZTP run are documented in the ZTP docs: [API reference](https://github.com/AzureLocal/azurelocal-ztp/blob/main/docs/appendix/api-reference.md) and [The Configurator app API](https://github.com/AzureLocal/azurelocal-ztp/blob/main/docs/appendix/configurator-app-api.md).
