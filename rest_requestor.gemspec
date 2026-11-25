# frozen_string_literal: true

require_relative "lib/rest_requestor/version"

Gem::Specification.new do |spec|
  spec.name = "rest_requestor"
  spec.version = RestRequestor::VERSION
  spec.authors = ["Scott Wright"]
  spec.email = ["scott@wrightzone.com"]

  spec.summary = "HTTP client with retry support, proxy awareness, and structured errors"
  spec.description = "Wraps Net::HTTP with JSON handling, exponential backoff on 503 errors, optional proxy support, and typed error classes."
  spec.homepage = "https://codeberg.org/jswright61/rest_requestor"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2"

  spec.files = Dir["lib/**/*"] + ["LICENSE"]
  spec.require_paths = ["lib"]
end
