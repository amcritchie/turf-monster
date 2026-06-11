namespace :ses do
  # Health-check / DKIM helper for the SES transport, without the aws CLI (signs
  # SES API calls with aws-sigv4). Export creds first (or have them in .env):
  #   export AWS_ACCESS_KEY_ID=...  AWS_SECRET_ACCESS_KEY=...  SES_REGION=us-east-2
  #   bin/rails ses:check
  #   bin/rails "ses:verify_domain[turfmonster.media]"

  def ses_signer(region)
    begin
      require "aws-sigv4"
    rescue LoadError
      abort "ses:* needs the aws-sigv4 gem — add `gem \"aws-sigv4\"` to the Gemfile (or use the aws CLI)."
    end
    Aws::Sigv4::Signer.new(
      service: "ses", region: region,
      access_key_id: ENV.fetch("AWS_ACCESS_KEY_ID"),
      secret_access_key: ENV.fetch("AWS_SECRET_ACCESS_KEY")
    )
  end

  def ses_request(signer, region, method, path, body = nil)
    require "net/http"
    require "json"
    url = "https://email.#{region}.amazonaws.com#{path}"
    headers = body ? { "content-type" => "application/json" } : {}
    sig = signer.sign_request(http_method: method, url: url, body: body, headers: headers)
    uri = URI(url)
    http = Net::HTTP.new(uri.host, 443); http.use_ssl = true
    req = Net::HTTP.const_get(method.capitalize).new(uri)
    headers.each { |k, v| req[k] = v }      # original headers (content-type) on the wire...
    sig.headers.each { |k, v| req[k] = v }  # ...plus the signed headers (authorization, x-amz-*)
    req.body = body if body
    res = http.request(req)
    [res.code.to_i, (JSON.parse(res.body) rescue { "raw" => res.body.to_s[0, 300] })]
  end

  def ses_error(body)
    body["message"] || body["Message"] || body["raw"]
  end

  desc "Check SES account status + verified identities (AWS_ACCESS_KEY_ID/SECRET in env)"
  task check: :environment do
    region = ENV.fetch("SES_REGION", "us-east-2")
    signer = ses_signer(region)
    get = ->(path) { ses_request(signer, region, "GET", path) }

    code, acct = get.call("/v2/email/account")
    puts "GetAccount (region #{region}) -> HTTP #{code}"
    if code == 200
      puts "  SendingEnabled=#{acct['SendingEnabled']}  ProductionAccessEnabled=#{acct['ProductionAccessEnabled']}  Enforcement=#{acct['EnforcementStatus']}"
    else
      puts "  ERROR: #{ses_error(acct)}"
    end

    code, ids = get.call("/v2/email/identities")
    puts "ListEmailIdentities -> HTTP #{code}"
    if code == 200
      list = ids["EmailIdentities"] || []
      puts "  identities: #{list.empty? ? '(none yet)' : list.map { |i| "#{i['IdentityName']}(#{i['VerifiedForSendingStatus'] ? 'verified' : 'pending'})" }.join(', ')}"
    else
      puts "  ERROR: #{ses_error(ids)}"
    end
    puts "Live transport: MAIL_TRANSPORT=#{ENV.fetch('MAIL_TRANSPORT', '(unset → resend)')}  delivery_method=#{ActionMailer::Base.delivery_method}"
  end

  desc "Create a SES domain identity and print the DKIM CNAME records to add to DNS"
  task :verify_domain, [:domain] => :environment do |_t, args|
    abort "Usage: ses:verify_domain[domain]" if args[:domain].blank?
    domain = args[:domain]
    region = ENV.fetch("SES_REGION", "us-east-2")
    signer = ses_signer(region)

    code, body = ses_request(signer, region, "POST", "/v2/email/identities",
                             { EmailIdentity: domain }.to_json)
    if code == 409 || (body["message"].to_s + body["Message"].to_s) =~ /already exists/i
      code, body = ses_request(signer, region, "GET", "/v2/email/identities/#{domain}")
    end

    if code != 200
      puts "#{domain}: ERROR (HTTP #{code}) #{ses_error(body)}"
      next
    end

    tokens = body.dig("DkimAttributes", "Tokens") || []
    status = body.dig("DkimAttributes", "Status") || body["VerifiedForSendingStatus"]
    puts "== #{domain} (region #{region}, DKIM status: #{status}) =="
    if tokens.empty?
      puts "  (no DKIM tokens returned)"
    else
      puts "  Add these 3 CNAME records to #{domain}'s DNS:"
      tokens.each do |t|
        puts "    NAME:  #{t}._domainkey.#{domain}"
        puts "    TYPE:  CNAME"
        puts "    VALUE: #{t}.dkim.amazonses.com"
        puts ""
      end
    end
  end
end
