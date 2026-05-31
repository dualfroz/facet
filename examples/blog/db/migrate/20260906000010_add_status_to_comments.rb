class AddStatusToComments < Prism::Orm::Migration
  def up
    add_column :comments, :status, :integer, default: 0
  end

  def down
    remove_column :comments, :status
  end
end
