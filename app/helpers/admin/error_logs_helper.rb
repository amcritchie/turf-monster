module Admin
  module ErrorLogsHelper
    # Parse the exception class out of an ErrorLog's inspect_field, which the
    # engine formats as "#<ClassName: message>" (see ErrorLog.capture!). There
    # is no exception-class column, so this regex is the single source of truth.
    # Class names are word chars + "::"; we stop at the first ": " (colon-space)
    # that precedes the message. Falls back to "Unknown" for malformed inspects.
    def error_class_for(log)
      Admin::ErrorLogsHelper.error_class_from_inspect(log&.inspect_field)
    end

    def self.error_class_from_inspect(inspect)
      m = inspect.to_s.match(/\A#<([A-Za-z0-9_:]+):/)
      m ? m[1] : "Unknown"
    end

    # Best-effort deep-link to a polymorphic target/parent record's admin page.
    # Renders an <a> when a route resolves, otherwise plain "Type: name" text.
    # Fully guarded — a deleted/orphaned target must never 500 the show page.
    def error_record_link(type:, id:, name:)
      return content_tag(:span, "None", class: "text-muted text-sm") if type.blank?

      label = name.presence || "#{type} ##{id}"
      path  = error_record_path(type, id, name)

      if path
        link_to(label, path, class: "text-primary hover:underline text-sm break-all")
      else
        content_tag(:span, "#{type}: #{label}", class: "text-heading text-sm break-all")
      end
    rescue StandardError
      content_tag(:span, "#{type} ##{id}", class: "text-heading text-sm break-all")
    end

    # Resolve the admin/show path for a polymorphic record. Prefers the slug
    # (target_name, set by rescue_and_log) since the app's routes are slug-keyed,
    # falling back to id. Returns nil when no usable route exists (caller then
    # renders plain text). Guarded so a lookup on a dropped table/record is safe.
    def error_record_path(type, id, name)
      case type
      when "Contest"
        contest = Contest.find_by(slug: name) || (id && Contest.find_by(id: id))
        contest && contest_path(contest)
      when "Entry"
        entry = Entry.find_by(slug: name) || (id && Entry.find_by(id: id))
        entry&.contest && contest_path(entry.contest)
      when "User"
        # No per-user admin show page exists; the users browser is the closest
        # admin surface for a User target.
        admin_users_path
      end
    rescue StandardError
      nil
    end
  end
end
