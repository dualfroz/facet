# Loaded by `bin/prism db:seed --require=app.rb` (see Prism::Cli#db_seed) -
# fills a freshly migrated development.pstore with enough data to click
# around the app without signing up and writing posts by hand first.
#
# Every record below is looked up by its natural key before being created,
# so running this file twice (a fresh checkout re-seeding, a developer
# re-running the command out of habit) is a no-op the second time rather
# than piling up duplicate rows or tripping the unique index on
# users.email - db:seed itself does not enforce that, it is a property of
# this file, same division of responsibility Rails draws around db/seeds.rb.

seed_users = [
  { email: 'writer@example.com', password: 'seed-password-1' },
  { email: 'reader@example.com', password: 'seed-password-2' }
].map do |attrs|
  User.find_by(email: attrs[:email]) || User.create!(attrs)
end
author, commenter = seed_users

seed_posts = [
  { title: 'Welcome to the blog', body: 'This is the first seeded post - edit or delete it freely.',
    status: :published },
  { title: 'A second seeded post', body: 'Seeded posts exist so the index page is never empty on a fresh clone.',
    status: :published },
  { title: 'An unpublished draft', body: 'Still a draft - only visible on the author\'s own dashboard.',
    status: :draft }
].map do |attrs|
  Post.find_by(title: attrs[:title]) || Post.create_with_unique_slug(attrs.merge(user_id: author.id))
end

published_posts = seed_posts.select(&:published?)
published_posts.each do |post|
  next if post.comments.any?
  Comment.create!(post_id: post.id, user_id: commenter.id, author: commenter.email,
                   body: "Nice post, #{post.title.downcase}!", status: :approved)
end

puts "[seeds] users=#{User.count} posts=#{Post.count} comments=#{Comment.count}"
