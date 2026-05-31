class AddConfirmedAtToUsers < Prism::Orm::Migration
  def up
    add_column :users, :confirmed_at, :datetime, default: nil
  end

  def down
    remove_column :users, :confirmed_at
  end
end
