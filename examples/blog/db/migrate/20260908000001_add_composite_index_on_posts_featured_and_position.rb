class AddCompositeIndexOnPostsFeaturedAndPosition < Prism::Orm::Migration
  def up
    add_index :posts, %i[featured position]
  end

  def down
    remove_index :posts, %i[featured position]
  end
end
