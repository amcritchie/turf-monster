# Writes OutboundRequest audit rows. Called by:
#   - The Stripe::Instrumentation hook (config/initializers/outbound_request_hooks.rb)
#   - The Solana::Client prepend (config/initializers/outbound_request_hooks.rb)
#
# Sanitizes request/response bodies (drops secrets), truncates oversized payloads,
# and swallows its own errors so a logger failure never breaks the caller.
module OutboundRequestLogger
  # Any key whose name (case-insensitive) contains one of these substrings gets
  # redacted before write. Conservative — better to redact too much than leak.
  SENSITIVE_KEYS = %w[
    api_key apikey api-key
    secret signing_secret webhook_secret client_secret
    password passwd
    token bearer authorization auth
    private_key privatekey
    customer_email receipt_email email
    ssn tax_id
    webhook_id transmission_sig
  ].freeze
  REDACTED = "[REDACTED]".freeze
  MAX_BODY_BYTES = 16_384

  module_function

  def record!(service:, method: nil, endpoint: nil,
              request_body: nil, response_body: nil,
              status_code: nil, duration_ms: nil,
              error_class: nil, error_message: nil,
              source: nil, user: nil, acting_admin: nil)
    # Fall back to request/job context if caller didn't pass explicit attribution.
    # See app/models/current.rb.
    source       ||= Current.outbound_source if defined?(Current)
    user         ||= Current.user            if defined?(Current)
    # OPSEC-046: when an admin is impersonating, Current.true_admin is the real
    # actor behind this call. Stamp it so the audit row points at the admin, not
    # just the impersonated user.
    acting_admin ||= Current.true_admin      if defined?(Current)

    OutboundRequest.create!(
      service:         service,
      method:          method&.to_s,
      endpoint:        endpoint&.to_s,
      request_body:    prepare_body(request_body),
      response_body:   prepare_body(response_body),
      status_code:     status_code,
      duration_ms:     duration_ms,
      error_class:     error_class,
      error_message:   error_message&.to_s&.first(2000),
      source:          source,
      user:            user,
      acting_admin_id: acting_admin&.id
    )
  rescue => e
    # Logger must never break the caller. Surface in dev logs so we can spot misconfig.
    Rails.logger.error "[outbound_request_logger] failed: #{e.class}: #{e.message}"
    nil
  end

  # ── Internals ───────────────────────────────────────────────────────────

  def prepare_body(body)
    return {} if body.nil?

    hash = coerce_to_hash(body)
    redacted = deep_redact(hash)

    json = redacted.to_json
    if json.bytesize > MAX_BODY_BYTES
      {
        "_truncated" => true,
        "original_bytesize" => json.bytesize,
        "preview" => json.byteslice(0, MAX_BODY_BYTES)
      }
    else
      redacted
    end
  end

  def coerce_to_hash(body)
    case body
    when Hash  then body
    when Array then { "_array" => body }
    when String
      parsed = JSON.parse(body) rescue nil
      parsed.is_a?(Hash) ? parsed : { "_raw" => body }
    else
      { "_value" => body.to_s }
    end
  end

  def deep_redact(obj)
    case obj
    when Hash
      obj.each_with_object({}) do |(k, v), out|
        out[k.to_s] = sensitive_key?(k) ? REDACTED : deep_redact(v)
      end
    when Array
      obj.map { |v| deep_redact(v) }
    else
      obj
    end
  end

  def sensitive_key?(key)
    name = key.to_s.downcase
    SENSITIVE_KEYS.any? { |sk| name.include?(sk) }
  end
end
