class AddIndexOnCommentsPostId < Facet::Orm::Migration
  def up
    add_index :comments, :post_id
  end

  def down
    remove_index :comments, :post_id
  end
end
