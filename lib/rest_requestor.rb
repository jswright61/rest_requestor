# frozen_string_literal: true

require "net/http"
require "uri"
require "json"
require "openssl"
require_relative "rest_requestor/version"
require_relative "rest_requestor/config"

class RestRequestor
  class StandardError < StandardError
    def initialize(uri, verb, resp, params = {}, msg: nil)
      body = if resp["Content-Type"]&.include?("text/html")
        if (m = resp.body.to_s.match(/<title>(.*)<\/title>/))
          m[1]
        else
          resp.body.to_s[0..20]
        end
      else
        resp.body.to_s
      end
      msg ||= "uri: #{uri}, Verb: #{verb}, Resp: #{resp.code} - #{resp.message}, Body: #{body}, Params: #{params}"
      super(msg)
    end
  end

  class RateLimitError < StandardError; end
  class NotFoundError < StandardError; end
  class ServiceUnavailableError < StandardError; end
  class TooManyRedirectsError < ::StandardError; end

  attr_reader :resp, :elapsed, :options

  OPTION_DEFAULTS = {
    max_retries: 7,
    open_timeout: 10,
    read_timeout: 30,
    proxy_address: "127.0.0.1",
    proxy_port: 9090,
    proxy_probe_uri: "https://example.com",
    user_agent: nil,
    skip_proxy: true,
    logger: nil
  }

  FILE_CONFIG = Config.load.freeze

  # Shared across instances; cert store is immutable after setup
  def self.ssl_cert_store
    @ssl_cert_store ||= begin
      store = OpenSSL::X509::Store.new
      store.set_default_paths
      # Prevent failures when CRL distribution points are unreachable
      store.flags = OpenSSL::X509::V_FLAG_PARTIAL_CHAIN
      store
    end
  end

  def initialize(**kw_args)
    @options = OPTION_DEFAULTS.merge(FILE_CONFIG).merge(kw_args)
    warn_no_user_agent if options[:user_agent].to_s.strip.empty?
  end

  def request(uri, verb, j_params: {}, f_hash: {}, q_params: {}, auth: nil, headers: {}, body: nil, retries: 0)
    unless [:get, :post, :put, :delete, :patch, :head].include?(verb)
      raise ArgumentError, "Verb must be one of :get, :post, :put, :delete, :patch, :head — got #{verb.inspect}"
    end
    uri = add_query_string(uri, q_params) if q_params && !q_params.empty?

    exec_req(uri, verb, j_params, f_hash, auth, headers, body)

    case resp.code.to_i
    when (200...300)
      return resp.code.to_i if verb == :head
      if resp["Content-Type"]&.include?("application/json")
        JSON.parse(resp.body)
      elsif resp.code.to_i == 200 && !resp.body.to_s.strip.empty?
        begin
          JSON.parse(resp.body.to_s)
        rescue JSON::ParserError
          200
        end
      else
        resp.code.to_i
      end
    when 404 then raise NotFoundError.new(uri, verb, resp, j_params)
    when 429
      # Caller must handle rate limits — retry semantics vary per service
      raise RateLimitError.new(uri, verb, resp, j_params)
    when 503
      if retries <= options[:max_retries]
        retries += 1
        waitfor = retry_delay(retries)
        options[:logger]&.info { "Retrying (#{retries}), pausing #{waitfor} seconds" }
        sleep waitfor
        # q_params already incorporated into uri above; omit here to avoid double-encoding
        request(uri, verb, j_params: j_params, f_hash: f_hash, auth: auth, headers: headers, body: body, retries: retries)
      else
        raise ServiceUnavailableError.new(uri, verb, resp, j_params)
      end
    else
      raise StandardError.new(uri, verb, resp, j_params)
    end
  end

  def resolve_redirects(url, limit = 10)
    uri = URI.parse(url)

    limit.times do
      http = build_http(uri)
      req = Net::HTTP::Head.new(uri.request_uri)
      req["User-Agent"] = options[:user_agent] unless options[:user_agent].to_s.strip.empty?
      response = http.request(req)
      return uri.to_s unless response.is_a?(Net::HTTPRedirection)

      uri = URI.join(uri, response["location"])
    end

    raise TooManyRedirectsError, "Too many redirects resolving #{url}"
  end

  private

  def warn_no_user_agent
    msg = "[RestRequestor] No user_agent set — many APIs require one. " \
          "Pass user_agent: \"YourApp/1.0\" to the initializer or set it in a config file."
    options[:logger]&.warn(msg)
    Kernel.warn(msg)
  end

  def retry_delay(retries)
    # Approx seconds: 1~2.5, 2~7.5, 3~17.5, 4~37.5, 5~77.5, 6~157.5, 7~317.3
    2**retries + rand(0..(2**retries / 2.0))
  end

  def add_query_string(uri, q_params)
    separator = uri.include?("?") ? "&" : "?"
    uri + separator + URI.encode_www_form(q_params)
  end

  def build_http(uri_obj)
    http = if proxy_alive?
      Net::HTTP.new(uri_obj.host, uri_obj.port, options[:proxy_address], options[:proxy_port])
    else
      Net::HTTP.new(uri_obj.host, uri_obj.port)
    end

    if uri_obj.scheme == "https"
      http.use_ssl = true
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER
      http.cert_store = self.class.ssl_cert_store
      http.min_version = OpenSSL::SSL::TLS1_2_VERSION
    end

    http.open_timeout = options[:open_timeout]
    http.read_timeout = options[:read_timeout]
    http
  end

  def exec_req(uri, verb, j_params, f_hash, auth, headers, body)
    uri_obj = URI(uri)
    http = build_http(uri_obj)

    request_class = case verb
    when :get    then Net::HTTP::Get
    when :post   then Net::HTTP::Post
    when :put    then Net::HTTP::Put
    when :delete then Net::HTTP::Delete
    when :patch  then Net::HTTP::Patch
    when :head   then Net::HTTP::Head
    end

    request_path = uri_obj.path
    request_path += "?#{uri_obj.query}" if uri_obj.query
    request_path = "/" if request_path.empty?

    req = request_class.new(request_path)
    req["User-Agent"] = options[:user_agent] unless options[:user_agent].to_s.strip.empty?

    headers.each { |key, value| req[key.to_s] = value }

    if !auth.nil?
      if auth.is_a?(String) && !auth.strip.empty?
        req["Authorization"] = auth
      elsif auth.is_a?(Array) && auth.length == 2
        req.basic_auth(*auth)
      elsif auth.is_a?(Hash) && auth.keys.length == 2
        # Assumes two-key {user:, password:} shape; order determines which is which
        req.basic_auth(*auth.values)
      elsif auth.respond_to?(:call)
        auth_header = auth.call
        req["Authorization"] = auth_header if auth_header
      end
    end

    if !j_params.nil? && !j_params.empty?
      req["Content-Type"] = "application/json"
      req.body = j_params.to_json
    elsif !f_hash.nil? && !f_hash.empty?
      req.set_form_data(f_hash)
    elsif !body.nil?
      req.body = body
    end

    r_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    @resp = http.request(req)
    r_end = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    @elapsed = r_end - r_start

    @resp
  end

  def proxy_alive?(refresh: false)
    remove_instance_variable(:@proxy_alive) if refresh
    return @proxy_alive if defined?(@proxy_alive)

    if options[:skip_proxy] || %w[1 true yes].include?(ENV["REST_REQUESTOR_SKIP_PROXY"].to_s.downcase)
      return @proxy_alive = false
    end

    begin
      uri = URI(options[:proxy_probe_uri])
      http = Net::HTTP.new(uri.host, uri.port, options[:proxy_address], options[:proxy_port])
      http.use_ssl = true
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER
      http.cert_store = self.class.ssl_cert_store
      http.min_version = OpenSSL::SSL::TLS1_2_VERSION
      http.open_timeout = 5
      http.read_timeout = 5
      http.request(Net::HTTP::Head.new("/"))
      @proxy_alive = true
    rescue Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNREFUSED, OpenSSL::SSL::SSLError
      @proxy_alive = false
    end
  end
end
