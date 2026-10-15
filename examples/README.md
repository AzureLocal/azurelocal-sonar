# Examples

| File | What it is |
| --- | --- |
| `sonar.config.example.json` | A config for one cluster (documentation values only). Copy it to `config/` (git-ignored) and fill it in. |
| `recording.publishable.example.jsonl` | A small recording made with `-Publishable` (the identifiers are pseudonyms: `cluster-01`, `node-01`, `rg-01`). Play it with `./Start-AzlSonar.ps1 -Replay ./examples/recording.publishable.example.jsonl -Speed 240 -Autoplay`. |

A real recording stays out of git (`recordings/` is ignored). To make one you can share, record with `-Publishable` or run
`scripts/Protect-Recording.ps1` on it; see [Publishable recordings](../docs/reference/publishable-recordings.md). A demo made this
way from a five-hour run (137 MB) is about 0.7 MB as `.jsonl.gz` (3.7 MB without `-MaxInfoLinesPerEvent`) and replays with `-Replay`; it is produced locally and is not committed here:

```powershell
./scripts/Protect-Recording.ps1 -Path ./recordings/clus01.jsonl -Destination ./recordings/demo-clus01.publishable.jsonl.gz `
    -MaxLogTextLength 1500 -MaxInfoLinesPerEvent 25 -MaxBytes 15MB -ExtraTerm 'Infinite Improbability Corp'
```
