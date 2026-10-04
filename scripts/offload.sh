#!/usr/bin/env bash
# Run a task through the local `opencode` CLI (OpenRouter / opencode models) instead of
# spending Claude tokens on it. Prints the model's final text reply to stdout;
# diagnostics (model used, tokens, cost) go to stderr, unless -j is given, in which
# case a single JSON object goes to stdout instead.
#
# Compatible with the stock macOS bash (3.2): no associative arrays, no mapfile,
# and possibly-empty arrays are expanded as ${arr[@]+"${arr[@]}"}.
set -euo pipefail

VERSION="1.1.0"
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

# Preferred free models, tried in order when -m is not given. The list is checked
# against opencode's live free-model list; if none of them is offered any more, the
# first free models opencode does offer are used instead (so this never goes stale).
DEFAULT_MODELS="${OFFLOAD_MODELS:-opencode/nemotron-3-ultra-free,openrouter/nvidia/nemotron-3-super-120b-a12b:free,openrouter/google/gemma-4-31b-it:free}"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/opencode-offload"
CACHE_TTL="${OFFLOAD_CACHE_TTL:-21600}"   # seconds the model list is cached (6h)
# Prompts are passed to opencode as one argument (that's what works best: attached-file
# prompts get empty replies from some models). Above the OS limit for a single argument
# (~1 MB total on macOS, 128 KB per argument on Linux) they fall back to an attached file.
if [[ "$(uname -s)" == "Darwin" ]]; then MAX_ARG_PROMPT=900000; else MAX_ARG_PROMPT=120000; fi

MODEL=""
VARIANT=""
FILES=()
MODELS=()
CONTINUE=0
SESSION_ID=""
TIMEOUT_SECS="${OFFLOAD_TIMEOUT:-600}"   # safety net: a call can never hang forever
RETRIES=1
JSON_OUT=0
JSON_REPLY=0
DRYRUN=0
DIR=""
AGENT=""
AUTO=0
LIST_ONLY=0
PAID_OK=0
REFRESH=0
BATCH=""
CONCURRENCY=4
CLEANUP=()   # temp dirs removed on exit

usage() {
  cat >&2 <<EOF
opencode-offload ${VERSION}

Usage: offload.sh [options] "<prompt>"       (prompt may also be piped via stdin)
       offload.sh -b prompts.txt [options]    batch: one prompt per line -> JSONL results
       offload.sh -l                          list free models

Cost guard (on by default):
  Only known free models (\$0 input/output cost, per 'opencode models --verbose')
  are ever used unless you pass -P. Any paid model in -m is skipped with a
  message, not silently billed.
  -P                      allow paid models (disables the free-only guard)

Model selection:
  -m model[,model2,...]  provider/model, comma-separated fallbacks tried in order
                          (default: preferred free models, auto-pruned to what
                          opencode currently offers; override with \$OFFLOAD_MODELS)
  -e variant              reasoning effort/variant, e.g. high, max, minimal
  -R                      refresh the cached model list (cached ${CACHE_TTL}s)

Input:
  -f file                 attach a file (repeatable)

Session continuity (passthrough to opencode):
  -c                      continue the most recent opencode session
  -s session_id           continue a specific session id

Reliability:
  -t seconds              kill a call that runs longer than this
                          (default ${TIMEOUT_SECS}; 0 disables)
  -r n                    retries per model for transient failures
                          (timeouts, rate limits, overload; default ${RETRIES})

Output:
  -j                      emit one JSON object {text,model,tokens,cost,sessionID,attempts}
                          to stdout instead of text+stderr-diagnostics
  -J                      the reply must be JSON: extract it (code fences and
                          surrounding prose are stripped), validate it, and print it
                          compactly; an invalid reply counts as a failure (retry/next model)
  -n                      dry run: print what would be run and exit, no call made

Batch:
  -b file                 one prompt per line, or JSONL lines {"id": ..., "prompt": ...};
                          prints one JSON result per input line, in input order
  -k n                    parallel calls in batch mode (default ${CONCURRENCY})

File-editing agent mode (opencode's own agent gets real read/write tool access
in the given directory -- higher blast radius, off unless you set -d):
  -d dir                  directory opencode's agent may read/write in
  -A agent                opencode agent preset to use (e.g. build, plan, explore)
  -U                      auto-approve opencode's own permission prompts (dangerous;
                          only meaningful together with -d/-A)

Without -d, calls run in an empty directory of their own (~/.cache/opencode-offload/workdir),
so opencode's agent cannot see or touch the current project (and starts faster).

  -l                      list free models (all models with -P), then exit
  -V                      print version
  -h                      this help
