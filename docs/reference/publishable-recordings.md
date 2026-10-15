# Publishable recordings

A recording made with `-Record` masks **secrets** (passwords, tokens, keys, the log credential, Key Vault secret names). It
still holds **identifiers**: subscription, tenant and principal GUIDs, private IP and MAC addresses, the resource group,
the cluster and node names, host and domain names, user names. That is what makes a recording useful on your own machine,
and what makes it unsafe to share.

A **publishable** recording replaces every identifier with a stable pseudonym and checks the result before it keeps the file.

```powershell
# While recording (needs a new file):
./Start-AzlSonar.ps1 -ConfigPath ./config/clus01.json -Record ./recordings/clus01.shareable.jsonl -Publishable

# Or rewrite a recording you already have (the source is never changed):
./scripts/Protect-Recording.ps1 -Path ./recordings/clus01.jsonl -Destination ./recordings/clus01.publishable.jsonl.gz `
    -ExtraTerm 'Infinite Improbability Corp' -MaxBytes 15MB

# Scan any recording with the detectors and print counts per category (never the values):
./scripts/Protect-Recording.ps1 -Path ./recordings/clus01.publishable.jsonl.gz -VerifyOnly
```

The same functions are in the module: `Export-AzlSonarPublishableRecording` and `Test-AzlSonarPublishableRecording`.

## What stays and what changes

| Stays as it was | Replaced |
|---|---|
| Event kinds and order, every `t` timestamp, step names, statuses and durations, error text (scrubbed), file names, log levels | Every identifier, in every string value and every object key |

A replay of the publishable file behaves like the original: the same phases, the same step tree, the same log lines, the
same timing.

## Token formats

The same original value gets the same token everywhere inside one recording (case-insensitive). Tokens are not
reversible; the mapping is not stored anywhere.

| Identifier | Token |
|---|---|
| GUID (subscription, tenant, principal, resource ids) | `00000000-0000-0000-0000-000000000001`, `...0002` ... |
| 32-hex id (a GUID without dashes, a server id) | 32 digits: 31 zeros and a counter |
| 40-hex id (certificate thumbprint) | 40 digits: zeros and a counter |
| 16-hex id (WWN, device id, with letters and digits) | 16 digits: zeros and a counter |
| IPv4 | `192.0.2.1`..`.254`, then `198.51.100.x`, then `203.0.113.x`, then `198.18.x.x` (documentation ranges) |
| IPv6 | `2001:db8::1`, `2001:db8::2` ... |
| MAC address | `00-00-5e-00-53-00` ... (RFC 7042 documentation range; separator and letter case are kept) |
| Subscription name | `sub-0001` (a subscription id is a GUID) |
| Resource group | `rg-01` |
| Cluster | `cluster-01` |
| Node | `node-01`, `node-02` ... |
| Arc machine | `arc-01` ... |
| Other host | `host-01` ... |
| DNS name | `<host token>.dom-01.example.test` (a name under `blob.core.windows.net`, `vault.azure.net` and similar keeps its service suffix: `res-01.blob.core.windows.net`) |
| User, UPN, account | `user-01`, `user-01@dom-01.example.test`, `DOM01\user-01` |
| Windows SID | `S-1-5-21-1000000001-2000000001-3000000001-<RID kept>` |
| Other named resource (storage account, vault) | `res-01` |

Kept on purpose: public Microsoft and Azure endpoints (`management.azure.com`, `login.microsoftonline.com` ...), version
numbers (`10.0.26100.1`, `4.0.0.0`), subnet masks, loopback and `0.0.0.0`, documentation values already in the file,
well-known account and folder names (`Administrator`, `Public`), `default` and public resource names (`extensions`,
`deploymentSettings`).

## How it finds identifiers

1. **Shape detectors** (every string): Azure resource ids (subscription, resource group, the name after each
   `/providers/<namespace>/<type>/`), email and UPN, SIDs, GUIDs, 32/40/16-hex ids, MACs (colon, dash, Cisco-dotted, and 12
   hex after a `MacAddress` key), IPv6 and IPv4, DNS names under common and private top-level domains, Windows
   profile folders, UNC hosts, URL hosts, AD distinguished names (`DC=`, `OU=`, `CN=`, `O=`, `L=`, `ST=`), `ComputerName=`,
   `HostName=`, `UserName=` style pairs, serial numbers and service tags, storage account and vault names after their label,
   `AzureAD\user` and `NETBIOS\user` (an all-capital domain), values in Windows event XML (`<Computer>`,
   `<Data Name='TargetUserName'>`), service principal names (`HOST/node`) and half-masked GUIDs
   (`d7f0cf39-xxxx-xxxx-xxxx-xxxxxxxxxxxx`: the hex groups that are left are zeroed). A PowerShell `-EncodedCommand` payload is
   removed (`[encoded command removed]`): base64 cannot be checked.
2. **Learned names**: the cluster, resource group, node names, Arc machine names, the log account and the domains found
   along the way are learned from the structured parts of the recording (config, state, tailer) and from earlier matches, and
   then replaced **everywhere** they appear, in any case, even where no pattern would find them. The export reads the file
   twice: once to learn, once to write, so a name learned late is also replaced where it first appeared.
3. **Escapes** that hide punctuation (XML entities such as `&#64;`, CLIXML `_x002E_`, a literal backslash-u escape, `%40`) are decoded first; the decoded text is kept.
4. **Extra terms** (`-ExtraTerm`): any strings you give (a company, a site, a tenant name) are replaced and checked.

