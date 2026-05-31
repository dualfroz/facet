class AddFeaturedToPosts < Prism::Orm::Migration
  def up
    add_column :posts, :featured, default: false
  end

  def down
    remove_column :posts, :featured
  end
end
