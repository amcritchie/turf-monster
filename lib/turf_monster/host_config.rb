module TurfMonster
  module HostConfig
    module_function

    def aliases(raw_aliases)
      raw_aliases.to_s.split(",").map(&:strip).reject(&:empty?)
    end

    def public_hosts(app_host:, aliases:)
      [ app_host, *aliases ].uniq
    end

    def allowed_https_origins(hosts)
      hosts.map { |host| %r{\Ahttps://#{Regexp.escape(host)}\z} }
    end
  end
end
