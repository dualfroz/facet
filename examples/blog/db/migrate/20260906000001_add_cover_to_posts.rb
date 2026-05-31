class AddCoverToPosts < Prism::Orm::Migration
  def up
    add_column :posts, :cover, default: nil
  end

  def down
    remove_column :posts, :cover
  end
end
