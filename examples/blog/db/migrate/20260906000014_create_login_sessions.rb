class CreateLoginSessions < Facet::Orm::Migration
  def up
    create_table :login_sessions do |t|
      t.integer :user_id
      t.string :token
      t.timestamps
    end
  end

  def down
    drop_table :login_sessions
  end
end
