require 'minitest/autorun'
require 'prism'
require 'support'

class ArticlesController < Prism::Controller
  def index = html('articles-index')
  def show = html("article-#{params['id']}")

  def publish
    html("published-#{params['id']}")
  end

  def archive
    html('archived-collection')
  end
end

class RemarksController < Prism::Controller
  def index = html("remarks-for-article-#{params['article_id']}")
  def show = html("remark-#{params['id']}-on-article-#{params['article_id']}")
end

class AccountController < Prism::Controller
  def show
    respond_to do |format|
      format.html { html('the-account') }
      format.json { json(kind: 'account') }
    end
  end

  def edit = html('edit-the-account')
end

class PreferencesController < Prism::Controller
  def index = html('preferences-for-account')
end

class NestedResourcesApp < Prism::Application
  resources :articles do
    member do
      patch :publish
    end
    collection do
      get :archive
    end
    resources :remarks
  end

  resource :account do
    resources :preferences, only: [:index]
  end
end

class ResourcesAdvancedTest < Minitest::Test
  include TestSupport

  def call(method, path, **opts)
    NestedResourcesApp.call(env_for(method, path, **opts))
  end

  def test_member_route_is_scoped_under_the_resource_id
    status, _, body = call('PATCH', '/articles/9/publish')
    assert_equal 200, status
    assert_equal 'published-9', body.join
  end

  def test_member_route_gets_a_rails_style_default_name
    assert_equal '/articles/9/publish', NestedResourcesApp.router.path_to(:publish_article, id: 9)
  end

  def test_collection_route_is_scoped_under_the_resource_without_an_id
    status, _, body = call('GET', '/articles/archive')
    assert_equal 200, status
    assert_equal 'archived-collection', body.join
  end

  def test_collection_route_gets_a_rails_style_default_name
    assert_equal '/articles/archive', NestedResourcesApp.router.path_to(:archive_articles)
  end

  def test_nested_resource_index_is_scoped_under_the_parent_id
    status, _, body = call('GET', '/articles/3/remarks')
    assert_equal 200, status
    assert_equal 'remarks-for-article-3', body.join
  end

  def test_nested_resource_show_receives_both_ids
    status, _, body = call('GET', '/articles/3/remarks/5')
    assert_equal 200, status
    assert_equal 'remark-5-on-article-3', body.join
  end

  def test_singular_resource_has_no_id_segment
    status, _, body = call('GET', '/account')
    assert_equal 200, status
    assert_equal 'the-account', body.join
  end

  def test_singular_resource_edit_path
    status, _, body = call('GET', '/account/edit')
    assert_equal 200, status
    assert_equal 'edit-the-account', body.join
  end

  def test_resources_nested_under_a_singular_resource
    status, _, body = call('GET', '/account/preferences')
    assert_equal 200, status
    assert_equal 'preferences-for-account', body.join
  end

  # `resource` used to build its routes without `format: true`, unlike
  # `resources` - a singular resource such as this one could only ever be
  # reached as JSON through Accept-header negotiation, never through the
  # explicit ".json" extension every plural resource already supports.
  def test_singular_resource_supports_the_json_extension
    status, headers, body = call('GET', '/account.json')
    assert_equal 200, status
    assert_equal 'application/json', headers['Content-Type']
    assert_equal({ 'kind' => 'account' }, JSON.parse(body.join))
  end

  def test_member_and_collection_require_an_id_param_and_reject_singular_resources
    error = assert_raises(ArgumentError) do
      Class.new(Prism::Application) do
        resource :account do
          member { get :foo }
        end
      end
    end
    assert_match(/singular resource/, error.message)
  end
end
