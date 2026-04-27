#!/usr/bin/env ruby
# frozen_string_literal: true

# X/Twitter AI & Dev Newsletter
# Fetches trending posts via Claude Code, renders HTML, sends via Resend CLI
# Designed for non-interactive execution (cron)

require "date"
require "json"
require "time"
require "open3"
require "tempfile"

puts Time.now.strftime("[%Y-%m-%d %H:%M:%S]")

LOCK_FILE = "/tmp/x-newsletter.lock"
RUN_LOCK_FILE = "/tmp/x-newsletter.run.lock"
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

# Config from env vars
puts "Loading config..."
env!("RESEND_API_KEY")
recipients = env!("X_NEWSLETTER_RECIPIENTS").split(",").map(&:strip)
from = env!("X_NEWSLETTER_FROM")
subject_prefix = env!("X_NEWSLETTER_SUBJECT_PREFIX")
subject = "#{subject_prefix} — #{Date.today.strftime("%Y-%m-%d")}"
puts "Subject: #{subject}"
puts "Recipients: #{recipients.length}"

generated_date = Date.today.strftime("%B %d, %Y")

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

  # Rules
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
claude_cmd = ["claude", "--print", "--model", "sonnet", "--allowedTools", "WebSearch,WebFetch", "-p", prompt]
raw, err, status = nil
Open3.popen3(*claude_cmd) do |stdin, stdout, stderr, wait_thr|
  stdin.close
  out_buf = +""
  err_buf = +""
  out_thread = Thread.new { out_buf << stdout.read }
  err_thread = Thread.new { err_buf << stderr.read }
  unless wait_thr.join(CLAUDE_TIMEOUT)
    Process.kill("TERM", wait_thr.pid) rescue nil
    sleep 5
    Process.kill("KILL", wait_thr.pid) rescue nil
    wait_thr.value
    out_thread.join
    err_thread.join
    abort "Claude timed out after #{CLAUDE_TIMEOUT}s, killed."
  end
  out_thread.join
  err_thread.join
  raw = out_buf
  err = err_buf
  status = wait_thr.value
end
claude_elapsed = (Time.now - claude_start).round(1)
unless status.success?
  abort "Claude failed (exit #{status.exitstatus}) after #{claude_elapsed}s:\n#{raw}\n#{err}"
end
puts "Claude response received (#{raw.length} bytes, #{claude_elapsed}s)"

# Parse posts from Claude output
blocks = raw.strip.split(/^---\s*$/).map(&:strip).reject(&:empty?)
posts = blocks.each_with_index.filter_map do |block, idx|
  lines = block.lines.map(&:strip).reject(&:empty?)
  if lines.size < 3
    warn "Block #{idx + 1}/#{blocks.size} skipped: only #{lines.size} lines"
    next
  end

  header = lines[0]
  handle = header[/@\w+/]
  likes = header[/~[\d.]+K?\s*likes/i]
  summary = lines[1...-1].join(" ")
  link = lines.last

  unless handle && link&.start_with?("http")
    warn "Block #{idx + 1}/#{blocks.size} skipped: missing handle or link (handle=#{handle.inspect}, last_line=#{lines.last.inspect})"
    next
  end

  { handle: handle, likes: likes, summary: summary, link: link }
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

# Send to each recipient
tmpfile = Tempfile.new(["newsletter", ".html"])
begin
  tmpfile.write(html)
  tmpfile.close

  File.write(LOCK_FILE, JSON.generate(last_run: Time.now.iso8601))
  puts "Lock written to #{LOCK_FILE}"

  recipients.each_with_index do |to, i|
    puts "Sending #{i + 1}/#{recipients.length}..."
    run("resend", "emails", "send",
        "--from", from,
        "--to", to,
        "--subject", subject,
        "--html-file", tmpfile.path)
  end
  puts "Done!"
ensure
  tmpfile.unlink
end
