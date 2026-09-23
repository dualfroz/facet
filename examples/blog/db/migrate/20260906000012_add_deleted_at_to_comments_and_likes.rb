class AddDeletedAtToCommentsAndLikes < Facet::Orm::Migration
  def up
    add_column :comments, :deleted_at, :datetime, default: nil
    add_column :likes, :deleted_at, :datetime, default: nil
  end

  def down
    remove_column :comments, :deleted_at
    remove_column :likes, :deleted_at
  end
end
