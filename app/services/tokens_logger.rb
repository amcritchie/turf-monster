# Helper for pretty-printing Stripe / on-chain responses inside the [tokens] log
# trace. Each line of the awesome-printed output gets the [tokens] prefix so it
# survives a `grep "\[tokens\]"` filter while tailing the dev logs.
module TokensLogger
  module_function

  def dump(label, obj)
    pretty = obj.respond_to?(:ai) ? obj.ai(plain: false, indent: 2, sort_keys: true) : obj.inspect
    pretty.each_line do |line|
      Rails.logger.info "[tokens] #{label} | #{line.chomp}"
    end
  end
end
