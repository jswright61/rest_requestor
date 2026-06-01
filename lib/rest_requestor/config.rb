# frozen_string_literal: true

require "yaml"

class RestRequestor
  module Config
    # Each tier holds candidate paths; the first found in a tier is used for that tier.
    # Tiers are merged least-to-most-specific, so project settings override env-explicit,
    # which override home/global settings. Settings absent from a more-specific tier are
    # inherited from less-specific ones.
    CONFIG_TIERS = [
      # Tier 1 — home/global (least specific)
      [
        -> { ENV["XDG_CONFIG_HOME"]&.then { |d| File.join(d, "rest_requestor", "config.yml") } },
        -> { File.join(Dir.home, ".config", "rest_requestor", "config.yml") },
        -> { File.join(Dir.home, ".rest_requestor_config.yml") }
      ],
      # Tier 2 — explicit path via environment variable
      [
        -> { (v = ENV["REST_REQUESTOR_CONFIG"]) && !v.empty? ? v : nil }
      ],
      # Tier 3 — project-local (most specific)
      [
        -> { File.join(Dir.pwd, "config", "rest_requestor_config.yml") }
      ]
    ].freeze

    def self.load
      CONFIG_TIERS.each_with_object({}) do |tier, result|
        data = first_in_tier(tier)
        result.merge!(parse(data)) if data
      end
    end

    def self.parse(data)
      result = {}

      if (raw_ua = data["user_agent"] || data[:user_agent])
        sanitized = raw_ua.to_s.gsub(/[^A-Za-z0-9_\-]/, "_")
        result[:user_agent] = "#{sanitized}/#{VERSION}"
      end

      if (v = data["max_retries"] || data[:max_retries])
        n = v.to_i
        result[:max_retries] = n if n > 0
      end

      %i[open_timeout read_timeout].each do |key|
        if (v = data[key.to_s] || data[key])
          n = v.to_f
          result[key] = n if n > 0
        end
      end

      result
    end

    def self.first_in_tier(locations)
      locations.each do |location|
        path = location.call
        next unless path && File.exist?(path)
        begin
          data = YAML.safe_load(File.read(path))
          return data if data.is_a?(Hash)
        rescue ::StandardError
          next
        end
      end
      nil
    end
    private_class_method :first_in_tier
  end
end
