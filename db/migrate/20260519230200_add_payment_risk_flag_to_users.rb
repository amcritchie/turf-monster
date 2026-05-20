class AddPaymentRiskFlagToUsers < ActiveRecord::Migration[7.2]
  def change
    # OPSEC-036: set true when a Stripe dispute (chargeback) lands for this
    # user — blocks further card token purchases.
    add_column :users, :payment_risk_flag, :boolean, default: false, null: false
  end
end
