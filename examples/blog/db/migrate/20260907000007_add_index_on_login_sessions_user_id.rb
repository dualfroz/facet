class AddIndexOnLoginSessionsUserId < Prism::Orm::Migration
  def up
    add_index :login_sessions, :user_id
  end

  def down
    remove_index :login_sessions, :user_id
  end
end
