Gem::Specification.new do |spec|
  spec.name          = "racehooks"
  spec.version       = "0.1.0"
  spec.authors       = ["RaceHooks"]
  spec.email         = ["contact@racehooks-ai.com"]

  spec.summary       = "Ruby client for the RaceHooks F1 live timing webhook API"
  spec.description   = "Webhook signature verification, construct_event, and a REST client " \
                       "for the RaceHooks API. Receive live F1 timing feeds — car telemetry, " \
                       "lap times, tyre data, race control messages, and more."
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
