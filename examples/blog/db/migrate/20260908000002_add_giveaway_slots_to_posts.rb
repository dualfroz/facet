class AddGiveawaySlotsToPosts < Facet::Orm::Migration
  def up
    add_column :posts, :giveaway_slots, :integer
  end

  def down
    remove_column :posts, :giveaway_slots
  end
end
