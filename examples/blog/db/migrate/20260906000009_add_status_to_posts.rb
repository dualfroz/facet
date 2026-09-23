class AddStatusToPosts < Facet::Orm::Migration
  def up
    add_column :posts, :status, :integer, default: 0
  end

  def down
    remove_column :posts, :status
  end
end
