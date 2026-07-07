#!/usr/bin/env bash
# =============================================================================
# LaunchDarkly Flag Evaluations, Metrics & Contexts Downloader
# =============================================================================
# Usage:
#   export LD_API_TOKEN="your-api-token"
#   chmod +x ld_download_flags.sh
#   ./ld_download_flags.sh
#
# Optional env overrides:
#   LD_PROJECT_KEY      — defaults to "default"
#   LD_ENV_KEY          — defaults to "production"
#   OUTPUT_DIR          — defaults to "./ld_export_<timestamp>"
#   CONTEXT_LIMIT       — max contexts per kind to fetch (default: 50)
#   CONTEXT_FILTER_DAYS — fetch contexts active in last N days (default: 30)
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
API_BASE="https://app.launchdarkly.com/api/v2"
PROJECT_KEY="${LD_PROJECT_KEY:-default}"
ENV_KEY="${LD_ENV_KEY:-production}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
OUTPUT_DIR="${OUTPUT_DIR:-./ld_export_${TIMESTAMP}}"
CONTEXT_LIMIT="${CONTEXT_LIMIT:-50}"
CONTEXT_FILTER_DAYS="${CONTEXT_FILTER_DAYS:-30}"

# ---------------------------------------------------------------------------
# Validate token
# ---------------------------------------------------------------------------
if [[ -z "${LD_API_TOKEN:-}" ]]; then
  echo "ERROR: LD_API_TOKEN is not set."
  echo "  export LD_API_TOKEN=\"your-api-token\" and re-run."
  exit 1
fi

AUTH_HEADER="Authorization: ${LD_API_TOKEN}"
CONTENT_HEADER="Content-Type: application/json"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log()  { echo "[$(date +%H:%M:%S)] $*"; }
fail() { echo "ERROR: $*" >&2; exit 1; }

# Wrapper: GET with auth, returns body; exits on HTTP error
ld_get() {
  local url="$1"
  local resp http_code body

  resp=$(curl -s -w "\n%{http_code}" \
    -H "$AUTH_HEADER" \
    -H "$CONTENT_HEADER" \
    "$url")

  http_code=$(echo "$resp" | tail -n1)
  body=$(echo "$resp" | head -n -1)

  if [[ "$http_code" -lt 200 || "$http_code" -ge 300 ]]; then
    echo "  HTTP $http_code for $url" >&2
    echo "  Response: $body" >&2
    return 1
  fi

  echo "$body"
}

# Wrapper: POST with auth + JSON body
ld_post() {
  local url="$1"
  local payload="$2"
  local resp http_code body

  resp=$(curl -s -w "\n%{http_code}" \
    -X POST \
    -H "$AUTH_HEADER" \
    -H "$CONTENT_HEADER" \
    -d "$payload" \
    "$url")

  http_code=$(echo "$resp" | tail -n1)
  body=$(echo "$resp" | head -n -1)

  if [[ "$http_code" -lt 200 || "$http_code" -ge 300 ]]; then
    echo "  HTTP $http_code for POST $url" >&2
    echo "  Response: $body" >&2
    return 1
  fi

  echo "$body"
}

# Pretty-print JSON if jq is available, otherwise raw
save_json() {
  local data="$1"
  local path="$2"
  if command -v jq &>/dev/null; then
    echo "$data" | jq '.' > "$path"
  else
    echo "$data" > "$path"
  fi
}

# ---------------------------------------------------------------------------
# Setup output directories
# ---------------------------------------------------------------------------
mkdir -p \
  "$OUTPUT_DIR/flags" \
  "$OUTPUT_DIR/metrics" \
  "$OUTPUT_DIR/experiments" \
  "$OUTPUT_DIR/contexts"

log "Output directory: $OUTPUT_DIR"
log "Project: $PROJECT_KEY  |  Environment: $ENV_KEY"
echo

# ---------------------------------------------------------------------------
# 1. List all feature flags
# ---------------------------------------------------------------------------
log "Fetching feature flags list..."
FLAGS_URL="${API_BASE}/flags/${PROJECT_KEY}?env=${ENV_KEY}&summary=false&limit=200"
FLAGS_DATA=$(ld_get "$FLAGS_URL") || fail "Could not fetch flags."
save_json "$FLAGS_DATA" "$OUTPUT_DIR/flags/all_flags.json"

if command -v jq &>/dev/null; then
  FLAG_KEYS=$(echo "$FLAGS_DATA" | jq -r '.items[].key')
  TOTAL=$(echo "$FLAGS_DATA" | jq '.totalCount // (.items | length)')
  log "Found $TOTAL flag(s)."
else
  log "jq not found — individual flag details will be skipped. Install jq for full output."
  FLAG_KEYS=""
