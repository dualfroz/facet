class NotificationMailerPreview < Prism::Mailer::Preview
  def new_post
    post = Post.first || Post.create_with_unique_slug(title: 'Preview Post', body: 'Fixture body for mailer previews.')
    NotificationMailer.new_post(post.id)
  end

  def welcome
    user = User.first || User.create!(email: 'preview@example.com', password: 'preview passphrase',
                                       password_confirmation: 'preview passphrase')
    NotificationMailer.welcome(user.id)
  end

  def password_reset
    user = User.first || User.create!(email: 'preview@example.com', password: 'preview passphrase',
                                       password_confirmation: 'preview passphrase')
    NotificationMailer.password_reset(user.id, user.generate_token_for(:password_reset))
  end

  def confirmation_instructions
    user = User.first || User.create!(email: 'preview@example.com', password: 'preview passphrase',
                                       password_confirmation: 'preview passphrase')
    NotificationMailer.confirmation_instructions(user.id, user.generate_token_for(:email_confirmation))
  end
end
