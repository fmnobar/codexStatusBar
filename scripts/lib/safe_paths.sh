#!/usr/bin/env bash

# Shared safeguards for any script that recursively removes a directory.
# Callers must opt a directory into deletion by placing a script-specific
# sentinel inside a path that is strictly contained by an allowed root.

safe_canonical_path() {
  /usr/bin/python3 -c 'import os, sys; print(os.path.realpath(os.path.abspath(sys.argv[1])))' "$1"
}

safe_assert_strict_descendant() {
  local candidate="$1"
  local allowed_root="$2"
  local candidate_path
  local root_path

  if [[ -L "$allowed_root" ]]; then
    echo "Refusing symlinked managed root: $allowed_root" >&2
    return 1
  fi

  candidate_path="$(safe_canonical_path "$candidate")"
  root_path="$(safe_canonical_path "$allowed_root")"

  case "$candidate_path" in
    "$root_path"/*)
      ;;
    *)
      echo "Refusing unsafe path outside managed root '$root_path': $candidate_path" >&2
      return 1
      ;;
  esac

  if [[ "$candidate_path" == "/" || "$candidate_path" == "$(safe_canonical_path "$HOME")" ]]; then
    echo "Refusing unsafe path: $candidate_path" >&2
    return 1
  fi
}

safe_require_owned_directory() {
  local directory="$1"
  local allowed_root="$2"
  local sentinel_name="$3"
  local sentinel_path="$directory/$sentinel_name"

  safe_assert_strict_descendant "$directory" "$allowed_root" || return 1

  if [[ -L "$directory" || ! -d "$directory" ]]; then
    echo "Refusing to remove a missing, non-directory, or symlinked path: $directory" >&2
    return 1
  fi

  if [[ -L "$sentinel_path" || ! -f "$sentinel_path" ]]; then
    echo "Refusing to remove an unowned directory without sentinel '$sentinel_name': $directory" >&2
    return 1
  fi
}

safe_prepare_owned_directory() {
  local directory="$1"
  local allowed_root="$2"
  local sentinel_name="$3"

  safe_assert_strict_descendant "$directory" "$allowed_root" || return 1

  if [[ -e "$directory" || -L "$directory" ]]; then
    safe_require_owned_directory "$directory" "$allowed_root" "$sentinel_name" || return 1
    return
  fi

  mkdir -p "$directory"
  safe_assert_strict_descendant "$directory" "$allowed_root" || return 1
  : > "$directory/$sentinel_name"
}

safe_remove_owned_directory() {
  local directory="$1"
  local allowed_root="$2"
  local sentinel_name="$3"

  safe_require_owned_directory "$directory" "$allowed_root" "$sentinel_name" || return 1
  rm -rf -- "$directory"
}

safe_reset_owned_directory() {
  local directory="$1"
  local allowed_root="$2"
  local sentinel_name="$3"

  safe_assert_strict_descendant "$directory" "$allowed_root" || return 1
  if [[ -e "$directory" || -L "$directory" ]]; then
    safe_remove_owned_directory "$directory" "$allowed_root" "$sentinel_name" || return 1
  fi
  safe_prepare_owned_directory "$directory" "$allowed_root" "$sentinel_name" || return 1
}

safe_remove_managed_child() {
  local candidate="$1"
  local expected_parent="$2"
  local allowed_basename_pattern="$3"
  local parent_path
  local expected_parent_path
  local basename

  if [[ -L "$expected_parent" ]]; then
    echo "Refusing symlinked expected parent: $expected_parent" >&2
    return 1
  fi

  parent_path="$(safe_canonical_path "$(dirname "$candidate")")"
  expected_parent_path="$(safe_canonical_path "$expected_parent")"
  basename="$(basename "$candidate")"

  if [[ "$parent_path" != "$expected_parent_path" ]]; then
    echo "Refusing to remove path outside expected parent '$expected_parent_path': $candidate" >&2
    return 1
  fi

  case "$basename" in
    $allowed_basename_pattern)
      ;;
    *)
      echo "Refusing to remove unexpected managed child '$basename'." >&2
      return 1
      ;;
  esac

  if [[ -L "$candidate" ]]; then
    echo "Refusing to recursively remove symlinked managed child: $candidate" >&2
    return 1
  fi

  if [[ -e "$candidate" ]]; then
    rm -rf -- "$candidate"
  fi
}