fi
echo

# ---------------------------------------------------------------------------
# 2. Per-flag details + evaluation config
# ---------------------------------------------------------------------------
if [[ -n "${FLAG_KEYS:-}" ]]; then
  log "Downloading per-flag details..."
  COUNT=0
  while IFS= read -r key; do
    [[ -z "$key" ]] && continue
    log "  → $key"
    FLAG_URL="${API_BASE}/flags/${PROJECT_KEY}/${key}?env=${ENV_KEY}"
    FLAG_DATA=$(ld_get "$FLAG_URL") || { log "  WARN: skipping $key (fetch failed)"; continue; }
    save_json "$FLAG_DATA" "$OUTPUT_DIR/flags/${key}.json"
    COUNT=$((COUNT + 1))
  done <<< "$FLAG_KEYS"
  log "Saved $COUNT individual flag file(s) to $OUTPUT_DIR/flags/"
  echo
fi

# ---------------------------------------------------------------------------
# 3. Flag status (evaluation state per environment)
# ---------------------------------------------------------------------------
log "Fetching flag statuses..."
STATUS_URL="${API_BASE}/flag-statuses/${PROJECT_KEY}/${ENV_KEY}"
STATUS_DATA=$(ld_get "$STATUS_URL") || { log "WARN: Could not fetch flag statuses."; STATUS_DATA=""; }
if [[ -n "${STATUS_DATA:-}" ]]; then
  save_json "$STATUS_DATA" "$OUTPUT_DIR/flags/flag_statuses.json"
  log "Saved flag_statuses.json"
fi
echo

# ---------------------------------------------------------------------------
# 4. Metrics
# ---------------------------------------------------------------------------
log "Fetching metrics list..."
METRICS_URL="${API_BASE}/metrics/${PROJECT_KEY}?limit=200"
METRICS_DATA=$(ld_get "$METRICS_URL") || fail "Could not fetch metrics."
save_json "$METRICS_DATA" "$OUTPUT_DIR/metrics/all_metrics.json"

if command -v jq &>/dev/null; then
  METRIC_KEYS=$(echo "$METRICS_DATA" | jq -r '.items[].key')
  TOTAL_M=$(echo "$METRICS_DATA" | jq '.totalCount // (.items | length)')
  log "Found $TOTAL_M metric(s)."

  log "Downloading per-metric details..."
  while IFS= read -r mkey; do
    [[ -z "$mkey" ]] && continue
    log "  → $mkey"
    M_URL="${API_BASE}/metrics/${PROJECT_KEY}/${mkey}"
    M_DATA=$(ld_get "$M_URL") || { log "  WARN: skipping $mkey"; continue; }
    save_json "$M_DATA" "$OUTPUT_DIR/metrics/${mkey}.json"
  done <<< "$METRIC_KEYS"
fi
echo

# ---------------------------------------------------------------------------
# 5. Experiments (requires Experimentation add-on)
# ---------------------------------------------------------------------------
log "Fetching experiments..."
EXP_URL="${API_BASE}/projects/${PROJECT_KEY}/environments/${ENV_KEY}/experiments?limit=50"
EXP_DATA=$(ld_get "$EXP_URL") || { log "WARN: Experiments endpoint unavailable (may require experimentation add-on)."; EXP_DATA=""; }
if [[ -n "${EXP_DATA:-}" ]]; then
  save_json "$EXP_DATA" "$OUTPUT_DIR/experiments/all_experiments.json"
  log "Saved all_experiments.json"

  if command -v jq &>/dev/null; then
    EXP_IDS=$(echo "$EXP_DATA" | jq -r '.items[].key // .items[].id // empty')
    while IFS= read -r eid; do
      [[ -z "$eid" ]] && continue
      log "  → experiment $eid"
      EID_URL="${API_BASE}/projects/${PROJECT_KEY}/environments/${ENV_KEY}/experiments/${eid}"
      EID_DATA=$(ld_get "$EID_URL") || { log "  WARN: skipping $eid"; continue; }
      save_json "$EID_DATA" "$OUTPUT_DIR/experiments/${eid}.json"
    done <<< "$EXP_IDS"
  fi
fi
echo

# ---------------------------------------------------------------------------
# 6. Contexts
# ---------------------------------------------------------------------------

# 6a. Context kinds
log "Fetching context kinds..."
KINDS_URL="${API_BASE}/projects/${PROJECT_KEY}/context-kinds"
KINDS_DATA=$(ld_get "$KINDS_URL") || { log "WARN: Could not fetch context kinds."; KINDS_DATA=""; }

