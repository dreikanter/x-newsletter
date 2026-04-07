#!/usr/bin/env bash
# Simulates cron execution: minimal env, non-interactive shell
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
rm -f /tmp/x-newsletter.lock
env -i HOME="$HOME" USER="$USER" LANG=en_US.UTF-8 /bin/bash --norc --noprofile "$SCRIPT_DIR/run.sh"
