class AddLockVersionToComments < Prism::Orm::Migration
  def up
    add_column :comments, :lock_version, :integer, default: 0
  end

  def down
    remove_column :comments, :lock_version
  end
end
