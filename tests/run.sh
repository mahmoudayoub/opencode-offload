#!/usr/bin/env bash
# Offline tests for scripts/offload.sh helpers (no network, no model calls).
#   bash tests/run.sh           # uses whatever bash is on PATH
#   /bin/bash tests/run.sh      # stock macOS bash 3.2
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../scripts/offload.sh
source "$HERE/../scripts/offload.sh"
set +e

pass=0 fail=0
check() {  # check "name" "expected" "actual"
  if [[ "$2" == "$3" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"; fi
}

# --- extract_json
check "plain object"        '{"a":1}'       "$(extract_json <<<'{"a": 1}')"
check "fenced json"         '{"a":[1,2]}'   "$(extract_json <<<$'Here you go:\n```json\n{"a": [1, 2]}\n```\nEnjoy')"
check "bare fence"          '{"b":true}'    "$(extract_json <<<$'```\n{"b": true}\n```')"
check "prose around object" '{"c":"x"}'     "$(extract_json <<<'Sure! {"c": "x"} Hope that helps.')"
check "array"               '[1,2,3]'       "$(extract_json <<<'The list: [1, 2, 3]')"
check "nested braces"       '{"o":{"p":{}}}' "$(extract_json <<<'x {"o": {"p": {}}} y')"
extract_json <<<'no json here' >/dev/null 2>&1; check "no json fails" "1" "$([[ $? -ne 0 ]] && echo 1 || echo 0)"
extract_json <<<'{"broken": ' >/dev/null 2>&1;   check "broken json fails" "1" "$([[ $? -ne 0 ]] && echo 1 || echo 0)"

# --- event stream parsing (shapes taken from real `opencode run --format json` output)
ok_stream='{"type":"step_start","sessionID":"ses_1"}
some non-JSON log line
{"type":"text","sessionID":"ses_1","part":{"text":"Hel"}}
{"type":"text","sessionID":"ses_1","part":{"text":"lo"}}
{"type":"step_finish","sessionID":"ses_1","part":{"tokens":{"total":42},"cost":0}}'
err_stream='{"type":"error","sessionID":"ses_2","error":{"name":"UnknownError","data":{"message":"Unexpected server error. Check server logs for details."}}}'
check "text joined"          "Hello" "$(events_text <<<"$ok_stream")"
check "no error on success"  ""      "$(events_error <<<"$ok_stream")"
check "error message"        "Unexpected server error. Check server logs for details." "$(events_error <<<"$err_stream")"
check "no text on error"     ""      "$(events_text <<<"$err_stream")"
check "summary"              '{"model":"m/x","tokens":42,"cost":0,"sessionID":"ses_1"}' "$(events_summary m/x <<<"$ok_stream")"
check "empty stream"         ""      "$(events_text <<<"")"

# --- retry classification
for e in "timed out after 30s" "Rate limit exceeded" "HTTP 429 Too Many Requests" "model overloaded" "empty reply (opencode exit code 0)" "reply was not valid JSON"; do
  check "transient: $e" "yes" "$(is_transient <<<"$e" && echo yes || echo no)"
done
for e in "Unexpected server error. Check server logs for details." "OpenCode's free tier can only be used from within OpenCode" "Model not found"; do
  check "permanent: $e" "no" "$(is_transient <<<"$e" && echo yes || echo no)"
done

# --- model selection against a fake model list (no opencode call: cache is pre-seeded)
export XDG_CACHE_HOME; XDG_CACHE_HOME="$(mktemp -d)"
CACHE_DIR="$XDG_CACHE_HOME/opencode-offload"; mkdir -p "$CACHE_DIR"
cat >"$CACHE_DIR/models.jsonl" <<'EOF'
{"__key__":"opencode/free-a","cost":{"input":0,"output":0}}
{"__key__":"openrouter/x/free-b:free","cost":{"input":0,"output":0}}
{"__key__":"openrouter/x/paid-c","cost":{"input":1,"output":2}}
EOF
MODEL=""; DEFAULT_MODELS="opencode/gone-1,opencode/gone-2"; PAID_OK=0; REFRESH=0
resolve_models 2>/dev/null
check "stale defaults fall back to live free models" "opencode/free-a openrouter/x/free-b:free" "${MODELS[*]}"
DEFAULT_MODELS="opencode/gone-1,openrouter/x/free-b:free"
resolve_models 2>/dev/null
check "defaults pruned to available"  "openrouter/x/free-b:free" "${MODELS[*]}"
MODEL="openrouter/x/paid-c,opencode/free-a"
resolve_models 2>/dev/null
check "paid model skipped by guard"   "opencode/free-a" "${MODELS[*]}"
MODEL="openrouter/x/paid-c"
( resolve_models >/dev/null 2>&1 ); check "only-paid list refused" "1" "$([[ $? -ne 0 ]] && echo 1 || echo 0)"
MODEL="openrouter/x/paid-c"; PAID_OK=1
resolve_models 2>/dev/null
check "-P allows paid"                "openrouter/x/paid-c" "${MODELS[*]}"
rm -rf "$XDG_CACHE_HOME"

echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
