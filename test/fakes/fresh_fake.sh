#!/usr/bin/env bash
set -u

log_file="${FC_FRESH_FAKE_LOG:-/tmp/fc_fresh_fake.log}"

{
  printf 'cwd=%s args=' "$PWD"
  for a in "$@"; do
    printf '[%s]' "$a"
  done
  printf '\n'
} >> "$log_file"

if [[ "${1-}" == "--cmd" && "${2-}" == "session" && "${3-}" == "open-file" ]]; then
  exit "${FC_FRESH_FAKE_OPEN_RC:-0}"
fi

exit 0
