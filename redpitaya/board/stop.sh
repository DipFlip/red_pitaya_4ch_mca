#!/usr/bin/env bash
# Stop only the owner matching this reader's session token.
set -euo pipefail
[[ $# == 1 && "$1" =~ ^[0-9a-f]{32}$ ]] || exit 2
if [[ -r /run/redpitaya-mca-owner.pid ]]; then
  read -r task_pid task_token < /run/redpitaya-mca-owner.pid
  if [[ "$task_token" == "$1" && "$task_pid" =~ ^[0-9]+$ ]]; then
    kill -TERM "$task_pid"
  fi
fi
