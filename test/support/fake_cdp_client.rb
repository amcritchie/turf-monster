# Canned-response Cdp::Client stand-in (house pattern: stub at the service
# seam, no real HTTP — see FakeVault / Cdp::CatalogTest::FakeClient). Used by
# the poll-job tests via `Cdp::Client.stub :new, fake`.
#
#   client = FakeCdpClient.new("/onramp/v1/buy/user/tm-1-2/transactions" => { "transactions" => [tx] })
#   client = FakeCdpClient.new({}, raise_error: Cdp::Client::ApiError.new("boom"))
#
# Responses are keyed by exact path; a value may be a Hash or a callable that
# receives the query params. Every get is recorded in #calls as [path, params].
class FakeCdpClient
  attr_reader :calls

  def initialize(responses = {}, raise_error: nil)
    @responses = responses
    @raise_error = raise_error
    @calls = []
  end

  def get(path, params = {})
    @calls << [path, params]
    raise @raise_error if @raise_error

    response = @responses.fetch(path) { raise Cdp::Client::ApiError.new("unstubbed path #{path}") }
    response.respond_to?(:call) ? response.call(params) : response
  end
end
