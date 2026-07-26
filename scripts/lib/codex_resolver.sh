#!/usr/bin/env bash

# Canonical shell-side Codex executable discovery and bounded validation.
# Keep the fixed order and discovered-app sorting aligned with
# CodexExecutableCandidateProvider in the production module.

CODEX_PROBE_OUTPUT=""
CODEX_RESOLVER_SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CODEX_DEFAULT_CANDIDATE_MANIFEST="$(cd -- "$CODEX_RESOLVER_SCRIPT_DIR/../.." && pwd)/Resources/CodexExecutableCandidates.txt"

codex_trim_manifest_line() {
  printf '%s' "$1" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//'
}

codex_validate_candidate_manifest() {
  local manifest_path="${1:-${CODEX_CANDIDATE_MANIFEST:-$CODEX_DEFAULT_CANDIDATE_MANIFEST}}"
  local line
  local candidate_count=0
  local seen_candidate
  local -a seen=("__codex_manifest_sentinel__")

  [[ -f "$manifest_path" && ! -L "$manifest_path" ]] || {
    echo "Codex candidate manifest is missing or symlinked: $manifest_path" >&2
    return 1
  }

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="$(codex_trim_manifest_line "$line")"
    [[ -n "$line" && "$line" != \#* ]] || continue
    [[ "$line" == /* && "$line" != *[[:cntrl:]]* ]] || {
      echo "Invalid Codex candidate manifest entry: $line" >&2
      return 1
    }
    for seen_candidate in "${seen[@]}"; do
      if [[ "$seen_candidate" == "$line" ]]; then
        echo "Duplicate Codex candidate manifest entry: $line" >&2
        return 1
      fi
    done
    seen+=("$line")
    candidate_count=$((candidate_count + 1))
  done < "$manifest_path"

  [[ "$candidate_count" -gt 0 ]] || {
    echo "Codex candidate manifest contains no executable paths: $manifest_path" >&2
    return 1
  }
}

codex_fixed_candidate_paths() {
  local manifest_path="${CODEX_CANDIDATE_MANIFEST:-$CODEX_DEFAULT_CANDIDATE_MANIFEST}"
  local applications_dir="${CODEX_APPLICATIONS_DIR:-/Applications}"
  local fixed_candidate

  codex_validate_candidate_manifest "$manifest_path" || return 1
  while IFS= read -r fixed_candidate || [[ -n "$fixed_candidate" ]]; do
    fixed_candidate="$(codex_trim_manifest_line "$fixed_candidate")"
    [[ -n "$fixed_candidate" && "$fixed_candidate" != \#* ]] || continue
    case "$fixed_candidate" in
      /Applications/*)
        printf '%s/%s\n' "$applications_dir" "${fixed_candidate#/Applications/}"
        ;;
      /opt/homebrew/bin/codex)
        printf '%s\n' "${CODEX_HOMEBREW_CANDIDATE:-$fixed_candidate}"
        ;;
      /usr/local/bin/codex)
        printf '%s\n' "${CODEX_USR_LOCAL_CANDIDATE:-$fixed_candidate}"
        ;;
      *)
        printf '%s\n' "$fixed_candidate"
        ;;
    esac
  done < "$manifest_path"
  return 0
}

codex_stop_bounded_probe() {
  local pid="$1"
  local attempt
  local grace_attempts="${CODEX_PROBE_TERMINATION_GRACE_ATTEMPTS:-5}"
  local termination_interval="${CODEX_PROBE_TERMINATION_INTERVAL:-0.05}"

  kill -TERM "$pid" >/dev/null 2>&1 || true
  for ((attempt = 0; attempt < grace_attempts; attempt += 1)); do
    if ! kill -0 "$pid" >/dev/null 2>&1; then
      wait "$pid" >/dev/null 2>&1 || true
      return 0
    fi
    sleep "$termination_interval"
  done

  kill -KILL "$pid" >/dev/null 2>&1 || true
  # Reap directly after the non-catchable signal. Polling kill -0 first can
  # mistake a dead, unreaped child for a still-running process.
  wait "$pid" >/dev/null 2>&1 || true
  if kill -0 "$pid" >/dev/null 2>&1; then
    echo "Timed-out Codex probe process $pid survived SIGKILL." >&2
    return 1
  fi
  return 0
}

codex_run_bounded_probe() {
  local candidate="$1"
  shift
  local output_file
  local pid
  local attempt
  local status
  local output_size
  local wait_attempts="${CODEX_PROBE_WAIT_ATTEMPTS:-20}"
  local wait_interval="${CODEX_PROBE_WAIT_INTERVAL:-0.1}"
  local maximum_output_bytes="${CODEX_PROBE_MAXIMUM_OUTPUT_BYTES:-262144}"

  CODEX_PROBE_OUTPUT=""
  output_file="$(mktemp "${TMPDIR:-/tmp}/CodexStatusBarCodexProbe.XXXXXX")" || return 1

  (
    # Limit a hostile or broken wrapper before it can fill the temporary disk.
    # POSIX shells express the file-size limit in 512-byte blocks.
    ulimit -f 512 >/dev/null 2>&1 || true
    exec "$candidate" "$@"
  ) >"$output_file" 2>&1 &
  pid=$!
  CODEX_PROBE_LAST_PID="$pid"

  for ((attempt = 0; attempt < wait_attempts; attempt += 1)); do
    if ! kill -0 "$pid" >/dev/null 2>&1; then
      status=0
      wait "$pid" || status=$?
      if [[ "$status" != "0" ]]; then
        rm -f -- "$output_file"
        return 1
      fi

      output_size="$(wc -c < "$output_file" | tr -d '[:space:]')"
      if [[ -z "$output_size" || "$output_size" -gt "$maximum_output_bytes" ]]; then
        rm -f -- "$output_file"
        return 1
      fi

      CODEX_PROBE_OUTPUT="$(<"$output_file")"
      rm -f -- "$output_file"
      return 0
    fi
    sleep "$wait_interval"
  done

  codex_stop_bounded_probe "$pid" || true
  rm -f -- "$output_file"
  return 1
}

codex_validate_candidate() {
  local candidate="$1"
  local version_output
  local capability_output

  [[ -x "$candidate" ]] || return 1

  codex_run_bounded_probe "$candidate" --version || return 1
  version_output="$CODEX_PROBE_OUTPUT"
  if [[ ! "$version_output" =~ [0-9]+(\.[0-9A-Za-z-]+)+ ]]; then
    return 1
  fi

  codex_run_bounded_probe "$candidate" app-server --help || return 1
  capability_output="$CODEX_PROBE_OUTPUT"
  case "$capability_output" in
    *stdio://*|*--stdio*|*ws://*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

codex_candidate_paths() {
  local applications_dir="${CODEX_APPLICATIONS_DIR:-/Applications}"
  local path_value="${CODEX_PATH_VALUE-${PATH:-}}"
  local discovered_bundle
  local path_entry

  codex_fixed_candidate_paths || return 1

  if [[ -d "$applications_dir" ]]; then
    while IFS= read -r discovered_bundle; do
      printf '%s\n' "$discovered_bundle/Contents/Resources/codex"
    done < <(
      find "$applications_dir" -maxdepth 1 \( -type d -o -type l \) -name 'Codex*.app' -print \
        | LC_ALL=C sort
    )
  fi

  while [[ "$path_value" == *:* ]]; do
    path_entry="${path_value%%:*}"
    path_value="${path_value#*:}"
    [[ -n "$path_entry" ]] && printf '%s\n' "$path_entry/codex"
  done
  [[ -n "$path_value" ]] && printf '%s\n' "$path_value/codex"
  return 0
}

codex_resolve_executable() {
  local candidate
  local canonical_candidate
  local is_duplicate
  local seen_candidate
  # Bash 3.2 treats an empty array expansion as unbound under `set -u`.
  local -a seen=("__codex_resolver_sentinel__")

  while IFS= read -r candidate; do
    [[ -n "$candidate" ]] || continue
    canonical_candidate="$(safe_canonical_path "$candidate")"
    is_duplicate=0
    for seen_candidate in "${seen[@]}"; do
      if [[ "$seen_candidate" == "$canonical_candidate" ]]; then
        is_duplicate=1
        break
      fi
    done
    [[ "$is_duplicate" == "0" ]] || continue
    seen+=("$canonical_candidate")

    if codex_validate_candidate "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done < <(codex_candidate_paths)

  return 1
}
