require 'csv'

class Post < Facet::Orm::Model
  ImportResult = Struct.new(:imported, :skipped)

  MAX_SLUG_ATTEMPTS = 20

  belongs_to :user
  has_many :comments, dependent: :destroy
  has_many :likes, as: :likeable, dependent: :destroy
  has_many :claims, dependent: :destroy

  acts_as_paranoid

  enum :status, { draft: 0, published: 1, archived: 2 }

  attribute :featured, :boolean, default: false

  attribute :giveaway_slots, :integer

  scope :featured, -> { where(featured: true) }

  acts_as_list column: :position, scope: :featured

  scope :created_within, ->(days) { where(created_at: { gte: Time.now.utc - (days.to_i * 86_400) }) }

  accepts_nested_attributes_for :comments, allow_destroy: true, reject_if: :all_blank

  validates :title, presence: true, length: { minimum: 3 }
  validates :body, presence: true

  before_destroy :remove_cover_file

  class << self
    def create_with_unique_slug(attributes)
      base_slug = slugify(attributes['title'] || attributes[:title])
      post = new(attributes)
      return post unless post.valid?

      attempt = 0
      begin
        attempt += 1
        candidate = attempt == 1 ? base_slug : "#{base_slug}-#{attempt}"
        raise Facet::Orm::Store::UniqueConstraintViolation if reserved_slugs.include?(candidate)

        post.slug = candidate
        transaction(requires_new: true) { post.save! }
      rescue Facet::Orm::Store::UniqueConstraintViolation
        retry if attempt < MAX_SLUG_ATTEMPTS
        post.errors.add(:slug, "could not be made unique after #{MAX_SLUG_ATTEMPTS} attempts")
      end
      post
    end

    def reserved_slugs
      @reserved_slugs ||= Blog.router.routes.filter_map do |route|
        match = route.pattern.match(%r{\A/posts/([^:/][^/]*)\z})
        match && match[1]
      end.uniq
    end

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

  after_commit(on: :create) { NotificationMailer.new_post(id).deliver_later }

  def to_param
    slug
  end

  def giveaway?
    !giveaway_slots.nil?
  end

  def giveaway_remaining
    return nil unless giveaway?
    [giveaway_slots - claims_count, 0].max
  end

  def giveaway_sold_out?
    giveaway? && giveaway_remaining.zero?
  end

  private

  def remove_cover_file
    return if soft_deleting?
    return unless cover && !cover.empty?
    path = File.join(APP_ROOT, 'public', 'uploads', cover)
    File.delete(path) if File.exist?(path)
  end
end
