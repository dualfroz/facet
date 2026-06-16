require 'minitest/autorun'
require 'prism'
require 'support'
require 'tmpdir'

class AuthzArticlePolicy < Prism::Policy
  def destroy?
    user && record.user_id == user.id
  end
end

class AuthzSessionsController < Prism::Controller
  include Prism::Authenticatable
  authenticate_with model: :AuthzUser

  def create
    user = AuthzUser.find_by(email: params['email'])
    if user
      sign_in(user)
      halt(200, 'signed in')
    else
      halt(401, 'invalid credentials')
    end
  end
end

class ArticlesController < Prism::Controller
  include Prism::Authenticatable
  include Prism::Authorizable
  authenticate_with model: :AuthzUser
  before_action :require_authentication, only: %i[destroy]
  rescue_from Prism::Policy::NotAuthorizedError, with: :forbidden

  def destroy
    article = AuthzArticle.find(params['id'])
    authorize(article)
    article.destroy
    halt(200, 'deleted')
  rescue Prism::Orm::RecordNotFound
    halt(404, 'not found')
  end

  private

  def forbidden(_exception)
    halt(403, 'forbidden')
  end
end

class AuthorizableApp < Prism::Application
  enable_sessions(secret: 'authz-secret')
  post '/sign_in', to: 'authz_sessions#create'
  delete '/articles/:id', to: 'articles#destroy'
end

class AuthorizableTest < Minitest::Test
  include TestSupport

  def setup
    @dir = Dir.mktmpdir('prism-authorizable')
    @store = Prism::Orm::Store.new(File.join(@dir, 'test.pstore'))
    @store.create_table(:authz_users, %w[id email])
    @store.create_table(:authz_articles, %w[id title user_id])

    user_class = Class.new(Prism::Orm::Model) { table_name :authz_users }
    user_class.store = @store
    Object.const_set(:AuthzUser, user_class)

    article_class = Class.new(Prism::Orm::Model) { table_name :authz_articles }
    article_class.store = @store
    Object.const_set(:AuthzArticle, article_class)

    @owner = AuthzUser.create!(email: 'owner@example.com')
    @stranger = AuthzUser.create!(email: 'stranger@example.com')
    @article = AuthzArticle.create!(title: 'mine', user_id: @owner.id)
  end

  def teardown
    FileUtils.remove_entry(@dir)
    Object.send(:remove_const, :AuthzUser) if Object.const_defined?(:AuthzUser)
    Object.send(:remove_const, :AuthzArticle) if Object.const_defined?(:AuthzArticle)
  end

  def call(method, path, **opts)
    AuthorizableApp.call(env_for(method, path, **opts))
  end

  def cookie_for(email)
    _, headers, = call('POST', '/sign_in',
                        headers: { 'Content-Type' => 'application/x-www-form-urlencoded' },
                        body: URI.encode_www_form('email' => email))
    lines = headers['Set-Cookie'].split("\n")
    lines.find { |line| line.start_with?('prism.session=') }.split(';').first
  end

  def test_owner_may_destroy_their_own_article
    status, _, body = call('DELETE', "/articles/#{@article.id}", cookies: cookie_for('owner@example.com'))
    assert_equal 200, status
    assert_equal 'deleted', body.join
  end

  def test_stranger_gets_403_instead_of_destroying_someone_elses_article
    status, _, body = call('DELETE', "/articles/#{@article.id}", cookies: cookie_for('stranger@example.com'))
    assert_equal 403, status
    assert_equal 'forbidden', body.join
    assert AuthzArticle.find_by(id: @article.id), 'the article must survive a denied authorization'
  end

  def test_signed_out_request_never_reaches_the_policy_at_all
    status, = call('DELETE', "/articles/#{@article.id}")
    assert_equal 401, status
  end
end
