#!/usr/bin/env bash
# Run a task through the local `opencode` CLI (OpenRouter models) instead of
# spending Claude tokens on it. Prints the model's final text reply to
# stdout; diagnostics (model used, tokens, cost) go to stderr, unless -j is
# given, in which case a single JSON object goes to stdout instead.
set -euo pipefail

DEFAULT_MODEL="opencode/deepseek-v4-flash-free"
MODEL="$DEFAULT_MODEL"
VARIANT=""
FILES=()
CONTINUE=0
SESSION_ID=""
TIMEOUT_SECS=""
JSON_OUT=0
DRYRUN=0
DIR=""
AGENT=""
AUTO=0
LIST_ONLY=0
PAID_OK=0

usage() {
  cat >&2 <<EOF
Usage: offload.sh [options] "<prompt>"       (prompt may also be piped via stdin)
       offload.sh -l                          # list available models

Cost guard (on by default):
  Only known free models (\$0 input/output cost, per 'opencode models --verbose')
  are ever used unless you pass -P. Any paid model in -m is skipped with a
  message, not silently billed.
  -P                      allow paid models (disables the free-only guard)

Model selection:
  -m model[,model2,...]  provider/model, comma-separated fallbacks tried in order
                          (default: ${DEFAULT_MODEL})
  -e variant              reasoning effort/variant, e.g. high, max, minimal

Input:
  -f file                 attach a file (repeatable)

Session continuity (passthrough to opencode):
  -c                      continue the most recent opencode session
  -s session_id           continue a specific session id

Reliability:
  -t seconds              kill the opencode call if it runs longer than this

Output:
  -j                      emit one JSON object {text,model,tokens,cost,sessionID}
                          to stdout instead of text+stderr-diagnostics
  -n                      dry run: print what would be run and exit, no call made

File-editing agent mode (opencode's own agent gets real read/write tool access
in the given directory -- higher blast radius, off unless you set -d):
  -d dir                  directory opencode's agent may read/write in
  -A agent                opencode agent preset to use (e.g. build, plan, explore)
  -U                      auto-approve opencode's own permission prompts (dangerous;
                          only meaningful together with -d/-A)

  -l                      list models opencode knows about (free-only unless -P), then exit
  -h                      this help
EOF
}

# Prints one compact JSON object per model known to opencode, each with a
# "__key__" field set to its "provider/id" string plus opencode's own cost
# metadata -- used to enforce/inspect the free-only guard below.
#
# Goes through a temp file rather than a straight pipe: `opencode models
# --verbose` truncates when piped directly into another process (it appears
# to exit before its stdout pipe fully drains), but writing to a file first
# is reliable.
model_cost_lookup() {
  local tmp
  tmp="$(mktemp)"
  opencode models --verbose >"$tmp" 2>/dev/null
  awk '
    /^[^ {}]/ { key = $0; next }
    /^{$/ { print "{\"__key__\": \"" key "\","; next }
    { print }
  ' "$tmp" | jq -c '.'
  rm -f "$tmp"
}

while getopts "m:e:f:lcs:t:jnd:A:UPh" opt; do
  case "$opt" in
    m) MODEL="$OPTARG" ;;
    e) VARIANT="$OPTARG" ;;
    f) FILES+=("$OPTARG") ;;
    l) LIST_ONLY=1 ;;
    c) CONTINUE=1 ;;
    s) SESSION_ID="$OPTARG" ;;
    t) TIMEOUT_SECS="$OPTARG" ;;
    j) JSON_OUT=1 ;;
    n) DRYRUN=1 ;;
    d) DIR="$OPTARG" ;;
    A) AGENT="$OPTARG" ;;
    U) AUTO=1 ;;
    P) PAID_OK=1 ;;
    h) usage; exit 0 ;;
    *) usage; exit 1 ;;
  esac
done
shift $((OPTIND - 1))

if ! command -v opencode >/dev/null 2>&1; then
  echo "Error: 'opencode' CLI not found on PATH." >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "Error: 'jq' is required to parse opencode's output." >&2
  exit 1
fi

if [[ "$LIST_ONLY" == "1" ]]; then
  if [[ "$PAID_OK" == "1" ]]; then
    exec opencode models
  fi
  model_cost_lookup | jq -r 'select(.cost.input == 0 and .cost.output == 0) | .__key__' | sort
  exit 0
fi

PROMPT="${1:-}"
if [[ -z "$PROMPT" && ! -t 0 ]]; then
  PROMPT="$(cat -)"
fi
if [[ -z "$PROMPT" ]]; then
  echo "Error: no prompt given (pass as an argument or pipe via stdin)." >&2
  usage
  exit 1
fi

IFS=',' read -ra MODELS <<< "$MODEL"

