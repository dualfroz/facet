class NotificationMailer < Facet::Mailer::Base
  self.template_roots = [File.join(APP_ROOT, 'app', 'views', 'mailers')]
  default from: 'blog@facet.example'

  def new_post(post_id)
    @post = Post.find(post_id)
    @post_url = "/posts/#{@post.to_param}"
    mail(to: 'editors@facet.example', subject: "New post: #{@post.title}")
  end

  def welcome(user_id)
    @user = User.find(user_id)
    mail(to: @user.email, subject: 'Welcome to Facet Blog')
  end

  def password_reset(user_id, token)
    @user = User.find(user_id)
    @reset_url = url_for(:edit_password_reset, token: token)
    mail(to: @user.email, subject: 'Reset your Facet Blog password')
  end

  def confirmation_instructions(user_id, token)
    @user = User.find(user_id)
    @confirmation_url = url_for(:email_confirmation, token: token)
    mail(to: @user.email, subject: 'Confirm your Facet Blog email address')
  end
end
