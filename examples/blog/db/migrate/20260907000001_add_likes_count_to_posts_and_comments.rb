class AddLikesCountToPostsAndComments < Facet::Orm::Migration
  def up
    add_column :posts, :likes_count, :integer, default: 0
    add_column :comments, :likes_count, :integer, default: 0
  end

  def down
    remove_column :posts, :likes_count
    remove_column :comments, :likes_count
  end
end