if [[ "$PAID_OK" != "1" && "$MODEL" != "$DEFAULT_MODEL" ]]; then
  LOOKUP="$(model_cost_lookup)"
  FREE_KEYS="$(jq -r 'select(.cost.input == 0 and .cost.output == 0) | .__key__' <<<"$LOOKUP")"
  KNOWN_KEYS="$(jq -r '.__key__' <<<"$LOOKUP")"
  FILTERED=()
  for candidate in "${MODELS[@]}"; do
    if grep -Fxq "$candidate" <<<"$FREE_KEYS"; then
      FILTERED+=("$candidate")
    elif grep -Fxq "$candidate" <<<"$KNOWN_KEYS"; then
      echo "[offload] skipping '$candidate' -- known paid model (pass -P to allow paid models)" >&2
    else
      echo "[offload] skipping '$candidate' -- unknown model, cannot verify it's free (pass -P to use it anyway)" >&2
    fi
  done
  if [[ ${#FILTERED[@]} -eq 0 ]]; then
    echo "Error: no free models left in '${MODEL}' after the free-only guard. Pass -P to allow paid models." >&2
    exit 1
  fi
  MODELS=("${FILTERED[@]}")
fi

BASE_ARGS=(run "$PROMPT" --format json)
[[ -n "$VARIANT" ]] && BASE_ARGS+=(--variant "$VARIANT")
for f in "${FILES[@]:-}"; do
  [[ -n "$f" ]] && BASE_ARGS+=(-f "$f")
done
[[ "$CONTINUE" == "1" ]] && BASE_ARGS+=(--continue)
[[ -n "$SESSION_ID" ]] && BASE_ARGS+=(--session "$SESSION_ID")
[[ -n "$DIR" ]] && BASE_ARGS+=(--dir "$DIR")
[[ -n "$AGENT" ]] && BASE_ARGS+=(--agent "$AGENT")
if [[ "$AUTO" == "1" ]]; then
  echo "[offload] WARNING: -U/--auto set -- opencode will auto-approve its own permission prompts and can read/write files in '${DIR:-the current directory}' unattended." >&2
  BASE_ARGS+=(--auto)
fi

if [[ "$DRYRUN" == "1" ]]; then
  {
    echo "[offload] dry run -- nothing executed"
    echo "[offload] models to try in order: ${MODELS[*]}"
    echo "[offload] opencode ${BASE_ARGS[*]} --model <one of the above>"
    [[ -n "$TIMEOUT_SECS" ]] && echo "[offload] timeout: ${TIMEOUT_SECS}s"
    printf '[offload] prompt preview: %.200s%s\n' "$PROMPT" "$([[ ${#PROMPT} -gt 200 ]] && echo '...')"
  } >&2
  exit 0
fi

RAW=""
USED_MODEL=""
for candidate in "${MODELS[@]}"; do
  ATTEMPT_ARGS=("${BASE_ARGS[@]}" --model "$candidate")
  if [[ -n "$TIMEOUT_SECS" ]]; then
    if RAW="$(timeout "$TIMEOUT_SECS" opencode "${ATTEMPT_ARGS[@]}" 2>&1)"; then
      USED_MODEL="$candidate"
      break
    fi
  else
    if RAW="$(opencode "${ATTEMPT_ARGS[@]}" 2>&1)"; then
      USED_MODEL="$candidate"
      break
    fi
  fi
  echo "[offload] model '$candidate' failed, trying next..." >&2
done

if [[ -z "$USED_MODEL" ]]; then
  echo "Error: all models failed (${MODELS[*]}). Last output:" >&2
  echo "$RAW" >&2
  exit 1
fi

TEXT="$(echo "$RAW" | jq -rs '[.[] | select(.type=="text") | .part.text] | join("")' 2>/dev/null || true)"

if [[ -z "$TEXT" ]]; then
  echo "Error: no text output parsed from opencode. Raw output:" >&2
  echo "$RAW" >&2
  exit 1
fi

SUMMARY_JSON="$(echo "$RAW" | jq -cs --arg model "$USED_MODEL" '
  ([.[] | select(.type=="step_finish")] | last // {}) as $sf |
  ([.[] | .sessionID] | first // "") as $sid |
  {model: $model, tokens: ($sf.part.tokens.total // null), cost: ($sf.part.cost // null), sessionID: $sid}
' 2>/dev/null || echo '{}')"

if [[ "$JSON_OUT" == "1" ]]; then
  jq -c --arg text "$TEXT" '. + {text: $text}' <<<"$SUMMARY_JSON"
else
  TOKENS="$(jq -r '.tokens // "?"' <<<"$SUMMARY_JSON")"
  COST="$(jq -r '.cost // "?"' <<<"$SUMMARY_JSON")"
  SID="$(jq -r '.sessionID // ""' <<<"$SUMMARY_JSON")"
  echo "[offload] model=$USED_MODEL tokens=$TOKENS cost=$COST${SID:+ session=$SID}" >&2
  printf '%s\n' "$TEXT"
fi
