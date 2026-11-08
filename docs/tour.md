# Tour of the page

What is on the page, top to bottom. The screenshots are Sonar's own demo data (`?demo=1&route=simplified`: three machines of a ZTP run, example names only). Everything on the page is read-only.

![The page during a ZTP run: top bar, the six modes, the summary with a card per machine, the steps and the live logs](images/tour-main.png)

## The top bar

From left to right: the brand, the **cluster name**, the **ⓘ Details** button, the run status, then on the right the connection state, **Log access**, **Export**, the **?** button and the theme toggle.

- **Status.** A chip (*Running*, *Done*, *Failed*, *Waiting*), the **Elapsed** time since the first machine or step started, and **Updated N s ago** (when Azure last answered; it turns amber when the answer is late).
- **Connection.** *Live* (server-sent events), *Polling*, *Offline, retrying*, *Demo* or *Replay (not live)*.
- **Log access** opens the [Log access window](#log-access-window). The dot says how the node logs are read: **green** live from the seed node, **amber** Azure only (the node logs are not available), **red** nothing answers.
- **Export** downloads the whole run as one JSON bundle (hidden in a replay).
- **?** opens the Help box ([below](#help-box)). The sun/moon button switches the light and dark theme; the choice is remembered in this browser.

## Details: what Sonar collected and is using

![The Details pop-down](images/tour-details.png)

The **ⓘ Details** button opens a pop-down that answers "what is Sonar actually working from?". Each value shows where it came from and how old it is.

| Group | What it shows |
| --- | --- |
| **Target** | Cluster, resource group (with a copy button), the subscription as its first 8 characters only, the region. |
| **Mode** | The route (simplified provisioning, ZTP, or OEM image + Arc registration) and the identity model, with one line on what it means. |
| **Nodes** | Each machine's name and address, and which one is the seed node (the node whose logs are read). |
| **Sources** | How often Sonar reads Azure and when Azure last answered; the ZTP event file with its event count and the age of the last event; whether the node logs are live. |
| **Config** | Which file Sonar read (`infrastructure.yml` or the config file), when, and how often it is checked; **Not set** items with the key to set; the Sonar version. |

Secrets are never shown: a credential appears only as *set* or *not set*, and the subscription id only as its first 8 characters. The same data is served at `/api/details` (read-only, this machine only).

## The six modes

The row under the top bar has one tile per mode: **Provisioning (ZTP)**, **OS configuration**, **Validate**, **Deployment**, **Update**, **Health**, six equal tiles. Each has a status icon (✓ done, a pulsing ● running, ○ waiting, ✕ failed), the name and a state line such as *2 of 3 machines ready*, *Step 3 of 7*, *Done* or *Passed*.

- The tile of the mode that is happening now is selected when the page opens. Click any tile to look at another mode: the summary box and the Steps box switch to it.
- A tile that has not started is grey and has no state line. Hover it to see when it starts (*Starts after validation passes*).
- **OS configuration** sits between Provisioning and Validate. It shows *2 of 3 converged* (and *1 retrying*) while the toolkit's run works, turns red when a machine fails, and is green only when every machine has converged; a finished plan with changes pending reads *Plan ready* and stays grey. Without `osConfigEventsPath` it is grey and the hover text says how to get its data. The page opens on it once ZTP is complete and an OS configuration run has started. [What it shows](stages.md#os-configuration)
- There are always six tiles. On the OEM image route the first tile reads **Provisioning (OS image)** instead of *Provisioning (ZTP)*. A run Sonar joined after provisioning has no machine data: the first tile is grey and its hover text says so (Sonar cannot tell whether provisioning was done, so it does not tick it).

## The summary box

The title and status chip of the selected mode, one sentence that says where things stand (and, when something blocks, what), when the mode started, and **a card per machine**.

A card shows the full machine name, its state in plain words (Azure's raw value is in the tooltip), the Azure Arc connection, a progress bar while it runs, and the one thing it waits on, or **Next: OS configuration** when ZTP is done. **Click a card** to look at that machine only: the steps and the logs follow it. Click it again to clear.

## Steps

![An Azure step with its details shown under it](images/tour-azure-step.png)

The steps of the selected mode, with a short description under every step name. In the provisioning mode they are grouped per machine. Steps that run in Azure carry an **Azure** badge.

- **Click an Azure step** (for example *RegisterMachine* or *InstallOs*): its status, start and end, what Azure says and any error are shown under it. The logs are left alone, because an Azure step writes nothing to a node log.
- **Click a node step** (the ZTP stages *Management address*, *Management address on the management NIC* and *BIOS restored*; the OEM image route's *OS image update* and *Bootstrap*; the deployment steps): the live logs filter to that machine and that step. For a ZTP stage the logs show the ZTP event lines of that stage; for the other node steps, the step's time window.
- **Go to current step** jumps to the step that is running (switching mode if needed); **Collapse all** folds the tree.

## Live logs

![The empty-filter message](images/tour-empty-filter.png)

The live log pane has the **All / Warnings+ / Errors** filter, the search box (press `/` to focus it; matches are highlighted), the file filter, the line, warning and error counts, one chip with a × for each filter that is on, a **new lines ↓** button while you are scrolled up, **Follow**, and the status line *Showing N of M lines*.

When a filter shows nothing, the pane says why. A step that has produced no lines yet says so (*This step has produced no lines on this node yet*) and offers **Show all lines for this node** and **Clear filter**.

## Log access window

![The Log access window](images/tour-log-access.png)

The **Log access** button opens a window with everything about reading the node logs: the identity, the status line (*Log access: Tailing node …, as supplied, last line 4 s ago*), and one tab per phase (Provisioning, Validation, Deployment, Post-deployment, Update, Add node, Repair, with *(current phase)* on the active one). For each phase: **Account**, **Where** (every folder), **When**, **How**, **This deployment**, **Confidence** and **Source**. Confidence says whether the entry was confirmed on a live deployment; if the logs are not where an unconfirmed entry says, please open an issue on GitHub. Close it with **Close**, `Esc` or a click outside.

## The OS configuration mode

![The OS configuration mode](images/tour-osconfig.png)

Between Provisioning and Validate. The summary has a card per machine: the method chip (**ZTP** or **ISO**, *expected* until the run resolves it, *differs from the file* with a warning when the master file says otherwise), the transport, the step it is on, *Retried* and *Restarted* counts, the account that reads its logs, and, during a guarded network change, the time left to confirm. The Steps box has the machine's steps with a stage chip each (*Planned*, *OK*, *Changing*, *Applied*, *Verified*, *Failed*, *Blocked*, *Not applicable*) and the toolkit's text; the **Azure** badge marks a step that runs as an Arc Run Command. **Details** lists the method, transport and versions of every machine. The full description is [here](stages.md#os-configuration). The screenshot is the demo (`?demo=1&route=osconfig`).

## Help box

![The Help box](images/tour-help.png)

The **?** button shows the Sonar version, links to the documentation (running Sonar stage by stage, updating the config, troubleshooting) and the GitHub repository, and the license. The version and the links come from the Sonar back end.

## Dark theme and narrow screens

![The dark theme](images/tour-dark.png)

The theme follows the system setting until you pick one with the toggle. On a screen under 900 px the tiles use two columns, the summary, the steps and the logs stack, and the page scrolls; the steps and the logs keep a fixed height and scroll inside.

![A narrow window](images/tour-narrow.png)
