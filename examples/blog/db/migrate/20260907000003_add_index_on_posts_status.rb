class AddIndexOnPostsStatus < Facet::Orm::Migration
  def up
    add_index :posts, :status
  end

  def down
    remove_index :posts, :status
  end
end
