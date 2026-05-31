class CreateClaims < Prism::Orm::Migration
  def up
    create_table :claims do |t|
      t.integer :post_id
      t.integer :user_id
      t.datetime :deleted_at
      t.timestamps
    end
    # Belt and braces with Claim's own `validates :user_id, uniqueness:
    # { scope: :post_id }`: the model-level check only ever sees rows this
    # same process/transaction can already read, whereas this unique index
    # is enforced by Store#validate_unique_indexes inside the very same
    # transaction the insert itself runs in (see Store#insert), so it
    # still catches a duplicate claim even in the hypothetical case of two
    # inserts racing without going through Post#with_lock first.
    add_index :claims, %i[post_id user_id], unique: true
  end

  def down
    drop_table :claims
  end
end
