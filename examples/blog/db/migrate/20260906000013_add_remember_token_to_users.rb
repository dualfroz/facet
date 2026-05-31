class AddRememberTokenToUsers < Prism::Orm::Migration
  def up
    add_column :users, :remember_token, default: nil
  end

  def down
    remove_column :users, :remember_token
  end
end
