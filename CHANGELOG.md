# Changelog

## 1.1.0

### Fixed
- **Default model no longer exists.** `opencode/deepseek-v4-flash-free` was removed from
  opencode, so every call without `-m` failed. The default is now a preferred list of free
  models that is pruned against opencode's live free list and falls back to whatever is
  free right now — it can't go stale again. Override with `$OFFLOAD_MODELS`.
- **Fallbacks didn't trigger on provider errors.** opencode exits 0 when the provider
  returns an error; success is now decided from the event stream (an `error` event, an
  empty reply or a timeout is a failure), so the next model in `-m` is actually tried.
- **Calls could hang forever.** `opencode run` reads stdin as extra prompt text when
  it isn't a terminal and waits for EOF; under an agent harness or a background shell
  stdin stays open, so the call never returned. opencode now always runs with stdin
  closed, and every call has a timeout as a safety net (default 600s, `-t 0` disables).
- Very long prompts no longer hit the OS argument-length limit: they're passed directly
  up to ~900 KB on macOS (~120 KB on Linux) and only beyond that sent as an attached file.
- Clear error message for a missing `-f` file instead of a failed model call.

### Added
- `-J`: the reply must be JSON — extracted from code fences/prose, validated, printed
  compactly; an invalid reply is retried or falls through to the next model.
- `-b file` / `-k n`: batch mode — one prompt per line or JSONL `{"id","prompt"}`,
  `n` calls in parallel, one JSON result per input line in input order.
- `-r n`: retries with exponential backoff for transient failures (rate limits,
  overload, timeouts, empty or invalid replies); permanent errors skip to the next model.
- Plain calls run in an empty directory of their own (`~/.cache/opencode-offload/workdir`):
  isolated from the caller's project, ~30% faster startup, and sessions stay resumable. `-d` still opts into a real directory.
- Model list cached for 6h (`-R` to refresh); `-l` reads the cache.
- `-V` version flag; `attempts` field in `-j` output.
- `tests/run.sh`: offline tests (28 checks), passing on bash 3.2 and newer.
- perl fallback for `-t` on systems without `timeout(1)` (stock macOS).
