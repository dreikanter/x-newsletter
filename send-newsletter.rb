#!/usr/bin/env ruby
# frozen_string_literal: true

# X/Twitter AI & Dev Newsletter
# Fetches trending posts via Claude Code, renders HTML, sends via Resend CLI,
# and pushes the top post to a Feeder (F2) webhook feed.
# Designed for non-interactive execution (cron)

require "date"
require "json"
require "time"
require "open3"
require "tempfile"
require "net/http"
require "uri"

puts Time.now.strftime("[%Y-%m-%d %H:%M:%S]")

LOCK_FILE = "/tmp/x-newsletter.lock"
RUN_LOCK_FILE = "/tmp/x-newsletter.run.lock"
# Published post UIDs, kept next to the script so they survive reboots and /tmp
# cleanups. Feeder dedups on its own; this list exists to keep the model from
# proposing what we already sent.
HISTORY_FILE = File.join(__dir__, "history.json")
HISTORY_LIMIT = 30
SCHEDULE_TOLERANCE = 60
CLAUDE_TIMEOUT = 1800

# Prevent concurrent runs: held for the lifetime of this process, auto-released on exit.
run_lock = File.open(RUN_LOCK_FILE, File::RDWR | File::CREAT, 0o644)
unless run_lock.flock(File::LOCK_EX | File::LOCK_NB)
  puts "Another instance is running, skipping."
  exit 0
end

def should_run?
  return true unless File.exist?(LOCK_FILE)
  last_run = Time.parse(JSON.parse(File.read(LOCK_FILE))["last_run"])
  Time.now - last_run >= 86400 - SCHEDULE_TOLERANCE
end

unless should_run?
  puts "Less than 24h since last run, skipping. Delete #{LOCK_FILE} to force."
  exit 0
end

def run(*cmd)
  out, err, status = Open3.capture3(*cmd)
  raise "Command failed: #{cmd.join(" ")}\n#{err}" unless status.success?
  out
end

def env!(key)
  ENV.fetch(key) { abort "Missing required env var: #{key}" }
end

def load_history
  return [] unless File.exist?(HISTORY_FILE)
  Array(JSON.parse(File.read(HISTORY_FILE))["uids"])
rescue JSON::ParserError => e
  warn "Ignoring unreadable #{HISTORY_FILE}: #{e.message}"
  []
end

def save_history(uids)
  File.write(HISTORY_FILE, JSON.pretty_generate(uids: uids.last(HISTORY_LIMIT)))
end

# A post's identity is its permalink, so the same post reached through a
# tracking link or the legacy domain must collapse to one UID.
def canonical_link(url)
  uri = URI.parse(url.strip)
  return url unless uri.host

  host = uri.host.downcase.delete_prefix("www.").delete_prefix("mobile.")
  uri.scheme = "https"
  uri.host = host == "twitter.com" ? "x.com" : host
  uri.query = nil
  uri.fragment = nil
  uri.to_s.chomp("/")
rescue URI::InvalidURIError
  url
end

# Config from env vars
puts "Loading config..."
env!("RESEND_API_KEY")
recipients = env!("X_NEWSLETTER_RECIPIENTS").split(",").map(&:strip)
from = env!("X_NEWSLETTER_FROM")
subject_prefix = env!("X_NEWSLETTER_SUBJECT_PREFIX")
webhook_url = env!("X_NEWSLETTER_WEBHOOK_URL")
webhook_token = env!("X_NEWSLETTER_WEBHOOK_TOKEN")
subject = "#{subject_prefix} — #{Date.today.strftime("%Y-%m-%d")}"
puts "Subject: #{subject}"
puts "Recipients: #{recipients.length}"

generated_date = Date.today.strftime("%B %d, %Y")

history = load_history
puts "History: #{history.length} known post#{"s" unless history.length == 1}"

recent_section =
  if history.empty?
    ""
  else
    <<~SECTION
      # Already covered
      These posts already went out. Do NOT return any of them, and skip anything that covers the same announcement:
      #{history.reverse.map { |uid| "- #{uid}" }.join("\n")}

    SECTION
  end

