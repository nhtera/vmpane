#!/usr/bin/env ruby
# Workflow policy (the self-hosted Mac must never run code from pull requests):
# - triggers that run with secrets or base-repo context for untrusted code are banned:
#   pull_request_target, issue_comment, workflow_run;
# - a job whose runs-on is not a known GitHub-hosted label is treated as self-hosted, and must have an
#   `if:` allowlisting events: contains(fromJSON('["push", ...]'), github.event_name) with only
#   push, workflow_dispatch and schedule;
# - every third-party Action and reusable workflow is pinned by a 40-character commit SHA.
# Usage: scripts/check-workflows.rb [files…] (default: .github/workflows/*.{yml,yaml})
require "json"
require "yaml"

HOSTED = /\A(ubuntu|macos|windows)-[\w.-]+\z/
BANNED_TRIGGERS = %w[pull_request_target issue_comment workflow_run].freeze
SAFE_EVENTS = %w[push workflow_dispatch schedule].freeze
GUARD = /contains\(fromJSON\('(\[[^\]]*\])'\),\s*github\.event_name\)/

def hosted?(runs_on)
  return false unless runs_on.is_a?(String) || runs_on.is_a?(Array)
  labels = Array(runs_on)
  return false unless labels.all?(String)
  labels.all? do |label|
    if label.include?("${{")
      # An expression may only choose between quoted hosted labels.
      quoted = label.scan(/'([^']*)'/).flatten
      !quoted.empty? && quoted.all? { |q| q.match?(HOSTED) } && label.scan(/\b(?:self-hosted|vmpane)\b/).empty?
    else
      label.match?(HOSTED)
    end
  end
end

def pinned?(uses)
  uses.start_with?("./") || uses.match?(/@[0-9a-f]{40}\z/)
end

files = ARGV.empty? ? Dir.glob(".github/workflows/*.{yml,yaml}").sort : ARGV
errors = []
files.each do |path|
  doc = YAML.safe_load(File.read(path), aliases: true) || {}
  # YAML 1.1 reads the bare key `on` as true.
  triggers = doc.key?("on") ? doc["on"] : doc[true]
  names = case triggers
          when Hash then triggers.keys.map(&:to_s)
          when Array then triggers.map(&:to_s)
          else [triggers.to_s]
          end
  (names & BANNED_TRIGGERS).each { |t| errors << "#{path}: trigger #{t} is not allowed" }

  (doc["jobs"] || {}).each do |name, job|
    unless hosted?(job["runs-on"]) || job["uses"]
      guard = job["if"].to_s[GUARD, 1]
      events = guard && (JSON.parse(guard) rescue nil)
      # `||` could OR the guard away; only `&&` may narrow it further.
      if events.nil? || events.empty? || !(events - SAFE_EVENTS).empty? || job["if"].to_s.include?("||")
        errors << "#{path}: job #{name} is not on a hosted runner and lacks the event allowlist guard " \
                  "contains(fromJSON('[\"push\", \"workflow_dispatch\"]'), github.event_name)"
      end
    end
    errors << "#{path}: job #{name} uses #{job['uses']} (pin by commit SHA)" if job["uses"] && !pinned?(job["uses"])
    (job["steps"] || []).each do |step|
      uses = step["uses"] or next
      errors << "#{path}: job #{name} uses #{uses} (pin by commit SHA)" unless pinned?(uses)
    end
  end
end
warn errors.join("\n") unless errors.empty?
exit(errors.empty? ? 0 : 1)
