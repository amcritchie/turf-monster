module Admin
  # Email manager — lists every email the app sends (typed transactional/marketing)
  # with a live preview. The transactional/marketing split + this manager move into
  # the shared studio-engine email framework (Phase 2); built here first.
  class EmailsController < ApplicationController
    before_action :require_admin
    before_action :load_email, only: %i[show raw]

    # GET /admin/emails
    def index
      @emails = EmailCatalog.entries
    end

    # GET /admin/emails/:key — manager page with the live preview iframe.
    def show
      @subject = safe_build&.subject
    end

    # GET /admin/emails/:key/raw — the rendered email itself (iframe source).
    def raw
      mail = @email.builder.call
      html = (mail.html_part&.body || mail.body).to_s
      render plain: html, content_type: "text/html", layout: false
    rescue => e
      render plain: error_html(e), content_type: "text/html", layout: false
    end

    private

    def load_email
      @email = EmailCatalog.find(params[:key])
      head :not_found unless @email
    end

    def safe_build
      @email.builder.call
    rescue StandardError
      nil
    end

    def error_html(error)
      "<body style='font-family:system-ui;color:#b91c1c;padding:2rem'>" \
        "Preview unavailable — this email needs sample data.<br><small>#{ERB::Util.html_escape(error.message)}</small></body>"
    end
  end
end
