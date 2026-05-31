class AddSlugToPosts < Prism::Orm::Migration
  def up
    # add_column's own default ('') would leave every existing row with the
    # SAME empty slug, which the unique index below would reject the moment
    # a second existing post tried to keep it - so every existing row gets
    # a real, distinct slug backfilled BEFORE the index goes on, the same
    # slugify Post.create_with_unique_slug uses for new rows (this runs at
    # the store level, not through the Post model - db:migrate does not
    # load app/models, see Prism::Cli#db_migrate).
    add_column :posts, :slug, default: ''
    backfill_unique_slugs
    add_index :posts, :slug, unique: true
  end

  def down
    remove_index :posts, :slug
    remove_column :posts, :slug
  end

  private

  def backfill_unique_slugs
    seen = {}
    store.all(:posts).each do |row|
      base = slugify(row['title'])
      slug = base
      suffix = 1
      while seen.key?(slug)
        suffix += 1
        slug = "#{base}-#{suffix}"
      end
      seen[slug] = true
      store.update(:posts, row['id'], 'slug' => slug)
    end
  end

  def slugify(title)
    base = title.to_s.downcase.gsub(/[^a-z0-9]+/, '-').gsub(/\A-+|-+\z/, '')
    base.empty? ? 'post' : base
  end
end
