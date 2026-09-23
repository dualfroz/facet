class CreateClaims < Facet::Orm::Migration
  def up
    create_table :claims do |t|
      t.integer :post_id
      t.integer :user_id
      t.datetime :deleted_at
      t.timestamps
    end
    add_index :claims, %i[post_id user_id], unique: true
  end

  def down
    drop_table :claims
  end
end
