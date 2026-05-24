# Reads the on-chain seeds state for a user immediately after an entry.
# Two near-identical rescue blocks in ContestsController#enter and
# #confirm_onchain_entry converged here — if either Solana read fails,
# we log and return zeros rather than blowing up the JSON response that
# confirms a successful entry.
#
# Usage:
#   snapshot = UserSeedsSnapshot.for(user: current_user, entry: entry)
#   render json: { success: true }.merge(snapshot.to_h)
#
# Returns zeros if the entry has no entry_number (e.g. a comped/free entry
# that never landed on-chain).
class UserSeedsSnapshot
  attr_reader :earned, :total, :level

  def self.for(user:, entry:)
    new(user: user, entry: entry).tap(&:fetch!)
  end

  def initialize(user:, entry:)
    @user = user
    @entry = entry
    @earned = 0
    @total = 0
    @level = 0
  end

  def fetch!
    return self if @entry.entry_number.blank?

    vault = Solana::Vault.new

    begin
      @earned = vault.seeds_for_entry(@entry.entry_number)
    rescue => e
      Rails.logger.warn "[seeds] failed seeds_for_entry entry=#{@entry.id}: #{e.message}"
    end

    if @user.solana_connected?
      begin
        onchain = vault.sync_balance(@user.solana_address)
        @total = onchain&.dig(:seeds) || 0
      rescue => e
        Rails.logger.warn "[seeds] failed sync_balance user=#{@user.id}: #{e.message}"
      end
    end

    @level = User.level_for(@total)
    self
  end

  def to_h
    { seeds_earned: @earned, seeds_total: @total, seeds_level: @level }
  end
end
