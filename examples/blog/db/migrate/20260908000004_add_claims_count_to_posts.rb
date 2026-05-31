class AddClaimsCountToPosts < Prism::Orm::Migration
  def up
    add_column :posts, :claims_count, :integer, default: 0
  end

  def down
    remove_column :posts, :claims_count
  end
end
