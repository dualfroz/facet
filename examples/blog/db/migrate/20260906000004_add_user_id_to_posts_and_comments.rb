class AddUserIdToPostsAndComments < Facet::Orm::Migration
  def up
    add_column :posts, :user_id
    add_column :comments, :user_id
  end

  def down
    remove_column :posts, :user_id
    remove_column :comments, :user_id
  end
end
