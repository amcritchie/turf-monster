class CreateEmailDeliveries < ActiveRecord::Migration[7.2]
  def change
    create_table :email_deliveries do |t|
      t.string  :email_key, null: false            # "UserMailer#magic_link"
      t.string  :to                                 # recipient address (for the log)
      t.string  :mailer, null: false                # mailer class name
      t.string  :action, null: false                # mailer method
      t.jsonb   :args,   null: false, default: []   # ActiveJob-serialized positional args
      t.jsonb   :kwargs, null: false, default: {}   # ActiveJob-serialized keyword args
      t.boolean :sent,   null: false, default: false
      t.datetime :sent_at
      t.text :error
      t.references :user, foreign_key: true         # recipient, when known

      t.timestamps
    end

    add_index :email_deliveries, :sent
    add_index :email_deliveries, :email_key
    add_index :email_deliveries, :created_at
  end
end
