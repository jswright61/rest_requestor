# RestRequestor

**Source:** https://codeberg.org/jswright61/rest_requestor

A minimal Ruby HTTP client built on `Net::HTTP` with no external runtime dependencies. Handles JSON requests and responses, typed error classes, exponential backoff on 503s, optional proxy support, and a tiered config file system.

## Installation

```ruby
# Gemfile
gem "rest_requestor"
```

```
gem install rest_requestor
```

## Quick Start

```ruby
require "rest_requestor"

rr = RestRequestor.new(user_agent: "MyApp/1.0")

# GET — returns parsed JSON or an integer status code
data = rr.request("https://api.example.com/users", :get)

# POST with a JSON body
result = rr.request("https://api.example.com/users", :post,
  j_params: { name: "Alice", role: "admin" })
```

## Making Requests

```ruby
rr.request(uri, verb, **options)
```

**Supported verbs:** `:get`, `:post`, `:put`, `:patch`, `:delete`, `:head`

### Request options

| Option | Type | Description |
|---|---|---|
| `j_params:` | Hash | JSON body — sets `Content-Type: application/json` |
| `f_hash:` | Hash | Form-encoded body — sets `Content-Type: application/x-www-form-urlencoded` |
| `body:` | String | Raw body — use with a `Content-Type` header |
| `q_params:` | Hash | Query string parameters, appended to the URI |
| `headers:` | Hash | Additional request headers |
| `auth:` | see below | Authorization (multiple formats accepted) |

### Authentication

`auth:` accepts several formats:

```ruby
# Bearer / pre-formed header string
rr.request(url, :get, auth: "Bearer eyJ...")

# Basic auth — array
rr.request(url, :get, auth: ["username", "password"])

# Basic auth — hash (two keys, user then password)
rr.request(url, :get, auth: { user: "username", password: "secret" })

# Callable — evaluated per request, useful for rotating tokens
rr.request(url, :get, auth: -> { "Bearer #{TokenStore.current}" })
```

### Return values

| Response | Return value |
|---|---|
| 2xx with `application/json` | Parsed JSON (`Hash` or `Array`) |
| 2xx with any other body | Integer status code |
| `:head` + 2xx | Integer status code |
| 404 | raises `RestRequestor::NotFoundError` |
| 429 | raises `RestRequestor::RateLimitError` |
| 503 | Retries with exponential backoff, then raises `RestRequestor::ServiceUnavailableError` |
| Any other 4xx / 5xx | raises `RestRequestor::StandardError` |

The raw response object and elapsed time are always available after a request:

```ruby
rr.request(url, :get)
rr.resp     # => Net::HTTPResponse
rr.elapsed  # => Float (seconds)
```

## Error Handling

All gem errors inherit from `RestRequestor::StandardError`, which itself inherits from `::StandardError`. The exception message includes the URI, verb, response code, and body.

```ruby
begin
  rr.request("https://api.example.com/widgets/99", :get)
rescue RestRequestor::NotFoundError
  # 404
rescue RestRequestor::RateLimitError
  # 429 — retry logic is left to the caller; semantics vary per API
rescue RestRequestor::ServiceUnavailableError
  # 503 after all retries exhausted
rescue RestRequestor::StandardError => e
  # any other non-2xx response
  puts e.message
end
```

`RestRequestor::TooManyRedirectsError` (a direct subclass of `::StandardError`, not `RestRequestor::StandardError`) is raised by `resolve_redirects` if the redirect chain exceeds the limit.

## Configuration

Settings are resolved in the following order, with later sources overriding earlier ones **per setting** — a project-level config need only specify what it wants to change; everything else is inherited.

### Initializer

Pass any option directly when creating an instance:

```ruby
rr = RestRequestor.new(
  user_agent:    "MyApp/2.0",
  max_retries:   3,
  open_timeout:  5,
  read_timeout:  15,
  logger:        Rails.logger
)
```

Initializer values take **highest** priority and override both defaults and config files.

### Defaults

