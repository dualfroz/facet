class AddGiveawaySlotsToPosts < Prism::Orm::Migration
  def up
    # No default (nil) on purpose - nil means "not a giveaway post" (see
    # Post#giveaway?), distinct from 0 ("was a giveaway, now sold out
    # forever"). A post created before this migration, or one nobody ever
    # opted into the giveaway field for, reads back as nil either way.
    add_column :posts, :giveaway_slots, :integer
  end

  def down
    remove_column :posts, :giveaway_slots
  end
end
