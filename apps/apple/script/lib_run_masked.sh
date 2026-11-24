#!/usr/bin/env bash
# Sourced by release_testflight.sh: run one release step with its output masked and
# logged, retrying within the configured limit after a transient network error.
#
#   MASK                          a `sed -E` program that masks passwords and email
#                                 addresses; the caller sets it before calling.
#   LORVEX_RELEASE_MAX_ATTEMPTS    positive integer attempt limit (default: 2);
#                                 controlled releases use 1 to prevent an automatic
#                                 repeat of an archive/export or ambiguous upload.
#
#   run_masked <log-file> <cmd>   appends the masked output to <log-file> and returns
#                                 the command's status. A failure whose output names a
#                                 transient network error (a lost connection, NSURLError
#                                 -1005 or -1001, a 502, 503, or 504) runs the command one
#                                 more time by default. The configured limit includes
#                                 the initial attempt. At that limit, or for any
#                                 nontransient failure, the command's status stands.

LORVEX_TRANSIENT_NETWORK='network connection was lost|NSURLError[A-Za-z]*[^0-9-]*-100[15]|HTTP[^0-9]*50[234]|request timed out'

run_masked() {
  local log="$1" attempt output status
  local max_attempts="${LORVEX_RELEASE_MAX_ATTEMPTS-2}"
  shift
  if [[ ! "$max_attempts" =~ ^[1-9][0-9]*$ ]]; then
    echo "LORVEX_RELEASE_MAX_ATTEMPTS must be a positive integer." >&2
    return 2
  fi
  for (( attempt = 1; attempt <= max_attempts; attempt++ )); do
    output="$(mktemp)"
    "$@" 2>&1 | sed -E "$MASK" | tee -a "$log" >"$output"
    status="${PIPESTATUS[0]}"
    if (( status == 0 )); then
      rm -f "$output"
      return 0
    fi
    if (( attempt < max_attempts )) && grep -qiE "$LORVEX_TRANSIENT_NETWORK" "$output"; then
      echo "release: transient network failure, retrying step ($((attempt + 1))/$max_attempts)" | tee -a "$log"
      rm -f "$output"
      continue
    fi
    rm -f "$output"
    return "$status"
  done
  return 1
}