# Fetch content via Claude Code
puts "Fetching content via Claude..."
prompt = <<~PROMPT
  Today's date is #{generated_date}.

  # What to find
  Search the web for popular posts from x.com from the last 24 hours about AI, programming, or developer tooling. Use web search to find them — search for terms like "site:x.com AI" or "popular tweets AI programming today" or check tech aggregator sites that surface trending tweets. Try multiple searches if needed.

  # Content criteria
  - Posts must contain genuine technical insight, novel information, or substantive analysis.
  - Exclude hype, engagement bait, and posts that are popular but non-informative.
  - If the original post is short (under 280 characters), quote it verbatim. If longer, provide a 1-2 sentence summary.
  - Return exactly 3 best posts you can find. Use approximate like counts if exact numbers are unavailable.
  - Order them best first: the first post is published on its own, so it must be the strongest one.
  - Every link must be a direct permalink to the post itself (https://x.com/<handle>/status/<id>), not a profile, search, or aggregator page.

  #{recent_section}# Rules
  - Do NOT ask questions, suggest alternatives, or request API keys.
  - Do NOT explain difficulties with searching x.com. Just do your best with available tools.
  - You MUST return exactly 3 posts. No exceptions. No commentary.

  # Output format
  Use this exact format, one post per block, separated by ---

  @handle ~NUMBERK likes
  Post text or summary here.
  https://x.com/...

  ---

  @handle2 ...

  Return ONLY the posts in this format. No markdown, no code fences, no commentary.
PROMPT

claude_start = Time.now
raw, err, status = Open3.capture3(
  "gtimeout", "--kill-after=5s", CLAUDE_TIMEOUT.to_s,
  "claude", "--print", "--model", "sonnet", "--allowedTools", "WebSearch,WebFetch,XNewsletterCronMarker", "-p", prompt
)
claude_elapsed = (Time.now - claude_start).round(1)
if [124, 137].include?(status.exitstatus)
  abort "Claude timed out after #{claude_elapsed}s, killed."
end
unless status.success?
  abort "Claude failed (exit #{status.exitstatus}) after #{claude_elapsed}s:\n#{raw}\n#{err}"
end
puts "Claude response received (#{raw.length} bytes, #{claude_elapsed}s)"

# Parse posts from Claude output
blocks = raw.strip.split(/^---\s*$/).map(&:strip).reject(&:empty?)
posts = blocks.each_with_index.filter_map do |block, idx|
  lines = block.lines.map(&:strip).reject(&:empty?)
  # Anchor on the "@handle ..." header rather than the first line: the model
  # occasionally opens the first block with a sentence of preamble, and that
  # block is the one published to the webhook, so a chatty opener should cost
  # a warning instead of the top post.
  header_idx = lines.index { |line| line.start_with?("@") }
  if header_idx.nil? || lines.size - header_idx < 3
    warn "Block #{idx + 1}/#{blocks.size} skipped: no @handle header followed by summary and link (#{lines.size} lines)"
    next
  end
  warn "Block #{idx + 1}/#{blocks.size}: dropped #{header_idx} preamble line(s)" if header_idx.positive?

  header = lines[header_idx]
  handle = header[/@\w+/]
  likes = header[/~[\d.]+K?\s*likes/i]
  summary = lines[(header_idx + 1)...-1].join(" ")
  link = lines.last

  unless handle && link.start_with?("http")
    warn "Block #{idx + 1}/#{blocks.size} skipped: missing handle or link (handle=#{handle.inspect}, last_line=#{link.inspect})"
    next
  end

  { handle: handle, likes: likes, summary: summary, link: canonical_link(link) }
end

if posts.empty?
  abort "No posts parsed from Claude output:\n#{raw}"
end
puts "Parsed #{posts.length} posts: #{posts.map { |p| p[:handle] }.join(", ")}"

# Render HTML
def escape(text)
  text.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;").gsub('"', "&quot;")
end

post_html = posts.map do |post|
  <<~HTML
    <p style="margin: 0 0 12px; font-family: Helvetica, Arial, sans-serif; font-size: 15px; line-height: 1.6; color: #333;">
      <a href="#{escape(post[:link])}" style="color: #333; text-decoration: underline;"><strong>#{escape(post[:handle])}</strong></a>
      <span style="color: #999;">#{escape(post[:likes] || "")}</span><br>
      #{escape(post[:summary])}
    </p>
  HTML
end.join(%(<div style="border-top: 1px solid #eee; margin: 20px 0;"></div>\n))

html = <<~HTML
  <!DOCTYPE html>
  <html lang="en">
  <head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  </head>
  <body style="margin: 0; padding: 0; background: #ffffff;">
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0">
  <tr><td style="padding: 10px 0 32px;">
  <table role="presentation" width="520" cellpadding="0" cellspacing="0" border="0" style="max-width: 520px; width: 100%;">
  <tr><td style="font-family: Helvetica, Arial, sans-serif; font-size: 15px; line-height: 1.6; color: #333;">
  #{post_html}
  <div style="border-top: 1px solid #eee; margin: 20px 0;"></div>
  <p style="margin: 0; font-family: Helvetica, Arial, sans-serif; color: #bbb; font-size: 12px;">#{escape(generated_date)}</p>
  </td></tr>
  </table>
  </td></tr>
  </table>
  </body>
  </html>
HTML

# Push the top unseen post to the Feeder webhook. One post per run: the endpoint
# takes a single post per request and this is a daily digest, not a firehose.
# Feeder folds source_url into the post body, so content carries only the text.
def deliver_to_webhook(url, token, post)
  uri = URI.parse(url)
  request = Net::HTTP::Post.new(uri)
  request["Authorization"] = "Bearer #{token}"
  request["Content-Type"] = "application/json"
  request.body = JSON.generate(
    content: [[post[:handle], post[:likes]].compact.join(" "), post[:summary]].join("\n"),
    source_url: post[:link],
    uid: post[:link]
  )

  response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https", open_timeout: 10, read_timeout: 30) do |http|
    http.request(request)
  end

  [response.code.to_i, response.body.to_s]
end

# Send to each recipient
tmpfile = Tempfile.new(["newsletter", ".html"])
webhook_error = nil
begin
  tmpfile.write(html)
  tmpfile.close

  File.write(LOCK_FILE, JSON.generate(last_run: Time.now.iso8601))
  puts "Lock written to #{LOCK_FILE}"

  featured = posts.find { |post| !history.include?(post[:link]) }
  if featured.nil?
    puts "Webhook: every post is already in history, nothing to push."
  else
    puts "Webhook: pushing #{featured[:handle]} (#{featured[:link]})..."
    begin
      code, body = deliver_to_webhook(webhook_url, webhook_token, featured)
      case code
      when 201
        warnings = Array(JSON.parse(body)["warnings"]) rescue []
        puts "Webhook: enqueued#{" (#{warnings.join(", ")})" if warnings.any?}"
        save_history(history + [featured[:link]])
      when 200
        puts "Webhook: duplicate, already ingested"
        save_history(history + [featured[:link]])
      else
        webhook_error = "HTTP #{code}: #{body.strip}"
      end
    rescue StandardError => e
      webhook_error = "#{e.class}: #{e.message}"
    end
    # Reported immediately so the reason survives even if the email step then
    # raises; the run still finishes and exits non-zero at the end.
    warn "Webhook delivery failed: #{webhook_error}" if webhook_error
  end

  recipients.each_with_index do |to, i|
    puts "Sending #{i + 1}/#{recipients.length}..."
    run("resend", "emails", "send",
        "--from", from,
        "--to", to,
        "--subject", subject,
        "--html-file", tmpfile.path)
  end
  puts webhook_error ? "Emails sent; webhook delivery failed." : "Done!"
ensure
  tmpfile.unlink
end

exit 1 if webhook_error
