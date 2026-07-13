#!/usr/bin/env bash

CODEX_ALLOWED_BUILD_WARNING='Metadata extraction skipped. No AppIntents.framework dependency found.'

filter_actionable_build_warnings() {
  local log_path="$1"
  local output_path="$2"
  local all_warnings_path="${output_path}.all"

  grep -E '(^|[[:space:]])warning:' "$log_path" > "$all_warnings_path" || true
  awk -v allowed="$CODEX_ALLOWED_BUILD_WARNING" '
    {
      message = $0
      if (match(message, /(^|[[:space:]])warning:[[:space:]]*/)) {
        message = substr(message, RSTART + RLENGTH)
      }
      if (message != allowed) {
        print $0
      }
    }
  ' "$all_warnings_path" > "$output_path"
  rm -f -- "$all_warnings_path"
}
