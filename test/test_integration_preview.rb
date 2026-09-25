require 'minitest/autorun'
require 'facet'
require 'tmpdir'

module PreviewFixtures
  DIR = Dir.mktmpdir('facet-preview-integration')
  STORE = Facet::Orm::Store.new(File.join(DIR, 'test.pstore'))
  STORE.create_table(:preview_posts, %w[id title body lock_version])

  class PreviewPost < Facet::Orm::Model
    self.store = STORE
    table_name :preview_posts
    validates :title, presence: true
  end

  class PreviewApp < Facet::Application
    get('/posts/:id') do
      post = PreviewPost.find(params['id'])
      json(id: post.id, title: post.title, body: post.body, lock_version: post.lock_version)
    end

    patch('/posts/:id/preview') do
      post = PreviewPost.find(params['id'])
      attempted = params.require('post').permit(:title, :body, :lock_version).to_h
      post.assign(attempted)
      post.valid?
      diff = post.changes.reject { |field, _| field == 'lock_version' }
      errors = post.errors.full_messages
      post.restore_attributes
      json(diff: diff, errors: errors, current_title: post.title, current_body: post.body)
    end

    patch('/posts/:id') do
      post = PreviewPost.find(params['id'])
      post.assign(params.require('post').permit(:title, :body, :lock_version).to_h)
      begin
        post.save!
        json(id: post.id, title: post.title, lock_version: post.lock_version)
      rescue Facet::Orm::StaleObjectError
        halt(409, 'stale object')
      end
    end
  end
end

class IntegrationPreviewTest < Minitest::Test
  include Facet::Testing::IntegrationTest
  integration_app PreviewFixtures::PreviewApp
  use_transactional_tests(store: PreviewFixtures::STORE)

  def test_preview_returns_a_diff_without_persisting_the_change
    post = PreviewFixtures::PreviewPost.create!(title: 'Original title', body: 'original body')

    patch("/posts/#{post.id}/preview", params: { post: { title: 'Proposed title', body: 'original body' } })
    assert_response :success
    body = response.json
    assert_equal ['Original title', 'Proposed title'], body.dig('diff', 'title')
    assert_empty body['errors']
    assert_equal 'Original title', body['current_title'], 'the response must show the record as still unsaved'

    get("/posts/#{post.id}")
    assert_equal 'Original title', response.json['title'], 'the store itself must be untouched by the preview'
  end

  def test_preview_reports_validation_errors_without_persisting_anything
    post = PreviewFixtures::PreviewPost.create!(title: 'Keep me', body: 'keep me too')

    patch("/posts/#{post.id}/preview", params: { post: { title: '', body: 'still keep me too' } })
    assert_response :success
    body = response.json
    refute_empty body['errors']
    assert_equal 'Keep me', body['current_title']

    get("/posts/#{post.id}")
    assert_equal 'Keep me', response.json['title']
  end

  def test_preview_is_unaffected_by_a_stale_lock_version_because_it_never_saves
    post = PreviewFixtures::PreviewPost.create!(title: 'Racing edit', body: 'body')
    stale_lock_version = post.lock_version
    post.update!(body: 'a concurrent edit landed first')
    refute_equal stale_lock_version, post.lock_version

    patch("/posts/#{post.id}/preview",
          params: { post: { title: 'Whatever I typed', body: 'body', lock_version: stale_lock_version } })
    assert_response :success
    assert_equal 'a concurrent edit landed first', response.json['current_body']
  end

  def test_real_update_with_a_stale_lock_version_is_rejected_with_409
    post = PreviewFixtures::PreviewPost.create!(title: 'Racing edit', body: 'body')
    stale_lock_version = post.lock_version
    post.update!(body: 'a concurrent edit landed first')

    patch("/posts/#{post.id}", params: { post: { title: 'Racing edit', body: 'my edit', lock_version: stale_lock_version } })
    assert_response 409

    get("/posts/#{post.id}")
    assert_equal 'a concurrent edit landed first', response.json['body'],
                 'the losing, stale update must never have been applied'
  end

  def test_real_update_with_a_fresh_lock_version_succeeds
    post = PreviewFixtures::PreviewPost.create!(title: 'Racing edit', body: 'body')

    patch("/posts/#{post.id}", params: { post: { title: 'Racing edit', body: 'my edit', lock_version: post.lock_version } })
    assert_response :success
    assert_equal 1, response.json['lock_version']
  end
end
