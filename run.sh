#!/usr/bin/env bash
set -euo pipefail

export LANG=en_US.UTF-8
export PATH="$HOME/.local/bin:/opt/homebrew/bin:$PATH"
eval "$(/opt/homebrew/bin/mise activate bash 2>/dev/null)" || true

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

export CLAUDE_CODE_OAUTH_TOKEN="$(fnox get CLAUDE_SETUP_TOKEN)"
export RESEND_API_KEY="$(fnox get RESEND_API_KEY)"
export X_NEWSLETTER_RECIPIENTS="$(fnox get X_NEWSLETTER_RECIPIENTS)"
export X_NEWSLETTER_FROM="$(fnox get X_NEWSLETTER_FROM)"
export X_NEWSLETTER_SUBJECT_PREFIX="$(fnox get X_NEWSLETTER_SUBJECT_PREFIX)"

exec "$SCRIPT_DIR/send-newsletter.rb"
