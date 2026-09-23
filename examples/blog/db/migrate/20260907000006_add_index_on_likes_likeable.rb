class AddIndexOnLikesLikeable < Facet::Orm::Migration
  def up
    add_index :likes, %i[likeable_id likeable_type]
  end

  def down
    remove_index :likes, %i[likeable_id likeable_type]
  end
end
