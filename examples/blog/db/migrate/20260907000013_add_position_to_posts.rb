class AddPositionToPosts < Prism::Orm::Migration
  def up
    add_column :posts, :position
  end

  def down
    remove_column :posts, :position
  end
end
