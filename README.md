# LaunchDarkly Exporter

A bash script that uses the LaunchDarkly REST API to export all feature flags, evaluations, metrics, experiments, and context instances to local JSON files.

---

## Requirements

| Tool | Required | Notes |
|------|----------|-------|
| `bash` | ✅ | v4+ recommended |
| `curl` | ✅ | For all API calls |
| `jq` | Recommended | Enables per-item exports & pretty-printing. Install via `brew install jq` or `apt install jq` |

---

## Setup

**1. Get a LaunchDarkly API token**

Go to **Account Settings → Authorization → Access tokens** in LaunchDarkly and create a token with at least **Reader** role.

**2. Set your token as an environment variable**

```bash
export LD_API_TOKEN="api-tok-xxxxxxxxxxxx"
```

**3. Make the script executable**

```bash
chmod +x ld_download_flags.sh
```

---

## Usage

```bash
./ld_download_flags.sh
```

Output is saved to `./ld_export_<timestamp>/` by default.

---

## Configuration

All options are set via environment variables — no flags or config files needed.

| Variable | Default | Description |
|----------|---------|-------------|
| `LD_API_TOKEN` | *(required)* | Your LaunchDarkly API token |
| `LD_PROJECT_KEY` | `default` | Project key to export from |
| `LD_ENV_KEY` | `production` | Environment to target |
| `OUTPUT_DIR` | `./ld_export_<timestamp>` | Where to write output files |
| `CONTEXT_LIMIT` | `50` | Max context instances to fetch per kind |
| `CONTEXT_FILTER_DAYS` | `30` | Lookback window for context activity (days) |

**Example — exporting a staging environment with more contexts:**

```bash
export LD_API_TOKEN="api-tok-xxxxxxxxxxxx"
export LD_PROJECT_KEY="my-app"
export LD_ENV_KEY="staging"
export CONTEXT_LIMIT=500
export CONTEXT_FILTER_DAYS=90

./ld_download_flags.sh
```

---

## What Gets Exported

```
ld_export_<timestamp>/
├── manifest.txt                        # Summary of the run + all file paths
│
├── flags/
│   ├── all_flags.json                  # All flags with full config
│   ├── flag_statuses.json              # Evaluation status per flag/env
│   └── <flag-key>.json                 # Per-flag detail (requires jq)
│
├── metrics/
│   ├── all_metrics.json                # All metrics definitions
│   └── <metric-key>.json              # Per-metric detail (requires jq)
│
├── experiments/
│   ├── all_experiments.json            # All experiments (requires add-on)
│   └── <experiment-id>.json           # Per-experiment detail (requires jq)
│
└── contexts/
    ├── context_kinds.json              # All context kinds in the project
    ├── context_attributes.json         # Attribute schema across all contexts
    └── <kind>/
        ├── page_1.json                 # Paginated context instances
        └── page_2.json                 # (one file per page of 50)
```

> **Note:** Experiments require the LaunchDarkly Experimentation add-on. If unavailable, the script logs a warning and continues.

---

## Notes on Large Accounts

- Flags are fetched with `limit=200`. If you have more than 200 flags, the script currently fetches the first page only. You can increase this or add pagination as needed.
- Context instances are paginated at 50 per page and stop at `CONTEXT_LIMIT`. Increase `CONTEXT_LIMIT` for larger exports.
- The script uses `set -euo pipefail` — it will stop on unexpected errors unless the error is explicitly handled with `|| { ... }`.

---

## Troubleshooting

**`ERROR: LD_API_TOKEN is not set`**
Run `export LD_API_TOKEN="your-token"` before executing the script.

**`HTTP 401` errors**
Your token may be expired or lack the required permissions. Verify it in Account Settings → Authorization.

**`HTTP 403` on experiments**
The Experimentation endpoint requires the Experimentation add-on. The script will warn and skip this section automatically.

**Individual flag files not created**
Install `jq` — per-item breakdown requires it. The bulk `all_flags.json` is always saved regardless.

---

## License

MIT — use freely, modify as needed.
# ld-exporter
