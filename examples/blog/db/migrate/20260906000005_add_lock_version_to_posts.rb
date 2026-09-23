class AddLockVersionToPosts < Facet::Orm::Migration
  def up
    add_column :posts, :lock_version, :integer, default: 0
  end

  def down
    remove_column :posts, :lock_version
  end
end