Long log lines can be cut (`-MaxLogTextLength`, default 2000 in the script) at a word boundary **before** scrubbing, so a cut
never leaves half an identifier and the long tail is never stored. A marker says how many characters were left out.
`-MaxIdleSeconds` closes long gaps between events (the page replays faster; step times inside the state are untouched).

## The check

After writing, the whole output is read again with the same detector set plus every learned term and every `-ExtraTerm`.
One surviving original means **nothing is written**: the function throws with counts per category (never the values), and
a live `-Publishable` recording is renamed `.NOT-PUBLISHABLE`. `-MaxBytes` also refuses a result that is too large.

The check proves that nothing a detector knows is left. It cannot prove that nothing is left. What it cannot see:

- a bare short name that was never in a structured field and has no pattern around it (for example `HV1` in a free-text table);
- hardware serials and service tags without a label in front of them;
- company, site and person names in free text or certificate text: give them with `-ExtraTerm`;
- base64, compressed or encrypted blobs, and identifiers split across lines;
- what the structure and the timing reveal (a deployment of this length with these errors on this date);
- a recording thinned with `-MaxInfoLinesPerEvent` keeps every warning and error line but only an even sample of the info lines (the
  number left out is added to the event's `lost`): fine for a demo, not a complete log.

Other models were asked to attack the detector list (gpt-6-1-sol, grok-4-6) and to review it for bugs (gpt-6-sol). What they found that
is fixed is in the detectors; what is not fixed is the list above.

Before you publish, scan the file with `-VerifyOnly`, read a sample of it, and add every name you find with `-ExtraTerm`.

## Size and speed

A real 137 MB recording (five hours, 2,310 events, 203,000 log lines) is dominated by log lines, a few of them very long (one
file's lines were 43 KB each). Measured on a developer workstation under load:

| Recording | File | Read for replay | Replay document | Memory of the replay process |
| --- | --- | --- | --- | --- |
| Publishable, long lines cut (`-MaxLogTextLength 1500`) | 3.7 MB `.jsonl.gz` (68 MB of JSON) | about 14 s | 68 MB, 6 s to build | about 740 MB |
| Publishable, thinned (`-MaxLogTextLength 1500 -MaxInfoLinesPerEvent 25`) | 0.72 MB `.jsonl.gz` (13 MB of JSON) | about 5 s | 13 MB, 1.2 s to build | about 255 MB |

Making a publishable file takes three to five minutes (the detectors are compiled C#; the file is read twice and verified once).
Use `-MaxLogTextLength` (cuts at a word boundary, before scrubbing), `-MaxInfoLinesPerEvent` and `-MaxIdleSeconds`, and write `.gz`:
Sonar replays `.jsonl.gz` directly and keeps only the text of log lines in memory, not their parsed JSON. The page is sent the whole
recording as one document, so it needs memory in proportion to it; do not ask a browser tab to replay the unthinned 137 MB file.
