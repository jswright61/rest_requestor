# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../lib/rest_requestor"

class TestRestRequestor < Minitest::Test
  def setup
    @rr = RestRequestor.new(user_agent: "TestSuite/1.0")
  end

  def test_version_defined
    refute_nil RestRequestor::VERSION
  end

  def test_default_options
    assert_equal 7, @rr.options[:max_retries]
    assert_equal 10, @rr.options[:open_timeout]
    assert_equal 30, @rr.options[:read_timeout]
    assert_equal "https://example.com", @rr.options[:proxy_probe_uri]
    assert_equal true, @rr.options[:skip_proxy]
    assert_nil RestRequestor::OPTION_DEFAULTS[:user_agent]
  end

  def test_custom_options_override_defaults
    rr = RestRequestor.new(user_agent: "Test/1.0", max_retries: 3, skip_proxy: false)
    assert_equal 3, rr.options[:max_retries]
    assert_equal false, rr.options[:skip_proxy]
  end

  def test_warns_to_stderr_when_no_user_agent
    _, err = capture_io { RestRequestor.new }
    assert_match(/No user_agent set/, err)
  end

  def test_no_warning_when_user_agent_provided
    _, err = capture_io { RestRequestor.new(user_agent: "MyApp/1.0") }
    assert_empty err
  end

  def test_warns_to_logger_when_no_user_agent
    messages = []
    logger = Object.new
    logger.define_singleton_method(:warn) { |msg| messages << msg }
    capture_io { RestRequestor.new(logger: logger) }
    assert_equal 1, messages.size
    assert_match(/No user_agent set/, messages.first)
  end

  def test_invalid_verb_raises_argument_error
    assert_raises(ArgumentError) { @rr.request("https://example.com", :invalid) }
  end

  def test_head_verb_is_valid
    # :head is accepted — no ArgumentError raised before the network call
    assert_raises(Exception) { @rr.request("https://0.0.0.0", :head) }
    begin
      @rr.request("https://0.0.0.0", :head)
    rescue ArgumentError
      flunk ":head raised ArgumentError — should be a valid verb"
    rescue Exception
      # any other error (network, timeout) is fine
    end
  end

  def test_retry_delay_is_private
    assert_raises(NoMethodError) { @rr.retry_delay(1) }
  end

  def test_retry_delay_increases_with_retries
    d1 = @rr.send(:retry_delay, 1)
    d3 = @rr.send(:retry_delay, 3)
    assert d3 > d1
  end

  def test_standard_error_inherits_ruby_standard_error
    assert RestRequestor::StandardError.ancestors.include?(::StandardError)
  end

  def test_rate_limit_error_inherits_standard_error
    assert RestRequestor::RateLimitError.ancestors.include?(RestRequestor::StandardError)
  end

  def test_not_found_error_inherits_standard_error
    assert RestRequestor::NotFoundError.ancestors.include?(RestRequestor::StandardError)
  end

  def test_service_unavailable_error_inherits_standard_error
    assert RestRequestor::ServiceUnavailableError.ancestors.include?(RestRequestor::StandardError)
  end

  def test_too_many_redirects_error_inherits_ruby_standard_error
    assert RestRequestor::TooManyRedirectsError.ancestors.include?(::StandardError)
    refute RestRequestor::TooManyRedirectsError.ancestors.include?(RestRequestor::StandardError)
  end
end

