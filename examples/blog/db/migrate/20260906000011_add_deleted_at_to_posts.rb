class AddDeletedAtToPosts < Facet::Orm::Migration
  def up
    add_column :posts, :deleted_at, :datetime, default: nil
  end

  def down
    remove_column :posts, :deleted_at
  end
end
