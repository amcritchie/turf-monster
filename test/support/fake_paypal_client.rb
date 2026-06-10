# Paypal::Client stand-in for tests (FakeVault sibling).
#
# Usage:
#   client = FakePaypalClient.new(order_id: "ORDER1")
#   Paypal::Client.stub :new, client do
#     # code under test
#   end
#   assert_equal 1, client.created_orders.length
class FakePaypalClient
  attr_reader :created_orders, :captured_orders, :verify_calls
  attr_accessor :order_id, :capture_response, :capture_raises, :verify_result

  def initialize(order_id: "FAKEORDER#{SecureRandom.hex(3).upcase}", capture_response: nil, verify_result: true)
    @order_id = order_id
    @capture_response = capture_response
    @verify_result = verify_result
    @capture_raises = nil
    @created_orders = []
    @captured_orders = []
    @verify_calls = []
  end

  def create_order(pack:, user:, purchase:)
    @created_orders << { pack: pack, user: user, purchase: purchase }
    { "id" => @order_id, "status" => "CREATED" }
  end

  def capture_order(order_id)
    raise Paypal::Client::Error, @capture_raises if @capture_raises
    @captured_orders << order_id
    @capture_response || FakePaypalClient.completed_capture_response(order_id: order_id)
  end

  def get_order(order_id)
    { "id" => order_id, "status" => "CREATED" }
  end

  def verify_webhook_signature(headers:, raw_body:)
    @verify_calls << { headers: headers, raw_body: raw_body }
    @verify_result
  end

  # POST /v2/checkout/orders/{id}/capture response, reduced to the fields the
  # app reads (order status + first purchase_unit's first capture).
  def self.completed_capture_response(order_id:, amount: "19.00", currency: "USD", capture_id: nil, status: "COMPLETED")
    {
      "id" => order_id,
      "status" => status,
      "purchase_units" => [{
        "payments" => {
          "captures" => [{
            "id" => capture_id || "CAP#{SecureRandom.hex(4).upcase}",
            "status" => status,
            "amount" => { "currency_code" => currency, "value" => amount }
          }]
        }
      }]
    }
  end
end