class TestRestRequestorConfig < Minitest::Test
  def test_parse_sets_user_agent_with_version
    result = RestRequestor::Config.parse("user_agent" => "MyApp")
    assert_equal "MyApp/#{RestRequestor::VERSION}", result[:user_agent]
  end

  def test_parse_sanitizes_special_chars_in_user_agent
    result = RestRequestor::Config.parse("user_agent" => "My App (v2)")
    assert_equal "My_App__v2_/#{RestRequestor::VERSION}", result[:user_agent]
  end

  def test_parse_accepts_symbol_key
    result = RestRequestor::Config.parse(user_agent: "MyApp")
    assert_equal "MyApp/#{RestRequestor::VERSION}", result[:user_agent]
  end

  def test_parse_sets_max_retries
    result = RestRequestor::Config.parse("max_retries" => 3)
    assert_equal 3, result[:max_retries]
  end

  def test_parse_sets_open_timeout
    result = RestRequestor::Config.parse("open_timeout" => 5)
    assert_equal 5.0, result[:open_timeout]
  end

  def test_parse_sets_read_timeout
    result = RestRequestor::Config.parse("read_timeout" => 60)
    assert_equal 60.0, result[:read_timeout]
  end

  def test_parse_sets_proxy_probe_uri
    result = RestRequestor::Config.parse("proxy_probe_uri" => "https://myproxy.internal/probe")
    assert_equal "https://myproxy.internal/probe", result[:proxy_probe_uri]
  end

  def test_parse_ignores_blank_proxy_probe_uri
    assert_equal({}, RestRequestor::Config.parse("proxy_probe_uri" => "  "))
  end

  def test_parse_ignores_zero_or_negative_numeric_values
    result = RestRequestor::Config.parse("max_retries" => 0, "open_timeout" => -1, "read_timeout" => 0)
    refute result.key?(:max_retries)
    refute result.key?(:open_timeout)
    refute result.key?(:read_timeout)
  end

  def test_parse_accepts_fractional_timeouts
    result = RestRequestor::Config.parse("open_timeout" => 2.5)
    assert_equal 2.5, result[:open_timeout]
  end

  def test_parse_returns_empty_hash_when_no_user_agent
    assert_equal({}, RestRequestor::Config.parse({}))
    assert_equal({}, RestRequestor::Config.parse("other_key" => "value"))
  end

  def test_parse_preserves_allowed_chars
    result = RestRequestor::Config.parse("user_agent" => "My-App_2")
    assert_equal "My-App_2/#{RestRequestor::VERSION}", result[:user_agent]
  end

  def test_load_reads_from_project_config_dir
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "config"))
      File.write(File.join(dir, "config", "rest_requestor_config.yml"), "user_agent: ProjectClient\n")
      result = Dir.chdir(dir) { RestRequestor::Config.load }
      assert_equal "ProjectClient/#{RestRequestor::VERSION}", result[:user_agent]
    end
  end

  def test_load_reads_from_env_var_path
    Dir.mktmpdir do |dir|
      config_path = File.join(dir, "custom_config.yml")
      File.write(config_path, "user_agent: EnvClient\n")
      Dir.mktmpdir do |project_dir|
        orig = ENV["REST_REQUESTOR_CONFIG"]
        ENV["REST_REQUESTOR_CONFIG"] = config_path
        result = Dir.chdir(project_dir) { RestRequestor::Config.load }
        assert_equal "EnvClient/#{RestRequestor::VERSION}", result[:user_agent]
      ensure
        orig ? ENV["REST_REQUESTOR_CONFIG"] = orig : ENV.delete("REST_REQUESTOR_CONFIG")
      end
    end
  end

  def test_project_tier_overrides_env_tier
    Dir.mktmpdir do |dir|
      env_config = File.join(dir, "env_config.yml")
      File.write(env_config, "user_agent: EnvClient\n")

      FileUtils.mkdir_p(File.join(dir, "project", "config"))
      File.write(File.join(dir, "project", "config", "rest_requestor_config.yml"), "user_agent: ProjectClient\n")

      orig = ENV["REST_REQUESTOR_CONFIG"]
      ENV["REST_REQUESTOR_CONFIG"] = env_config
      result = Dir.chdir(File.join(dir, "project")) { RestRequestor::Config.load }
      assert_equal "ProjectClient/#{RestRequestor::VERSION}", result[:user_agent]
    ensure
      orig ? ENV["REST_REQUESTOR_CONFIG"] = orig : ENV.delete("REST_REQUESTOR_CONFIG")
    end
  end

  def test_cascade_merges_settings_across_tiers
    Dir.mktmpdir do |dir|
      # Env tier: sets user_agent and max_retries
      env_config = File.join(dir, "env_config.yml")
      File.write(env_config, "user_agent: BaseApp\nmax_retries: 5\n")

      # Project tier: overrides max_retries only; user_agent inherited from env tier
      FileUtils.mkdir_p(File.join(dir, "project", "config"))
      File.write(File.join(dir, "project", "config", "rest_requestor_config.yml"), "max_retries: 2\n")

      orig = ENV["REST_REQUESTOR_CONFIG"]
      ENV["REST_REQUESTOR_CONFIG"] = env_config
      result = Dir.chdir(File.join(dir, "project")) { RestRequestor::Config.load }
      assert_equal "BaseApp/#{RestRequestor::VERSION}", result[:user_agent]
      assert_equal 2, result[:max_retries]
    ensure
      orig ? ENV["REST_REQUESTOR_CONFIG"] = orig : ENV.delete("REST_REQUESTOR_CONFIG")
    end
  end

  def test_load_returns_empty_hash_when_no_config_found
    Dir.mktmpdir do |dir|
      orig_xdg = ENV.delete("XDG_CONFIG_HOME")
      orig_env = ENV.delete("REST_REQUESTOR_CONFIG")
      result = Dir.chdir(dir) { RestRequestor::Config.load }
      assert_equal({}, result)
    ensure
      ENV["XDG_CONFIG_HOME"] = orig_xdg if orig_xdg
      ENV["REST_REQUESTOR_CONFIG"] = orig_env if orig_env
    end
  end

  def test_load_skips_malformed_yaml
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "config"))
      File.write(File.join(dir, "config", "rest_requestor_config.yml"), ":: bad: yaml: {{\n")
      result = Dir.chdir(dir) { RestRequestor::Config.load }
      assert_equal({}, result)
    end
  end

  def test_kw_args_override_file_config
    rr = RestRequestor.new(user_agent: "Explicit/1.0")
    assert_equal "Explicit/1.0", rr.options[:user_agent]
  end
end
