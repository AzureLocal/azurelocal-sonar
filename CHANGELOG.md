# Changelog

All notable changes to AzL Sonar are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/) and this project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Unreleased

### Features

* **api:** `Invoke-AzlSonarApi` (exported by the module, and `scripts/Invoke-AzlSonarApi.ps1`) calls the read-only API the supported way: the access-token handshake with a session cookie container, `-Since`/`-All` paging of `/api/logs` that reports gaps (lines that left the ring buffer) and Sonar restarts (`server` changed), `-Follow` for `/api/events` as objects, `-OutFile` for `/api/export`, clear errors for 401, 403, 404, 405 and 429 (`Retry-After` honoured), timeouts, and no token in any output. Replaces the function pasted into `docs/api.md`.
* **api:** `Start-AzlSonar.ps1 -TokenFile <path>` (and the `tokenFile` config key) writes the access token, and only the token, to a file readable by the current user only (Windows ACL without inheritance, Linux mode 600) and removes it when Sonar stops, so automation need not scrape the launch output. The launch output shows the path and not the token. A path that holds a file that is not a Sonar token file is refused unless `-Force`.
* **config:** `Start-AzlSonar.ps1 -InfrastructureFile <infrastructure.yml>` builds Sonar's configuration in memory from the master infrastructure file (schema 5): subscription, resource group, cluster, route (`scenario.os_install`), identity model (`scenario.identity`), the nodes and their management addresses (the management port's `ip_address`, static or `dhcp_reservation`; the first node is the seed) and the ZTP event file (`provisioning.simplified.evidence_path`/`ztp-events.jsonl`). A self-contained reader: no toolkit module and no YAML module. Missing or unknown keys are reported with their schema 5 path. The credential never comes from the file. `-ConfigPath` works as before.
* **config:** a node added to, or removed from, the infrastructure file is noticed within a minute and logged (`Restart Sonar to track the change`). The pollers are built at start, so Sonar does not change its nodes live.
* **config:** `-PollSeconds` overrides the poll interval for either way of configuring.
* **config:** commands that create and edit the config file: `New-AzlSonarConfig` (with `-Interactive` guided setup; pre-fills subscription and resource group from the Az context; never asks for a password), `Add-AzlSonarNode`, `Remove-AzlSonarNode`, `Get-AzlSonarConfig`, `Test-AzlSonarConfig -Path` and `ConvertTo-AzlSonarConfig -InfrastructureFile -OutFile`.
* **config:** `Start-AzlSonar.ps1` with no arguments uses `./sonar.config.json` or `./config/sonar.config.json` when present; otherwise it prints the three ways to configure Sonar with the exact commands and offers the guided setup.
* **docs:** `examples/sonar.config.commented.jsonc` (every key explained), and the pages Start here, Running Sonar by purpose and Configuration.
* **provisioning:** azurelocal-ztp's per-machine stages are steps of each machine. **Management address (maintenance environment)** (stage Device, before the claim) comes first and shows before the edge machine exists. **Management address on the management NIC** (Network, after the OS install) and **BIOS restored** (Restore: the final BIOS values after temporary install values) come last. Only a failed state is an error, so a Network job queued behind other jobs shows as running.
* **provisioning:** with the ZTP event file, a machine is done when Azure reports it Provisioned, its Network step succeeded, and its Restore step succeeded or is not applicable. Restore is not applicable when the stage ends (its `StageCompleted`, or Handoff) with no events for the machine. Until then the machine stays running at 95%.
* **provisioning:** `provisioning.ztpComplete` (all machines done) and `provisioning.nextStep` (`OS configuration` and its guide, https://azurelocal.cloud). Each machine has a `ztp` entry with its Device, Network and Restore step status.
* **web:** when ZTP is complete, the phase chip reads **ZTP complete**, the status reads "ZTP complete: N of N machines provisioned. OS configuration next", and a note under the header links the OS configuration guide.
* **web:** the page is rebuilt (see [Tour of the page](docs/tour.md)). The top bar has the cluster name, **ⓘ Details**, the run status with elapsed time and "updated N s ago", **Log access** (with a dot: live, Azure only, none), Export, a **?** button (version, documentation links, license) and the theme toggle. One tile per mode (Provisioning (ZTP) or (OS image), Validate, Deployment, Update, Health) selects what the summary box and the Steps box show. A summary box with a card per machine (full name, plain-word state, Arc connection, what it waits on, progress; a click filters the steps and the logs to that machine). Steps carry a description and an **Azure** badge. The Steps box and the Live logs box fill the window height and scroll inside; on a narrow screen they stack.
* **web:** **Details** shows what Sonar collected and is using (target, mode, nodes, sources, config), each value with where it came from and how old it is; secrets are never shown and the subscription only as its first 8 characters.
* **web:** Log access is a window opened from the top bar (a tab per phase), no longer a panel on the page.
* **api:** read-only `GET /api/about` (Sonar version from the module manifest and the documentation links) and `GET /api/details` (what Sonar collected and is using).
* **config:** optional `location` (infrastructure file: `azure.location`), shown in Details.
* **demo:** `?demo=1&route=simplified` is a ZTP run of three machines (two done, one installing the OS), with ZTP events in the logs.
* **update:** `state.update` gains `level`, `label`, `ran`, `nextAction`, `updates[]` (what Azure offers), `runs[]` (history), `summary.checkCounts` and `phase: waiting`; the Update view has panels for the offered updates, the readiness checks and the history. `?demo=1&route=update` shows the standalone Update monitor. See [the update object](docs/api.md#the-update-object).

### Security

* **web:** every request is checked before routing. The `Host` header must be `localhost`, `127.0.0.1` or `[::1]` with Sonar's port (400 otherwise; defeats DNS rebinding) and an `Origin` header must be Sonar's own (403). Sonar listens on `localhost` and `127.0.0.1`.
* **web:** a per-start **access token**, on by default. The URL Sonar prints and opens carries `?t=<token>`; Sonar sets a `HttpOnly`, `SameSite=Strict` cookie and redirects to the URL without it. Every other request needs the cookie (401 without). The token is masked like a password and is in no recording, export, `/api/details` or message. `-NoAccessToken` (or `accessToken: false`) turns it off, for a single-user machine only. **How you open Sonar changes:** use the printed URL with `?t=`.
* **web:** security headers on every response (`Cache-Control: no-store`, `X-Content-Type-Options`, `Referrer-Policy`, `X-Frame-Options: DENY`, a `Content-Security-Policy` with no `unsafe-inline`); JSON bodies escape `<`, `>` and `&`. The page no longer sets inline styles.
* **web:** only the page's own five files are served, from a fixed table. Help and Log access links are followed only when `https` on `azurelocal.cloud`, `learn.microsoft.com` or `github.com`; otherwise they are text.
* **api:** at most 4 live streams (`maxEventStreams`), 429 beyond; `/api/logs` answers are capped (2000 lines, about 2 MB, `truncated`) and `since` is parsed strictly. `/api/details` cuts local paths out of free text.

### Fixed

* **update:** the Update tab was green on a cluster that had never run an update. Azure's update summary says `AppliedSuccessfully` before any update ran, and Sonar rolled that up to success. Now the tab is neutral (*No update has run*) until an update run finished `Succeeded` (or `lastUpdated` is set with an installed update) and the summary is back to `AppliedSuccessfully`; an update that waits for content (`AdditionalContentRequired`, the SBE side-load) is amber with its name, version, package type, description and a link to the Learn page; unknown update states show Azure's word and are never green.
* **update:** the pre-update readiness checks are counted and coloured by severity: Critical and Error turn the tab red, Warning amber, Informational are listed with their remediation link and do not colour it. A check that passed is no longer listed as failed because its severity is Critical.
* **update:** `-Monitor Update` (standalone, weeks after a deployment) reads only the cluster, the Arc machines, the update resources and the seed node log: no deployment settings, edge machines, ARM deployments or event files, and no stale deployment tree. Auto lands on the Update view when an update starts, and also when a deployment that finished more than 24 hours ago has an update waiting for content or ready.
* **update:** while an update runs, a seed node that does not answer is rebooting: the log tile reads *Reconnecting to node logs*, not an error.
* **web:** clicking a provisioning step such as *Register machine* or *Install OS* left the live logs empty ("No lines match the current filters"). Cause: every step offered a time-window log filter, but a step that runs in Azure writes nothing to a node log, so its window held no line. Azure steps now show their details under the step and never filter the logs; node steps filter by machine and time window (or, for a ZTP stage, by the ZTP event lines of that stage); and an empty result says why and offers **Show all lines for this node** and **Clear filter**.

### Changed

* **provisioning:** the simplified route no longer says **Ready for Validate**. After ZTP comes OS configuration (OEM drivers, `C:\SBE`, DHCP off, DNS and time, the deployment admin; azurelocal-toolkit Phase 03), then Validate. `provisioning.readyForValidate` stays in the state; it is always false on the simplified route. The OEM image route is unchanged.
* **config:** the built-in YAML reader for `infrastructure.yml` is stricter and more exact: a key such as `712:` keeps its inline value, unquoted keys are trimmed, `''` inside a single-quoted value no longer ends the comment scan, `|` and `>` block scalars keep blank lines, indentation and `#` lines, duplicate keys are refused, and every error names its line without printing it. Multi-line quoted values and flow collections, `- - a`, text after a closing quote, content after `...`, input over 2 MB and nesting over 40 levels are refused with a clear message. See "What the YAML reader supports and refuses" in the configuration page.
* **provisioning:** the **Prepare for Validate** step and the per-machine `prepare` field are removed: azurelocal-ztp no longer has a Prepare stage. Prepare events in older event files still show in the log pane.

## [0.5.1](https://github.com/AzureLocal/azurelocal-sonar/compare/v0.5.0...v0.5.1) (2026-11-12)


### Bug Fixes

* **docs:** put the version placeholder in code so the VitePress build passes AB[#0](https://github.com/AzureLocal/azurelocal-sonar/issues/0) ([f507453](https://github.com/AzureLocal/azurelocal-sonar/commit/f50745354d63ad14f5ddb6d74ce949517dce5588))
* **docs:** use relative links on the docs home page so lychee can resolve them AB[#0](https://github.com/AzureLocal/azurelocal-sonar/issues/0) ([722da33](https://github.com/AzureLocal/azurelocal-sonar/commit/722da33d8fde15f92a383ed6045a92a2442febc0))
* **tests:** keep the NUL path case out of the Pester test name AB[#0](https://github.com/AzureLocal/azurelocal-sonar/issues/0) ([338e0b4](https://github.com/AzureLocal/azurelocal-sonar/commit/338e0b44905d2ca69a656a28e716e300186e37c1))
* **tests:** suppress the fake-credential analyzer rule in NodeUpdate tests AB[#0](https://github.com/AzureLocal/azurelocal-sonar/issues/0) ([a5f388f](https://github.com/AzureLocal/azurelocal-sonar/commit/a5f388fa3581796be8135bcf9e9006d87c6c28fd))

## [0.5.0](https://github.com/AzureLocal/azurelocal-sonar/compare/v0.4.0...v0.5.0) (2026-11-09)


### Features

* **api:** Invoke-AzlSonarApi, the supported helper for the read-only API AB[#0](https://github.com/AzureLocal/azurelocal-sonar/issues/0) ([2c4395c](https://github.com/AzureLocal/azurelocal-sonar/commit/2c4395c290b9d777608661e503515ea6a0ddc57b))
* **api:** Start-AzlSonar.ps1 -TokenFile and the tokenFile config key write the access token to a user-only file AB[#0](https://github.com/AzureLocal/azurelocal-sonar/issues/0) ([0046aaf](https://github.com/AzureLocal/azurelocal-sonar/commit/0046aaf20688e2ed1ef3ed7c1bf479944d946b96))
* **arm:** read the ARM Validate and Deploy event feed, build the arm state, follow armEventsPath AB[#0](https://github.com/AzureLocal/azurelocal-sonar/issues/0) ([dc4b5f0](https://github.com/AzureLocal/azurelocal-sonar/commit/dc4b5f006df7be1e714d654d864e6e526ad95180))
* **config:** build Sonar's config from the master infrastructure.yml, config commands, guided setup, docs ([08ea801](https://github.com/AzureLocal/azurelocal-sonar/commit/08ea801554c4c3e54748c08f5fd1f2f99d2c8f35))
* **config:** Set-AzlSonarConfig changes one key, checked before writing; document every key ([917c922](https://github.com/AzureLocal/azurelocal-sonar/commit/917c92297214c9d51f4644fe7beaf8ea377740cd))
* **discovery:** Discovery stage reader, manual install flag, -Monitor, no Health AB[#0](https://github.com/AzureLocal/azurelocal-sonar/issues/0) ([d1299e5](https://github.com/AzureLocal/azurelocal-sonar/commit/d1299e5d0dfb31e5e9d8e6ec20641733f9aec8e8))
* **osconfig:** read the hardened event feed: runId, seq, every state, address source, guarded panel data AB[#0](https://github.com/AzureLocal/azurelocal-sonar/issues/0) ([ddac6a9](https://github.com/AzureLocal/azurelocal-sonar/commit/ddac6a9f739c1e05d723f887d19d1056fad4709f))
* **osconfig:** read the OS configuration event feed, build osConfiguration, pick the log account per node ([432318f](https://github.com/AzureLocal/azurelocal-sonar/commit/432318f88aac105d38ca69d3cf10c5127fd4d04b))
* **provisioning:** ZTP Device, Network and Restore steps; ZTP complete hands over to OS configuration ([f776a23](https://github.com/AzureLocal/azurelocal-sonar/commit/f776a2362a8e63b35fb974e88d8143e7f2310ba5))
* **security:** access token, Host and Origin checks, security headers, fixed static files, limits ([66d1e35](https://github.com/AzureLocal/azurelocal-sonar/commit/66d1e35229b6167e8c423e7b8366084ec4338480))
* **sonar:** show the domain account's breaker in Details, drop the LCM wording from the page ([7ff3e30](https://github.com/AzureLocal/azurelocal-sonar/commit/7ff3e307d8a6ffec376ca39981c75d1c5bd82d37))
* **update:** read the cluster's own update service and merge it with Azure's verdict AB[#0](https://github.com/AzureLocal/azurelocal-sonar/issues/0) ([a368df8](https://github.com/AzureLocal/azurelocal-sonar/commit/a368df8a8e6f8b9088ba52d1c867f9cc6370f7b5))
* **verification:** Sonar monitors the pre-cluster verification gate AB[#0](https://github.com/AzureLocal/azurelocal-sonar/issues/0) ([d0dcbab](https://github.com/AzureLocal/azurelocal-sonar/commit/d0dcbab5a00127edeefde4de7fee32f175f60ef9))
* **web:** ARM checks, validation results and deployment progress inside the Validate and Deployment modes AB[#0](https://github.com/AzureLocal/azurelocal-sonar/issues/0) ([9601e1c](https://github.com/AzureLocal/azurelocal-sonar/commit/9601e1c99ea0223a72472ea4ff605cf19cddf465))
* **web:** cluster card for Validate, Deployment, Update, Add node and Repair AB[#0](https://github.com/AzureLocal/azurelocal-sonar/issues/0) ([651d96e](https://github.com/AzureLocal/azurelocal-sonar/commit/651d96e24e8ffb966f2a4f2bdeb87bc543d1c5bd))
* **web:** Discovery tile first, Provisioning not used for a manual install, standalone monitors, guarded panel and address source AB[#0](https://github.com/AzureLocal/azurelocal-sonar/issues/0) ([1cd8757](https://github.com/AzureLocal/azurelocal-sonar/commit/1cd8757b78278abdfab3ff0e4eab25f99afe60ad))
* **web:** fill-the-window layout, fix for empty log filters, docs and tour with screenshots ([67f90c4](https://github.com/AzureLocal/azurelocal-sonar/commit/67f90c49b3154e2f4dd4864cbaf8322811a4ca8b))
* **web:** five-tile mode bar, steps per mode, Log access window ([eb37f31](https://github.com/AzureLocal/azurelocal-sonar/commit/eb37f31d877fd7654a0db58023e1ed46ffce2ff1))
* **web:** new top bar, Details pop-down, Help box and summary box with machine cards ([9b14f43](https://github.com/AzureLocal/azurelocal-sonar/commit/9b14f43e99231492b535002f6659f239bc85c43b))
* **web:** OS configuration mode between Provisioning and Validate ([299a746](https://github.com/AzureLocal/azurelocal-sonar/commit/299a746a9a7b6f202d1983aacc8a63957616d21e))


### Bug Fixes

* **arm:** empty lists stay arrays under strict mode, one analyzer-clean naming, quicker step-limit test AB[#0](https://github.com/AzureLocal/azurelocal-sonar/issues/0) ([73ea1f2](https://github.com/AzureLocal/azurelocal-sonar/commit/73ea1f20dd5fd8b17f89bf0628f9de6a9242fbb6))
* **config:** harden the built-in YAML reader for infrastructure.yml ([bcb5858](https://github.com/AzureLocal/azurelocal-sonar/commit/bcb58588105344407489c8074e628e4043215f21))
* **dashboard:** use the Azure Local family icon for the favicon and page logo ([d7dfef5](https://github.com/AzureLocal/azurelocal-sonar/commit/d7dfef5086ed366ce1b7d44b6b95bc4b0e2bec09))
* **dashboard:** use the Azure Local family icon for the favicon and page logo ([aac5d52](https://github.com/AzureLocal/azurelocal-sonar/commit/aac5d52c02ce0680d804de215bd73b6a4bde7149))
* **provisioning:** a Network step that ZTP deferred to OS configuration counts as done ([c95c990](https://github.com/AzureLocal/azurelocal-sonar/commit/c95c990407ae85c6e95b204cc1098f550ba7f09e))
* **sonar:** classify each transport leg, never reuse the domain password on a second transport (F2) ([fd4bfec](https://github.com/AzureLocal/azurelocal-sonar/commit/fd4bfeca3e8ddd2db51f382c461ac02bc82fbffe))
* **sonar:** classify the legs' exceptions, not only the text; count only real attempts (N1, N3) ([5dc7f34](https://github.com/AzureLocal/azurelocal-sonar/commit/5dc7f34b9f7ca9287a755b41761fad11f331866e))
* **sonar:** inconclusive-result backoff, attempt cap, version recheck, SSPI codes, unusable accounts (N2 to N5) ([ea9844d](https://github.com/AzureLocal/azurelocal-sonar/commit/ea9844ddc54de8f4d016abeab6e8fa8d66072570))
* **sonar:** keep a working local session when the attempt cap is full (D2) ([62617d0](https://github.com/AzureLocal/azurelocal-sonar/commit/62617d0211052352a753ec6909d929badd07c893))
* **sonar:** mask secrets by salted fingerprint, never keep the password as text in Shared ([e80518f](https://github.com/AzureLocal/azurelocal-sonar/commit/e80518fbca2c79f5625e9d4e7ddf54dda39c3d8b))
* **sonar:** one lock, immutable records and an account-wide lockout breaker for the domain account ([4ca17e6](https://github.com/AzureLocal/azurelocal-sonar/commit/4ca17e6c1129d2c7584f2444d48d3e95081ba4d9))
* **sonar:** probe-gated, ticketed domain account breaker; classify by code and stage (F1, F3, F5-F11) ([cd79ddf](https://github.com/AzureLocal/azurelocal-sonar/commit/cd79ddfed53cd6cd168cfee059d526e765615519))
* **sonar:** the recorder masks a password registered after the recording started (F4) ([a4a30a5](https://github.com/AzureLocal/azurelocal-sonar/commit/a4a30a580c3ec8fd9c7de6d77f57c11fb4112fa4))
* **sonar:** unclassified results no longer latch a healthy account for every node (D1, D3) ([9a99f57](https://github.com/AzureLocal/azurelocal-sonar/commit/9a99f5780bd742fa88913aa0aab07258390c7048))
* **sonar:** use only the operator-supplied domain account, validate its Key Vault reference at load ([9d592cc](https://github.com/AzureLocal/azurelocal-sonar/commit/9d592cc177260028dc83eb9c7b334c6969498648))
* **test:** replay seek compares UTC; no prompt in a -NonInteractive session ([e6e2299](https://github.com/AzureLocal/azurelocal-sonar/commit/e6e22999d9bbaf907e17c7c2c9d53575936642a9))
* **ui:** always show the five mode tiles, grey Provisioning with a reason when there is no machine data ([ff73a14](https://github.com/AzureLocal/azurelocal-sonar/commit/ff73a14c889c5b670a5208f7d0dbe25bfa293a7c))
* **update:** AppliedSuccessfully is not an update that ran; verdict, offers, history and standalone Update monitor AB[#0](https://github.com/AzureLocal/azurelocal-sonar/issues/0) ([a7fd91c](https://github.com/AzureLocal/azurelocal-sonar/commit/a7fd91cd29d62fcc24fce79581940f3678403c31))
* **update:** orphaned runs and unreadable run status do not decide the verdict; no URL in app.js demo; fix anchor AB[#0](https://github.com/AzureLocal/azurelocal-sonar/issues/0) ([c6d29b4](https://github.com/AzureLocal/azurelocal-sonar/commit/c6d29b401b62a83bd6be45c2c8f2841092a36665))
* **update:** the Update tab follows the verdict, lists offers and checks, and reconnects to node logs AB[#0](https://github.com/AzureLocal/azurelocal-sonar/issues/0) ([7ace56e](https://github.com/AzureLocal/azurelocal-sonar/commit/7ace56e2176b415b40c536cc0eb7ca220d0afdb2))
* **web:** analyzer-clean name for the cluster object builder AB[#0](https://github.com/AzureLocal/azurelocal-sonar/issues/0) ([b9a7cd8](https://github.com/AzureLocal/azurelocal-sonar/commit/b9a7cd873062636fb75537f71ec46fa33bae856d))
* **web:** level filter helpers no longer depend on a var set after the test export; exhaustive level-filter tests AB[#0](https://github.com/AzureLocal/azurelocal-sonar/issues/0) ([afdde6a](https://github.com/AzureLocal/azurelocal-sonar/commit/afdde6afa871951bbcdf8077bfe36d09bcd700d8))
* **web:** no URL in the demo state, repair the config page link anchor AB[#0](https://github.com/AzureLocal/azurelocal-sonar/issues/0) ([7c242c5](https://github.com/AzureLocal/azurelocal-sonar/commit/7c242c52fcea7f2cc5a50a62d1ff15c2dbcc0f47))
* **ztp:** a later run no longer erases the finished stages of machines it does not cover ([09af13a](https://github.com/AzureLocal/azurelocal-sonar/commit/09af13accf1690c3d1e8e74e4cd6530ae4023c0e))

## [0.4.0](https://github.com/AzureLocal/azurelocal-sonar/compare/v0.3.0...v0.4.0) (2026-11-06)


### Features

* **provisioning:** show azurelocal-ztp's Prepare stage after the OS is provisioned ([4601f85](https://github.com/AzureLocal/azurelocal-sonar/commit/4601f85a82a956236fdd26df86ce2adb01d82690))
* **provisioning:** show azurelocal-ztp's Prepare stage after the OS is provisioned ([15b5056](https://github.com/AzureLocal/azurelocal-sonar/commit/15b5056f3e1878a8588c68705583b822bfd20d1c))


### Bug Fixes

* **provisioning:** don't report an earlier attempt's ProvisionOs error as a failure ([b3f0cbf](https://github.com/AzureLocal/azurelocal-sonar/commit/b3f0cbf998f8a076a99e3e3a6645a27570491369))
* **provisioning:** don't report an earlier attempt's ProvisionOs error as a failure ([f2bfbfb](https://github.com/AzureLocal/azurelocal-sonar/commit/f2bfbfb7793ad605b4844eeb07545e5eca4af296))
* **web:** an open page reloads itself when Sonar comes back with new page code ([f61d062](https://github.com/AzureLocal/azurelocal-sonar/commit/f61d062102f8933832bb1e6dc4a6a5778627d086))
* **web:** an open page reloads itself when Sonar comes back with new page code ([21ad818](https://github.com/AzureLocal/azurelocal-sonar/commit/21ad8180b70bf984a231423f8e70847efcbd7ba5))
* **web:** header says Ready for Validate when every machine is done ([f9b7dab](https://github.com/AzureLocal/azurelocal-sonar/commit/f9b7dabb48ec59dc86752922bc40cc11adc2ed5c))
* **web:** header says Ready for Validate when every machine is done ([b9baad1](https://github.com/AzureLocal/azurelocal-sonar/commit/b9baad161e63afe811688db32a452bf26106a818))

## [0.3.0](https://github.com/AzureLocal/azurelocal-sonar/compare/v0.2.0...v0.3.0) (2026-10-16)


### Features

* GA api-versions and 12.2609 guidance, Azure lag and Environment Checker stage, update track, deployment shape, collapsed log access ([223bf68](https://github.com/AzureLocal/azurelocal-sonar/commit/223bf6845683b2ecbc7e2b8549787c0f85cb14e6))
* OEM-route Arc registration phase shows what registration does - OS image update (Get-ArcZeroDaySolutionUpdateStatus: Scan, Download, Install), bootstrap steps (Get-ArcBootstrapStatus incl. ArcConfiguration &gt; ArcRegistration), Arc machine registered and Connected; extensions move to Validate; read-only node probe over WinRM/SSH ([74871d4](https://github.com/AzureLocal/azurelocal-sonar/commit/74871d4e5434d46bad51baff8157475651692153))
* provisioning route setting and provisioning / Arc registration phases for both routes (simplified and OEM image) - work in progress, committed on owner order ([00c8f78](https://github.com/AzureLocal/azurelocal-sonar/commit/00c8f7801f77f0b28183c236930a768b7a5c4fd7))
* **recording:** publishable recordings (identifier pseudonyms, verified) and the export bundle ([948991d](https://github.com/AzureLocal/azurelocal-sonar/commit/948991d4df7b6bcf5c2a4e1e680e9e640c29f47d))
* Sonar back end - ARM poller, seed-node log tailer, HttpListener/SSE server, Start-AzlSonar.ps1, example config (S-5) ([e88fea9](https://github.com/AzureLocal/azurelocal-sonar/commit/e88fea95f41f9df57c89978fa6d61d5f8fc16e80))
* **web:** clearer confidence badge on the log-access card - 'Confirmed on Azure Local 2609 (Local Identity)' vs 'From Microsoft docs - not yet confirmed', with what was observed and what to do if it differs; README explains it ([f217022](https://github.com/AzureLocal/azurelocal-sonar/commit/f2170225d8f5fb4788ebe0748512257cf1912596))
* **web:** Sonar page - live step tree, log stream, guidance card, export, demo mode (S-5) ([c6772a8](https://github.com/AzureLocal/azurelocal-sonar/commit/c6772a8c0d6359d34f321aedc2efed8f69b2d908))
* **ztp:** follow the azurelocal-ztp provisioning event file (ztpEvents.path) in the log pane ([f15754b](https://github.com/AzureLocal/azurelocal-sonar/commit/f15754b608e728b5da2db7461dca575026fc13cc))


### Bug Fixes

* GPT review should-fixes - log event times with node UTC offset, page log sequencing and restart detection, SSE flow control and client cap, bounded discovery and state, file filter rebuild, step window re-render, zero-count summaries, rename rotation; docs: README, getting started, how it works ([930433f](https://github.com/AzureLocal/azurelocal-sonar/commit/930433f132c2555182e377485192909f7f22d3d0))
* loopback-only requests and secret redaction (GPT review blockers); SSH log transport fallback via Posh-SSH stdin; deployment log paths verified live ([d1b889f](https://github.com/AzureLocal/azurelocal-sonar/commit/d1b889f8e3b7514b23090e1aee648b985aa8e027))

## [Unreleased]

### Fixed

- Resolve the web-logic runner's app path from the working directory so the relative path used by Linux CI loads the same module as Pester's absolute path.

## [0.2.0] - 2026-10-15

Hardening release (owner order of 15 Oct 2026: the tools 100% built out). Everything below that reads Azure or the node is
covered by Pester with mocked answers; what could not be run live is marked "unverified against a live run" in the page and
the docs.

### Added

- **Publishable recordings.** `-Record -Publishable`, `Export-AzlSonarPublishableRecording`, `Test-AzlSonarPublishableRecording` and
  `scripts/Protect-Recording.ps1` replace GUIDs, IPv4, IPv6 and MAC addresses, SIDs, host and domain names, UPNs, subscription,
  resource group, cluster, node and user names with stable pseudonyms (`00000000-0000-0000-0000-000000000001`, `192.0.2.x`,
  `node-01`, `host-01.dom-01.example.test` ...), keep structure, timestamps, step names and durations, and refuse to write when a
  verification pass still finds an original (a live `-Publishable` recording is renamed `.NOT-PUBLISHABLE`). Options:
  `-ExtraTerm`, `-MaxLogTextLength`, `-MaxInfoLinesPerEvent`, `-MaxIdleSeconds`, `-MaxBytes`, `-VerifyOnly`. The detectors are
  compiled C# (a 137 MB recording in about five minutes). See `docs/reference/publishable-recordings.md`.
- **Update track** (unverified against a live run): `updateSummaries`, `updates` and `updateRuns` read into a step tree, with the
  update as the phase, a replay marker and a guidance card; `track` and `updateTrack` in the config; add node and repair as guidance
  cards and a config `track`.
- **Azure lag and Environment Checker stage:** the state carries `lag` (Azure behind the node log, or a newer running ARM deployment)
  and `environmentChecker` (limited, full, cloud deployment); the node-log role and interface is shown as the current step marked
  *from node log*; the page shows notes under the header.
- **Export bundle:** `Export-AzlSonarBundle` and `scripts/Export-SonarBundle.ps1` write a timeline JSON and a self-contained HTML
  report from any recording.
- **Log access panel** collapsed by default to one status line with an expander (S-12).
- **Event feed contract:** `docs/reference/events.schema.json` and `docs/reference/events.md` (what other tools can emit and Sonar
  replays; how a deployment pipeline runs Sonar with `-Record`).
- **Deployment shape in the config:** `clusterPattern` (Standard or RackAware), `architecture` (hyperconverged or disaggregated) and
  `internalDns`, with Learn's notes on the guidance card and a warning for the rack aware and Local Identity combination (Learn
  contradicts itself there).
- CI (`.github/workflows/ci.yml`: Pester per test file, the page logic under Node, PSScriptAnalyzer, relative links, the docs build),
  release-please, `PSScriptAnalyzerSettings.psd1`, `AGENTS.md`, `CLAUDE.md`, `CONTRIBUTING.md`, a pull request template and this file.
- `examples/recording.publishable.example.jsonl`: a small recording made with `-Publishable`.

### Changed

- Default api-versions are the GA versions on Microsoft Learn: deploymentSettings and the update resources `2026-10-01`, edge machines
  `2026-10-01`, Arc machines `2026-07-15`; the preview versions stay configurable and `apiVersionFallback` (default `2025-10-01`) is
  tried once when the configured version is not accepted.
- Guidance for release 12.2609 (latest): Validate about 10 minutes; Deploy 2.5 to 3 hours with a limited then a full Environment
  Checker run, Begin cloud deployment 45-60 minutes, Deploy Moc and ARB Stack 40-45 minutes (a new "How long" row).
- Reading a recording keeps no parsed JSON for log and tailer events (memory).
- `Protect-AzlSonarText` compiles its patterns once.
- The docs build checks dead links (`ignoreDeadLinks` is off); the module version is 0.2.0.
- README and docs say that recordings keep identifiers unless made with `-Publishable`; names of test environments and events are removed from the public docs.

### Fixed

- A `<time>` placeholder outside a code span broke the VitePress build of `docs/design.md`.

## [0.1.0] - 2026-10-11

First version: live step tree from Azure, live log tailing from the seed node, phase guidance, provisioning and Arc registration
views for both routes, record and replay, export, and a local web page.