KIND_KEYS=""
if [[ -n "${KINDS_DATA:-}" ]]; then
  save_json "$KINDS_DATA" "$OUTPUT_DIR/contexts/context_kinds.json"
  log "Saved context_kinds.json"

  if command -v jq &>/dev/null; then
    KIND_KEYS=$(echo "$KINDS_DATA" | jq -r '.items[].key // empty')
    TOTAL_K=$(echo "$KINDS_DATA" | jq '.items | length')
    log "Found $TOTAL_K context kind(s): $(echo "$KIND_KEYS" | tr '\n' ' ')"
  fi
fi
echo

# 6b. Context attribute names (schema discovery)
log "Fetching context attribute names..."
ATTR_URL="${API_BASE}/projects/${PROJECT_KEY}/environments/${ENV_KEY}/context-attributes"
ATTR_DATA=$(ld_get "$ATTR_URL") || { log "WARN: Could not fetch context attributes."; ATTR_DATA=""; }
if [[ -n "${ATTR_DATA:-}" ]]; then
  save_json "$ATTR_DATA" "$OUTPUT_DIR/contexts/context_attributes.json"
  log "Saved context_attributes.json"
fi
echo

# 6c. Context instances — paginated search per kind
CONTINUATION_TOKEN=""

fetch_contexts_for_kind() {
  local kind="$1"
  local out_dir="$2"
  local page=1
  local total_saved=0
  CONTINUATION_TOKEN=""

  log "  Fetching context instances for kind: '$kind' (limit=$CONTEXT_LIMIT)..."

  while true; do
    # Build payload; include continuationToken only when set
    if [[ -n "$CONTINUATION_TOKEN" ]]; then
      local payload="{\"filter\":\"kind:${kind}\",\"limit\":50,\"continuationToken\":\"${CONTINUATION_TOKEN}\"}"
    else
      local payload="{\"filter\":\"kind:${kind}\",\"limit\":50}"
    fi

    local search_url="${API_BASE}/projects/${PROJECT_KEY}/environments/${ENV_KEY}/contexts/search"
    local body
    body=$(ld_post "$search_url" "$payload") || {
      log "  WARN: search failed for kind='$kind' on page $page — skipping"
      break
    }

    save_json "$body" "${out_dir}/page_${page}.json"

    local fetched=0
    if command -v jq &>/dev/null; then
      fetched=$(echo "$body" | jq '.items | length')
      total_saved=$((total_saved + fetched))
      CONTINUATION_TOKEN=$(echo "$body" | jq -r '.continuationToken // empty')
    fi

    log "    page $page: ${fetched} context instance(s)"

    # Stop conditions: no more pages, no items, or hit our limit
    if [[ -z "$CONTINUATION_TOKEN" || "$fetched" -eq 0 || "$total_saved" -ge "$CONTEXT_LIMIT" ]]; then
      break
    fi

    page=$((page + 1))
  done

  log "  Total saved for kind '$kind': $total_saved instance(s)"
}

if [[ -n "$KIND_KEYS" ]]; then
  log "Downloading context instances per kind..."
  while IFS= read -r kind; do
    [[ -z "$kind" ]] && continue
    mkdir -p "$OUTPUT_DIR/contexts/$kind"
    fetch_contexts_for_kind "$kind" "$OUTPUT_DIR/contexts/$kind"
  done <<< "$KIND_KEYS"
else
  # Fallback: no jq / no kinds — try a generic GET list
  log "Fetching context instances (generic, no kind filter)..."
  CTX_URL="${API_BASE}/projects/${PROJECT_KEY}/environments/${ENV_KEY}/contexts?limit=50"
  CTX_DATA=$(ld_get "$CTX_URL") || { log "WARN: Could not fetch contexts."; CTX_DATA=""; }
  if [[ -n "${CTX_DATA:-}" ]]; then
    save_json "$CTX_DATA" "$OUTPUT_DIR/contexts/contexts_all.json"
    log "Saved contexts_all.json"
  fi
fi
echo

# ---------------------------------------------------------------------------
# 7. Summary manifest
# ---------------------------------------------------------------------------
MANIFEST="$OUTPUT_DIR/manifest.txt"
{
  echo "LaunchDarkly Export"
  echo "==================="
  echo "Generated         : $(date)"
  echo "Project           : $PROJECT_KEY"
  echo "Environment       : $ENV_KEY"
  echo "Context limit     : $CONTEXT_LIMIT per kind"
  echo "Context lookback  : last $CONTEXT_FILTER_DAYS days"
  echo ""
  echo "Files:"
  find "$OUTPUT_DIR" -type f | sort
} > "$MANIFEST"

log "Done! All data saved to: $OUTPUT_DIR"
log "See manifest.txt for a full file listing."
