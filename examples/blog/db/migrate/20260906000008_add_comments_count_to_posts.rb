class AddCommentsCountToPosts < Prism::Orm::Migration
  def up
    add_column :posts, :comments_count, :integer, default: 0
  end

  def down
    remove_column :posts, :comments_count
  end
end
