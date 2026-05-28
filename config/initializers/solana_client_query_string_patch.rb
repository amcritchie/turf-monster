# solana-studio 0.4.2 bug: Solana::Client#http_post builds the HTTP request
# with @uri.path only, dropping the query string. Breaks any RPC provider
# that carries auth in the query — e.g. Helius's ?api-key=...
#
# https://github.com/.../solana-studio fix tracked; remove this initializer
# after bumping the gem (and bundle updating here).

require "solana/client"
require "net/http"

module Solana
  class Client
    private

    def http_post(body)
      http = Net::HTTP.new(@uri.host, @uri.port)
      if @uri.scheme == "https"
        http.use_ssl = true
        http.verify_mode = OpenSSL::SSL::VERIFY_PEER
        http.min_version = OpenSSL::SSL::TLS1_2_VERSION
      end
      http.open_timeout = 10
      http.read_timeout = 30

      # Use request_uri (path + query) instead of just path. This is the
      # one-line fix vs upstream — preserves ?api-key=... etc.
      request_path = @uri.request_uri
      request_path = "/" if request_path.nil? || request_path.empty?

      request = Net::HTTP::Post.new(request_path)
      request["Content-Type"] = "application/json"
      request.body = body.to_json

      http.request(request)
    end
  end
end
