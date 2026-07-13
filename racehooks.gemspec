require_relative "lib/racehooks/version"

Gem::Specification.new do |spec|
  spec.name          = "racehooks"
  spec.version       = Racehooks::VERSION
  spec.authors       = ["RaceHooks"]
  spec.email         = ["contact@racehooks.io"]

  spec.summary       = "Official Ruby client for RaceHooks — the motorsports analytics platform"
  spec.description   = "Webhook signature verification, construct_event, and a REST client " \
                       "for RaceHooks, the motorsports analytics platform. Parse 50+ live F1 " \
                       "feeds — timing, race events, and derived analytics feeds backed by " \
                       "twelve production ML models — delivered to your webhook endpoint."
  spec.homepage      = "https://racehooks.io"
  spec.license       = "MIT"

  spec.required_ruby_version = ">= 2.6"

  spec.metadata = {
    "homepage_uri"    => spec.homepage,
    "source_code_uri" => "https://github.com/racehooks/racehooks-ruby",
    "changelog_uri"   => "https://github.com/racehooks/racehooks-ruby/blob/main/CHANGELOG.md",
    "bug_tracker_uri" => "https://github.com/racehooks/racehooks-ruby/issues",
  }

  spec.files = Dir["lib/**/*", "LICENSE", "*.md"]
  spec.require_paths = ["lib"]

  # No runtime dependencies — uses only Ruby stdlib (net/http, json, openssl)
end