| Option | Default | Description |
|---|---|---|
| `user_agent` | `nil` | See [User Agent](#user-agent) |
| `max_retries` | `7` | Maximum 503 retry attempts |
| `open_timeout` | `10` | Seconds to wait for a connection |
| `read_timeout` | `30` | Seconds to wait for a response |
| `skip_proxy` | `true` | Bypass proxy even if configured |
| `proxy_address` | `"127.0.0.1"` | Proxy host |
| `proxy_port` | `9090` | Proxy port |
| `logger` | `nil` | Logger for retry messages and warnings |

### Config files

RestRequestor looks for config files in three tiers. Within each tier the first file found is used. Settings are merged across tiers — more specific tiers override less specific ones per key.

**Tier 1 — home/global** (least specific, checked in order):
```
$XDG_CONFIG_HOME/rest_requestor/config.yml
~/.config/rest_requestor/config.yml
~/.rest_requestor_config.yml
```

**Tier 2 — explicit path**:
```
$REST_REQUESTOR_CONFIG   (environment variable containing a file path)
```

**Tier 3 — project-local** (most specific):
```
{project_root}/config/rest_requestor_config.yml
```

**Example:** a global `~/.rest_requestor_config.yml` sets `user_agent`, a project's `config/rest_requestor_config.yml` sets `max_retries`. Both settings apply; the project value wins if the same key appears in both.

**Config file format:**

```yaml
user_agent: MyApp
max_retries: 3
open_timeout: 5
read_timeout: 20
```

`user_agent` in a config file is sanitized — any character outside `[A-Za-z0-9_-]` is replaced with `_` — and `/VERSION` is appended automatically. `"My App"` becomes `"My_App/0.4.0"`.

Numeric settings (`max_retries`, `open_timeout`, `read_timeout`) are ignored if zero or negative.

### Environment variables

| Variable | Effect |
|---|---|
| `REST_REQUESTOR_CONFIG` | Path to a config file (Tier 2 above) |
| `REST_REQUESTOR_SKIP_PROXY` | Set to `1`, `true`, or `yes` to bypass proxy regardless of instance config |

## User Agent

RestRequestor ships with **no default user agent**. Omitting one means no `User-Agent` header is sent, and many APIs will reject or rate-limit headerless requests.

If you create an instance without a `user_agent` configured, a warning is printed to `$stderr` (and to your logger, if one is set):

```
[RestRequestor] No user_agent set — many APIs require one.
Pass user_agent: "YourApp/1.0" to the initializer or set it in a config file.
```

The deliberate lack of a default protects other users of the gem: a shared default string like `RestRequestor/0.4.0` would mean one irresponsible client could get that string blocked or flagged everywhere.

**Set your user agent** via the initializer, a project config file, or a global config file — whatever fits your workflow:

```ruby
RestRequestor.new(user_agent: "MyApp/1.0")
```

```yaml
# config/rest_requestor_config.yml
user_agent: MyApp
```

## Proxy Support

Proxy support is disabled by default (`skip_proxy: true`). To enable it:

```ruby
rr = RestRequestor.new(
  user_agent:    "MyApp/1.0",
  skip_proxy:    false,
  proxy_address: "proxy.corp.example.com",
  proxy_port:    8080
)
```

When `skip_proxy` is `false`, RestRequestor probes the proxy at instantiation time and falls back to a direct connection if it is unreachable.

## Redirect Resolution

`resolve_redirects` follows a redirect chain and returns the final URL without fetching the full response body. Useful for resolving shortened or redirecting URLs before making a real request.

```ruby
final_url = rr.resolve_redirects("https://short.example.com/abc123")
# => "https://real.destination.example.com/some/path"
```

Raises `RestRequestor::TooManyRedirectsError` if the chain exceeds the limit (default 10).

## Contributing

Bug reports and pull requests are welcome at https://codeberg.org/jswright61/rest_requestor.

1. Fork the repo on Codeberg
2. Create a branch (`git checkout -b my-fix`)
3. Make your changes and add tests — patches without tests will not be merged
4. Run the test suite and confirm it is green (`ruby -Ilib test/test_rest_requestor.rb`)
5. Open a pull request against `main` with a clear description of what changed and why

Please keep pull requests focused — one fix or feature per PR. If you are planning something substantial, open an issue first to discuss the approach before writing code.

After cloning, activate the pre-push hook:

```
git config core.hooksPath .githooks
```

## Requirements

- Ruby >= 3.0
- No external runtime dependencies

## License

MIT