EOF
}

log() { echo "[offload] $*" >&2; }
die() { echo "Error: $*" >&2; exit 1; }

cleanup() { local d; for d in ${CLEANUP[@]+"${CLEANUP[@]}"}; do rm -rf "$d"; done; }
new_tmpdir() { local d; d="$(mktemp -d)"; CLEANUP+=("$d"); echo "$d"; }

file_mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0; }

# One compact JSON object per model known to opencode, each with a "__key__" field
# ("provider/id") plus opencode's own cost metadata. Cached for CACHE_TTL seconds.
#
# Goes through a temp file rather than a straight pipe: `opencode models --verbose`
# truncates when piped directly into another process (it appears to exit before its
# stdout pipe fully drains), but writing to a file first is reliable.
model_lookup() {
  local cache="$CACHE_DIR/models.jsonl" tmp now
  now="$(date +%s)"
  if [[ "$REFRESH" != "1" && -s "$cache" ]] && (( now - $(file_mtime "$cache") < CACHE_TTL )); then
    cat "$cache"
    return
  fi
  mkdir -p "$CACHE_DIR"
  tmp="$(mktemp)"
  opencode models --verbose >"$tmp" 2>/dev/null || true
  if awk '
      /^[^ {}]/ { key = $0; next }
      /^{$/ { print "{\"__key__\": \"" key "\","; next }
      { print }
    ' "$tmp" | jq -c '.' >"$cache.tmp.$$" 2>/dev/null && [[ -s "$cache.tmp.$$" ]]; then
    mv "$cache.tmp.$$" "$cache"
  else
    rm -f "$cache.tmp.$$"
  fi
  rm -f "$tmp"
  cat "$cache" 2>/dev/null || true
}

free_models()  { jq -r 'select(.cost.input == 0 and .cost.output == 0) | .__key__'; }
known_models() { jq -r '.__key__'; }

# Text of all "text" events in an opencode --format json stream (non-JSON lines ignored).
events_text() { jq -Rrn '[inputs | fromjson? | select(.type == "text") | .part.text] | join("")'; }
# First error message in the stream, if any.
events_error() {
  jq -Rrn '[inputs | fromjson? | select(.type == "error") | (.error.data.message // .error.name // "error")] | first // empty'
}
# {model,tokens,cost,sessionID} summary of the stream.
events_summary() {
  jq -Rcn --arg model "$1" '
    [inputs | fromjson?] as $ev |
    ([$ev[] | select(.type == "step_finish")] | last // {}) as $sf |
    {model: $model, tokens: ($sf.part.tokens.total // null), cost: ($sf.part.cost // null),
     sessionID: ([$ev[] | .sessionID? // empty] | first // "")}'
}

# Pull a JSON value out of a model reply: the whole reply, a ```json fenced block,
# or the widest {...} / [...] span. Prints it compactly; fails if none parses.
extract_json() {
  jq -Rsce '
    def try_parse: (try fromjson catch null);
    (try_parse)
    // ([capture("```(?:json|JSON)?\\s*(?<j>[\\s\\S]*?)\\s*```"; "g").j | try_parse] | map(select(. != null)) | first)
    // (capture("(?<j>\\{[\\s\\S]*\\})").j | try_parse)
    // (capture("(?<j>\\[[\\s\\S]*\\])").j | try_parse)
    // error("no JSON found in reply")'
}

# Errors worth retrying on the same model; anything else moves straight to the next one.
is_transient() {
  grep -qiE 'timed out|rate.?limit|429|too many requests|overload|temporar|503|502|504|ECONNRESET|socket hang up|network|empty reply|not valid JSON'
}

run_with_timeout() {
  if [[ -z "$TIMEOUT_SECS" || "$TIMEOUT_SECS" == "0" ]]; then
    "$@"
  elif command -v timeout >/dev/null 2>&1; then
    timeout "$TIMEOUT_SECS" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$TIMEOUT_SECS" "$@"
  else  # stock macOS has no timeout(1); perl's alarm gives the same exit code (124 on timeout)
    perl -e 'my $t = shift; my $pid = fork; if (!$pid) { exec @ARGV or exit 127 }
             local $SIG{ALRM} = sub { kill "TERM", $pid; sleep 1; kill "KILL", $pid; exit 124 };
             alarm $t; waitpid $pid, 0; exit($? >> 8)' "$TIMEOUT_SECS" "$@"
  fi
}

# ---------------------------------------------------------------- model selection
resolve_models() {
  local spec="${MODEL:-$DEFAULT_MODELS}" lookup free known candidate
  local requested=() kept=()
  IFS=',' read -ra requested <<< "$spec"

  if [[ "$PAID_OK" == "1" ]]; then
    MODELS=("${requested[@]}")
    return
  fi

  lookup="$(model_lookup)"
  if [[ -z "$lookup" ]]; then
    if [[ -z "$MODEL" ]]; then
      log "could not read opencode's model list; trying the built-in free defaults unverified"
      MODELS=("${requested[@]}")
      return
    fi
    die "could not read opencode's model list to verify '$spec' is free. Pass -P to skip the check."
  fi
  free="$(free_models <<<"$lookup")"
  known="$(known_models <<<"$lookup")"

  for candidate in "${requested[@]}"; do
    candidate="$(echo "$candidate" | tr -d '[:space:]')"
    [[ -z "$candidate" ]] && continue
    if grep -Fxq "$candidate" <<<"$free"; then
      kept+=("$candidate")
    elif grep -Fxq "$candidate" <<<"$known"; then
      log "skipping '$candidate' -- known paid model (pass -P to allow paid models)"
    elif [[ -z "$MODEL" ]]; then
      log "skipping default '$candidate' -- no longer offered by opencode"
    else
      log "skipping '$candidate' -- unknown model, cannot verify it's free (pass -P to use it anyway; -R refreshes the model list)"
    fi
  done

  if [[ ${#kept[@]} -eq 0 && -z "$MODEL" ]]; then
    # None of the preferred defaults exist any more: fall back to what opencode offers
    # for free right now, opencode's own free tier first.
    while IFS= read -r candidate; do
      [[ -n "$candidate" ]] && kept+=("$candidate")
      [[ ${#kept[@]} -ge 3 ]] && break
    done < <( { grep '^opencode/' <<<"$free" || true; grep -v '^opencode/' <<<"$free" || true; } )
    [[ ${#kept[@]} -gt 0 ]] && log "preferred defaults unavailable; using ${kept[*]}"
  fi

  if [[ ${#kept[@]} -eq 0 ]]; then
    die "no free models left in '${spec}' after the free-only guard. Pass -P to allow paid models."
  fi
  MODELS=("${kept[@]}")
}

# ---------------------------------------------------------------- batch mode
run_batch() {
  [[ -r "$BATCH" ]] || die "batch file '$BATCH' not found"
  local work n=0 line id prompt base child=() f ok=0 failed=0 total
  work="$(new_tmpdir)"

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$(echo "$line" | tr -d '[:space:]')" ]] && continue
    n=$((n + 1))
    base="$work/$(printf '%06d' "$n")"
    id="$n"
    prompt="$line"
    if jq -e 'type == "object" and has("prompt")' <<<"$line" >/dev/null 2>&1; then
      prompt="$(jq -r '.prompt' <<<"$line")"
      id="$(jq -c '.id // empty' <<<"$line")"
      [[ -z "$id" ]] && id="$n"
    fi
    printf '%s' "$prompt" >"$base.prompt"
    printf '%s' "$id" >"$base.id"
  done <"$BATCH"
  total="$n"
  [[ "$total" -gt 0 ]] || die "batch file '$BATCH' has no prompts"

  resolve_models   # once, so every item uses the same verified list (and the cache is warm)
  child=(-j -m "$(IFS=,; echo "${MODELS[*]}")" -r "$RETRIES")
  [[ "$PAID_OK" == "1" ]] && child+=(-P)
  [[ "$JSON_REPLY" == "1" ]] && child+=(-J)
  [[ -n "$TIMEOUT_SECS" ]] && child+=(-t "$TIMEOUT_SECS")
  [[ -n "$VARIANT" ]] && child+=(-e "$VARIANT")
  for f in ${FILES[@]+"${FILES[@]}"}; do child+=(-f "$f"); done

  if [[ "$DRYRUN" == "1" ]]; then
    log "dry run -- $total prompts, $CONCURRENCY in parallel, each: offload.sh ${child[*]}"
    return 0
  fi
  log "batch: $total prompts, $CONCURRENCY in parallel, models: ${MODELS[*]}"

  # Each item N runs: offload.sh <child args> < N.prompt > N.out 2> N.err
  # (relative names keep xargs' substituted command short; BSD xargs caps it at 255 bytes)
  ( cd "$work" && ls -- *.prompt | sed 's/\.prompt$//' |
      xargs -P "$CONCURRENCY" -I{} sh -c '"$@" < {}.prompt > {}.out 2> {}.err; echo done >&2' _ "$SELF" "${child[@]}" 2>&1 |
      { i=0; while read -r _; do i=$((i + 1)); if [[ $((i % 10)) -eq 0 || $i -eq $total ]]; then log "batch progress $i/$total"; fi; done; } )

  for f in "$work"/*.prompt; do
    base="${f%.prompt}"
    id="$(cat "$base.id")"
    jq -e . "$base.id" >/dev/null 2>&1 || id="$(jq -Rn --arg v "$id" '$v')"
    if [[ -s "$base.out" ]] && jq -e . "$base.out" >/dev/null 2>&1; then
      jq -c --argjson id "$id" '{id: $id, ok: true} + .' "$base.out"
      ok=$((ok + 1))
    else
      jq -cn --argjson id "$id" --arg err "$(grep -v '^\[offload\]' "$base.err" | tail -3 | tr '\n' ' ' | sed 's/ *$//')" \
        '{id: $id, ok: false, error: (if $err == "" then "failed" else $err end)}'
      failed=$((failed + 1))
    fi
  done
  log "batch done: $ok ok, $failed failed"
  [[ "$failed" -eq 0 ]]
}

# ---------------------------------------------------------------- main
main() {
  local opt
  while getopts "m:e:f:lcs:t:r:jJnd:A:UPRb:k:Vh" opt; do
    case "$opt" in
      m) MODEL="$OPTARG" ;;
      e) VARIANT="$OPTARG" ;;
      f) FILES+=("$OPTARG") ;;
      l) LIST_ONLY=1 ;;
      c) CONTINUE=1 ;;
      s) SESSION_ID="$OPTARG" ;;
      t) TIMEOUT_SECS="$OPTARG" ;;
      r) RETRIES="$OPTARG" ;;
      j) JSON_OUT=1 ;;
      J) JSON_REPLY=1 ;;
      n) DRYRUN=1 ;;
      d) DIR="$OPTARG" ;;
      A) AGENT="$OPTARG" ;;
      U) AUTO=1 ;;
      P) PAID_OK=1 ;;
      R) REFRESH=1 ;;
      b) BATCH="$OPTARG" ;;
      k) CONCURRENCY="$OPTARG" ;;
      V) echo "opencode-offload $VERSION"; exit 0 ;;
      h) usage; exit 0 ;;
      *) usage; exit 1 ;;
    esac
  done
  shift $((OPTIND - 1))

  command -v opencode >/dev/null 2>&1 || die "'opencode' CLI not found on PATH."
  command -v jq >/dev/null 2>&1 || die "'jq' is required to parse opencode's output."
  [[ "$RETRIES" =~ ^[0-9]+$ ]] || die "-r expects a number"
  [[ "$CONCURRENCY" =~ ^[1-9][0-9]*$ ]] || die "-k expects a positive number"
  trap cleanup EXIT

  if [[ "$LIST_ONLY" == "1" ]]; then
    if [[ "$PAID_OK" == "1" ]]; then
      model_lookup | known_models | sort
    else
      model_lookup | free_models | sort
    fi
    return 0
  fi

  # Attachments are resolved to absolute paths, because the call itself runs elsewhere.
  local i abs
  for i in ${FILES[@]+"${!FILES[@]}"}; do
    abs="${FILES[$i]}"
    [[ "$abs" = /* ]] || abs="$PWD/$abs"
    [[ -e "$abs" ]] || die "attached file '${FILES[$i]}' not found"
    FILES[$i]="$abs"
  done

  if [[ -n "$BATCH" ]]; then
    run_batch
    return $?
  fi

  local prompt="${1:-}"
  if [[ -z "$prompt" && ! -t 0 ]]; then
    prompt="$(cat -)"
  fi
  if [[ -z "$prompt" ]]; then
    echo "Error: no prompt given (pass as an argument or pipe via stdin)." >&2
    usage
    exit 1
  fi

  resolve_models

  # Plain text mode runs in an empty directory of its own: opencode's agent can't read or
  # edit the caller's project, and it skips indexing it. It is persistent (not a per-call
  # temp dir) because opencode can't resume a session (-s/-c) whose directory is gone --
  # it just hangs. -d opts into a real directory.
  local workdir="$DIR"
  if [[ -z "$workdir" ]]; then
    workdir="$CACHE_DIR/workdir"
    mkdir -p "$workdir"
  fi

  local message="$prompt" attach=(${FILES[@]+"${FILES[@]}"})
  if [[ ${#prompt} -gt $MAX_ARG_PROMPT ]]; then
    # Avoid the OS argument-length limit: ship the prompt as an attached file.
    log "prompt is ${#prompt} chars, over the ${MAX_ARG_PROMPT}-char argument limit: sending it as an attached file (some models reply poorly to that; consider splitting the task)"
    local pf
    pf="$(new_tmpdir)/offload-prompt.md"
    printf '%s' "$prompt" >"$pf"
    attach+=("$pf")
    message="Your complete task is in the attached file offload-prompt.md. Follow its instructions exactly and reply with only the result."
  fi

  local base=(run "$message" --format json --dir "$workdir")
  [[ -n "$VARIANT" ]] && base+=(--variant "$VARIANT")
  local f
  for f in ${attach[@]+"${attach[@]}"}; do base+=(-f "$f"); done
  [[ "$CONTINUE" == "1" ]] && base+=(--continue)
  [[ -n "$SESSION_ID" ]] && base+=(--session "$SESSION_ID")
  [[ -n "$AGENT" ]] && base+=(--agent "$AGENT")
  if [[ "$AUTO" == "1" ]]; then
    log "WARNING: -U/--auto set -- opencode will auto-approve its own permission prompts and can read/write files in '${DIR:-a temporary directory}' unattended."
    base+=(--auto)
  fi

  if [[ "$DRYRUN" == "1" ]]; then
    log "dry run -- nothing executed"
    log "models to try in order: ${MODELS[*]} (retries per model: $RETRIES)"
    log "opencode run <prompt> --format json --dir ${DIR:-$CACHE_DIR/workdir} ${base[*]:6} --model <one of the above>"
    log "timeout: ${TIMEOUT_SECS}s per call"
    printf '[offload] prompt preview: %.200s%s\n' "$prompt" "$([[ ${#prompt} -gt 200 ]] && echo '...')" >&2
    return 0
  fi

  local candidate attempt raw rc text err reply used="" attempts=0 last_err=""
  for candidate in "${MODELS[@]}"; do
    attempt=0
    while :; do
      attempt=$((attempt + 1))
      attempts=$((attempts + 1))
      rc=0
      # stdin must be closed: when it isn't a terminal, `opencode run` reads it as extra
      # prompt text and waits for EOF -- under an agent harness or a background shell,
      # whose stdin stays open, that is forever. (The prompt itself is passed as an argument.)
      raw="$(run_with_timeout opencode "${base[@]}" --model "$candidate" </dev/null 2>/dev/null)" || rc=$?
      text="$(events_text <<<"$raw")"
      err="$(events_error <<<"$raw")"
      if [[ "$rc" == "124" ]]; then
        err="timed out after ${TIMEOUT_SECS}s"
      elif [[ -z "$err" && -z "$text" ]]; then
        err="empty reply (opencode exit code $rc)"
      fi
      if [[ -z "$err" && "$JSON_REPLY" == "1" ]]; then
        if reply="$(extract_json <<<"$text" 2>/dev/null)"; then
          text="$reply"
        else
          err="reply was not valid JSON"
        fi
      fi
      if [[ -z "$err" ]]; then
        used="$candidate"
        break 2
      fi
      last_err="$err"
      if [[ "$attempt" -le "$RETRIES" ]] && is_transient <<<"$err"; then
        log "model '$candidate' failed ($err), retrying in $((2 ** attempt))s..."
        sleep $((2 ** attempt))
        continue
      fi
      log "model '$candidate' failed: $err"
      break
    done
  done

  if [[ -z "$used" ]]; then
    die "all models failed (${MODELS[*]}). Last error: $last_err"
  fi

  local summary
  summary="$(events_summary "$used" <<<"$raw")"
  if [[ "$JSON_OUT" == "1" ]]; then
    if [[ "$JSON_REPLY" == "1" ]]; then
      jq -c --argjson json "$text" --argjson attempts "$attempts" '. + {json: $json, attempts: $attempts}' <<<"$summary"
    else
      jq -c --arg text "$text" --argjson attempts "$attempts" '. + {text: $text, attempts: $attempts}' <<<"$summary"
    fi
  else
    log "$(jq -r '"model=\(.model) tokens=\(.tokens // "?") cost=\(.cost // "?")" + (if .sessionID != "" then " session=\(.sessionID)" else "" end)' <<<"$summary") attempts=$attempts"
    printf '%s\n' "$text"
  fi
}

# Sourcing the script (as the tests do) defines the helpers without running anything.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
