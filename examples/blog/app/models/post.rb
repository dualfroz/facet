require 'csv'

class Post < Prism::Orm::Model
  # Result of .import_csv below - `imported` are posts that actually made
  # it to disk, `skipped` are { title:, errors: } pairs for rows that
  # never did (blank title, or a slug collision that outlived
  # MAX_SLUG_ATTEMPTS).
  ImportResult = Struct.new(:imported, :skipped)

  MAX_SLUG_ATTEMPTS = 20

  belongs_to :user
  has_many :comments, dependent: :destroy
  has_many :likes, as: :likeable, dependent: :destroy
  # dependent: :destroy, not :nullify - same reasoning as comments/likes
  # above: Claim is paranoid too (see the model), so trashing this post
  # soft-deletes its claims along with it and #restore(recursive: true)
  # brings them back, rather than a plain trash permanently erasing the
  # record of who already won a giveaway slot.
  has_many :claims, dependent: :destroy

  # A deleted post lands in the trash (see PostsController#destroy/#trash/
  # #restore) instead of vanishing outright - Post.all/#find already hide
  # it everywhere else in the app for free. Comment and Like are paranoid
  # too, so the `dependent: :destroy` cascades above soft-delete them the
  # moment a post is trashed instead of removing them for real, and
  # PostsController#restore(recursive: true) brings them all back together
  # with the post (see Associable#cascade_restore_dependent_associations).
  acts_as_paranoid

  # Every post starts life as a draft (column default 0, see the
  # add_status_to_posts migration) - only #publish! on posts#show makes it
  # show up on the public index (see PostsController#index below).
  enum :status, { draft: 0, published: 1, archived: 2 }

  # Prism::Orm::Attributes: casts the "featured" checkbox's form value
  # ("1"/"0", always a String off an HTTP request - see the hidden-field
  # trick in _form.erb) into a real TrueClass/FalseClass on write, instead
  # of leaving the literal string "1" sitting in the featured column. That
  # distinction is not cosmetic: `where(featured: true)` (see the
  # .featured scope below and PostsController#index's `?featured=1`
  # filter) does a plain Ruby `==` against whatever is actually stored,
  # so a stored String would never match a query for the Boolean `true`.
  attribute :featured, :boolean, default: false

  # Same reasoning as TypeCasting.cast_integer's own comment: blank input
  # from the (optional) giveaway_slots form field casts to nil, not 0 - nil
  # means "not a giveaway post" (see #giveaway? below), 0 means "was a
  # giveaway, every slot already claimed", and those are not the same
  # state for #giveaway_sold_out? to report.
  attribute :giveaway_slots, :integer

  scope :featured, -> { where(featured: true) }

  # acts_as_list scoped by the featured flag itself: every post gets a
  # position within its own featured/non-featured group (the non-featured
  # group's numbers are never shown or reordered - see posts#index and
  # PostsController#move_up/#move_down, both gated on featured_only), so
  # toggling a post's own featured flag on/off cheaply hops it between two
  # already-maintained lists (append to the bottom of whichever group it
  # lands in) instead of needing a bespoke third state to track "not in
  # any list yet". Editors use #move_up/#move_down to curate which
  # featured posts lead the homepage instead of always showing the most
  # recently featured one first.
  acts_as_list column: :position, scope: :featured

  # Backed by the range-capable secondary index on created_at
  # (db/migrate/20260907000004_add_index_on_posts_created_at.rb) - the
  # gte/lte hash this builds is exactly what
  # Query::ConditionNode#indexable_ranges recognizes, so PostsController#index
  # chaining this onto .published (see below) hits
  # Store#lookup_by_index_range with an O(log n) binary search over
  # sorted_values instead of a full table scan. See Store#lookup_by_index_range.
  scope :created_within, ->(days) { where(created_at: { gte: Time.now.utc - (days.to_i * 86_400) }) }

  # Lets the author moderate comments (edit or remove) from the same form
  # used to edit the post itself - reject_if: :all_blank so a moderation
  # form that only ever submits EXISTING comment rows (no "add a comment"
  # field on this screen) never has to worry about accidentally building
  # a blank new one.
  accepts_nested_attributes_for :comments, allow_destroy: true, reject_if: :all_blank

  validates :title, presence: true, length: { minimum: 3 }
  validates :body, presence: true

  before_destroy :remove_cover_file

  class << self
    # Builds and saves a post, deriving a URL-safe slug from its title and
    # retrying with a numeric suffix (-2, -3, ...) on a real collision from
    # the unique index on posts.slug (see the add_slug_to_posts migration)
    # instead of surfacing a raw Store::UniqueConstraintViolation to the
    # caller. Each attempt runs in its own transaction(requires_new: true)
    # SAVEPOINT (lib/prism/orm/transactions.rb, session 94) rather than a
    # plain nested transaction - this is not decorative: a post whose
    # insert loses the unique-slug race is still enlisted as a transaction
    # participant (Model#save calls enlist_in_transaction before the
    # insert that might fail), so without a savepoint to pop that doomed
    # participant back out, it would ride along in the SAME frame as
    # whatever else the surrounding transaction commits and wrongly fire
    # this model's after_commit(on: :create) - our NotificationMailer
    # hook below - for a post that was never actually created (id nil).
    # requires_new's rollback_frame removes it from the frame entirely and
    # fires after_rollback for it immediately instead. See .import_csv,
    # the one caller that puts multiple attempts inside a shared outer
    # transaction where this distinction is observable.
    #
    # A candidate that collides with a RESERVED slug (see #reserved_slugs
    # below) is treated exactly like a real unique-index collision and
    # retried with the same numeric suffix - raising the store's own
    # UniqueConstraintViolation before ever attempting the insert reuses
    # the retry/give-up loop below instead of duplicating it, and is
    # accurate: both cases mean this exact slug can never resolve to this
    # post's show page.
    def create_with_unique_slug(attributes)
      base_slug = slugify(attributes['title'] || attributes[:title])
      post = new(attributes)
      return post unless post.valid?

      attempt = 0
      begin
        attempt += 1
        candidate = attempt == 1 ? base_slug : "#{base_slug}-#{attempt}"
        raise Prism::Orm::Store::UniqueConstraintViolation if reserved_slugs.include?(candidate)

        post.slug = candidate
        transaction(requires_new: true) { post.save! }
      rescue Prism::Orm::Store::UniqueConstraintViolation
        retry if attempt < MAX_SLUG_ATTEMPTS
        post.errors.add(:slug, "could not be made unique after #{MAX_SLUG_ATTEMPTS} attempts")
      end
      post
    end

    # Every literal (non-`:param`) single-segment route Blog registers
    # directly under /posts/ - i.e. `collection do get(:trash) end` and
    # friends in app.rb. A post whose slug happened to literally equal one
    # of these (say, a post titled "Trash") would be permanently
    # unreachable at its own /posts/<slug> URL: Application#dispatch tries
    # routes in registration order (see the "Custom collection/member/
    # nested routes go first" comment in Application.resources) and the
    # collection route, being literal, is registered - and therefore
    # tried - before the generic /posts/:slug show route it would
    # otherwise shadow. Derived from the router itself rather than a
    # hand-kept word list, so a future collection action added in app.rb
    # is automatically reserved too instead of silently reintroducing
    # this bug the day someone forgets to update a hardcoded list.
    def reserved_slugs
      @reserved_slugs ||= Blog.router.routes.filter_map do |route|
        match = route.pattern.match(%r{\A/posts/([^:/][^/]*)\z})
        match && match[1]
      end.uniq
    end

    # Bulk-creates posts from an uploaded CSV (title,body columns) in ONE
    # outer transaction for the whole batch - the counterpart to
    # PostsController#export, which streams the same shape back out. A row
    # that can't be imported (blank title, or an exhausted slug retry) is
    # skipped and reported instead of aborting rows already committed
    # earlier in the same batch, which is exactly the guarantee
    # .create_with_unique_slug's per-row savepoint above exists to give:
    # without it, Store#within_transaction flattens every nested `transaction`
    # call into ONE shared in-memory table (see TransactionRegistry), so a
    # single bad row deep in a large CSV would otherwise either roll back
    # every row already imported ahead of it, or - worse - stay silently
    # enlisted and fire a phantom "new post" notification for a row that
    # was never actually saved.
    def import_csv(io, author:)
      imported = []
      skipped = []
      transaction do
        CSV.parse(io, headers: true) do |row|
          title = row['title'].to_s
          post = create_with_unique_slug(
            'title' => title, 'body' => row['body'].to_s, 'status' => :published, 'user_id' => author.id
          )
          if post.persisted?
            imported << post
          else
            skipped << { title: title, errors: post.errors.full_messages }
          end
        end
      end
      ImportResult.new(imported, skipped)
    end

    private

    def slugify(title)
      base = title.to_s.downcase.gsub(/[^a-z0-9]+/, '-').gsub(/\A-+|-+\z/, '')
      base.empty? ? 'post' : base
    end
  end

  # Queued from after_commit (not right after #save returns truthy) so the
  # notification only ever goes out for a post that actually survived to
  # disk - a failed after_create elsewhere in the callback chain rolls the
  # whole save back and this never fires, whereas a plain post-save call
  # site can't tell the difference between "saved" and "saved, but the
  # transaction it was part of later rolled back".
  after_commit(on: :create) { NotificationMailer.new_post(id).deliver_later }

  # Overrides Prism::Orm::Model#to_param (id.to_s) so every post-URL
  # call site that writes `post.to_param` gets the friendly slug instead
  # of the numeric id - see app.rb's `resources :posts, param: :slug`.
  def to_param
    slug
  end

  # nil giveaway_slots (the column default) means this post was never
  # opted into the giveaway feature at all - distinct from a real 0, which
  # can only be reached by every slot actually being claimed (see
  # #giveaway_remaining/#giveaway_sold_out?).
  def giveaway?
    !giveaway_slots.nil?
  end

  # claims_count, not claims.count/claims.size - the counter cache column
  # ClaimsController#create's Post#with_lock critical section reads (via
  # #giveaway_sold_out? below) has to be the SAME read a concurrent,
  # blocked-on-the-file-lock request will see the instant it gets its own
  # turn, and only the counter cache is guaranteed to be updated inside
  # that same transaction (see Claim's belongs_to counter_cache: true) -
  # counting the claims association fresh here would still be correct, but
  # would cost an extra query for no benefit.
  def giveaway_remaining
    return nil unless giveaway?
    [giveaway_slots - claims_count, 0].max
  end

  def giveaway_sold_out?
    giveaway? && giveaway_remaining.zero?
  end

  private

  # Without this, every hard-deleted post left its uploaded cover behind in
  # public/uploads forever - PostsController#store_cover writes only the
  # bare filename onto the row, so nothing else ever points back at the file.
  # Skipped for a plain trash (#soft_deleting?, see acts_as_paranoid above):
  # the row can still come back via #restore, and a restored post whose
  # cover image was already deleted from disk would be a broken restore,
  # not a real one.
  def remove_cover_file
    return if soft_deleting?
    return unless cover && !cover.empty?
    path = File.join(APP_ROOT, 'public', 'uploads', cover)
    File.delete(path) if File.exist?(path)
  end
end
