# Public Transparency hub. A single page that links to every trust /
# legitimacy / help page (on-chain program, proof of reserves, source code,
# legal, and help) so reviewers (and users) can be handed one URL instead of a
# list. Cited in the Phantom / Blowfish de-list appeal.
class TransparencyController < ApplicationController
  skip_before_action :require_authentication
  skip_before_action :require_profile_completion, raise: false

  def show
  end
end
