# X Newsletter

Daily email digest of top AI, programming, and developer tooling posts from X/Twitter.

## Prerequisites

- Ruby (macOS default version is OK)
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code)
- [Resend CLI](https://resend.com/docs/cli)
- [fnox](https://github.com/jdx/fnox)

## Setup

```sh
fnox set RESEND_API_KEY 'your-resend-api-key'
fnox set X_NEWSLETTER_RECIPIENTS 'alice@example.com,bob@example.com'
fnox set X_NEWSLETTER_FROM 'Newsletter <newsletter@example.com>'
fnox set X_NEWSLETTER_SUBJECT_PREFIX 'X Newsletter: Top AI & Dev Posts'
```

## Usage

```sh
./run.sh
```

`run.sh` reads secrets from fnox and passes them as env vars to `send-newsletter.rb`. The Ruby script can also run standalone with env vars set directly.

## Scheduling

Safe to run from cron at any frequency:

```
*/10 * * * * /path/to/x-newsletter/run.sh > /tmp/x-newsletter.log 2>&1
```

## Lock mechanism

Two locks:

- `/tmp/x-newsletter.run.lock` — `flock`-based, prevents concurrent runs. Auto-released when the process exits.
- `/tmp/x-newsletter.lock` — JSON file written after Claude returns, before sending. Subsequent runs within 24h exit early. Delete this file to force a re-run.

The Claude subprocess is also bounded by a 30-minute timeout to keep a single hung run from stacking up cron instances.

## Testing

`test.sh` removes the lock file and runs `run.sh`, simulating a fresh cron execution.
