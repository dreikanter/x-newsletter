# X Newsletter

Daily digest of top AI, programming, and developer tooling posts from X/Twitter. Each run emails the full digest and pushes the single strongest post to a [Feeder](https://github.com/dreikanter/f2) webhook feed.

## Prerequisites

- Ruby (macOS default version is OK)
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code)
- [Resend CLI](https://resend.com/docs/cli)
- [fnox](https://github.com/jdx/fnox)
- GNU coreutils (`brew install coreutils`) — for `gtimeout`

## Setup

```sh
fnox set RESEND_API_KEY 'your-resend-api-key'
fnox set X_NEWSLETTER_RECIPIENTS 'alice@example.com,bob@example.com'
fnox set X_NEWSLETTER_FROM 'Newsletter <newsletter@example.com>'
fnox set X_NEWSLETTER_SUBJECT_PREFIX 'X Newsletter: Top AI & Dev Posts'
fnox set X_NEWSLETTER_WEBHOOK_URL 'https://fffeeder.com/v1/posts'
fnox set X_NEWSLETTER_WEBHOOK_TOKEN 'your-feeder-webhook-token'
```

`X_NEWSLETTER_WEBHOOK_URL` is the shared Feeder ingress endpoint; the token is what identifies and authenticates the target feed. Both come from the feed page of a `webhook` feed in Feeder — see [Webhook publication](#webhook-publication).

## Usage

```sh
./run.sh
```

`run.sh` reads secrets from fnox and passes them as env vars to `send-newsletter.rb`. The Ruby script can also run standalone with env vars set directly.

## Webhook publication

Every run pushes **one** post — the first block Claude returns, which the prompt asks it to rank strongest-first — to Feeder's ingress endpoint:

```
POST $X_NEWSLETTER_WEBHOOK_URL
Authorization: Bearer $X_NEWSLETTER_WEBHOOK_TOKEN
Content-Type: application/json

{"content": "@handle ~5K likes\nSummary.", "source_url": "https://x.com/...", "uid": "https://x.com/..."}
```

- **One post per request** is the endpoint's contract, and one post per day is the intent — the email keeps carrying all three.
- **`uid` is the post permalink**, so a repeat suggestion is rejected as a duplicate instead of double-posting. Links are canonicalized first (`https`, `twitter.com` → `x.com`, `www.`/`mobile.` and query strings stripped) so the same post reached two ways collapses to one UID.
- **`source_url` is folded into the post body by Feeder**, so `content` carries only the handle, like count, and text.
- `201` (enqueued) and `200` (duplicate) both record the UID in `history.json`; anything else is reported and the run exits non-zero *after* the emails go out, so a webhook outage never costs a newsletter.

### History

`history.json` (next to the script, gitignored) keeps the last 30 published UIDs. They are injected into the prompt as an "Already covered" exclusion list, which is what keeps the model from re-suggesting yesterday's post. Feeder's own dedup is the backstop; this list is what keeps the digest fresh. Delete the file to reset.

## Editing the recipients list

Recipients live in fnox as a comma-separated list. View, then overwrite:

```sh
fnox get X_NEWSLETTER_RECIPIENTS
fnox set X_NEWSLETTER_RECIPIENTS 'alice@example.com,bob@example.com'
```

Whitespace around commas is stripped, so `'a@x.com, b@y.com'` works too.

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

## Cleanup cron

The Claude subprocess is invoked with a sentinel `XNewsletterCronMarker` entry in `--allowedTools`. The model never invokes it (it isn't a real tool), but it's visible in the process's argv, which lets a cleanup cron job kill any stragglers without false-matching unrelated `claude --print` invocations:

```
0 15 * * * pkill -TERM -f XNewsletterCronMarker; sleep 5; pkill -KILL -f XNewsletterCronMarker; true
```

Schedule it after the last regular run window (the example runs at 15:00, 15 minutes after the 14:45 cron tick).

## Testing

`test.sh` removes the lock file and runs `run.sh`, simulating a fresh cron execution. It does not touch `history.json`, so a test run pushes a genuinely new post rather than replaying the last one.
