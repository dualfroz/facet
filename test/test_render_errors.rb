require 'minitest/autorun'
require 'prism'
require 'tmpdir'
require 'support'

class RenderErrorsGadget < Prism::Orm::Model
  table_name :gadgets
  validates :name, presence: true, length: { minimum: 3 }
end

class GadgetsController < Prism::Controller
  def create
    gadget = RenderErrorsGadget.new(name: params['name'])

    if gadget.save
      respond_to do |format|
        format.json { json(id: gadget.id, name: gadget.name) }
      end
    else
      respond_to do |format|
        format.json { render_errors(gadget) }
      end
    end
  end

  def show
    gadget = RenderErrorsGadget.find(params['id'])
    respond_to do |format|
      format.json { json(id: gadget.id, name: gadget.name) }
    end
  rescue Prism::Orm::RecordNotFound
    respond_to do |format|
      format.json { render_not_found('gadget not found') }
    end
  end
end

class GadgetsApp < Prism::Application
  post '/gadgets', to: 'gadgets#create'
  get '/gadgets/:id', to: 'gadgets#show'
end

class RenderErrorsTest < Minitest::Test
  include TestSupport

  def setup
    @dir = Dir.mktmpdir('prism-render-errors-store')
    store = Prism::Orm::Store.new(File.join(@dir, 'test.pstore'))
    store.create_table(:gadgets, %w[id name])
    RenderErrorsGadget.store = store
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def call(method, path, form: {}, **opts)
    body = form.map { |k, v| "#{k}=#{v}" }.join('&')
    headers = { 'Content-Type' => 'application/x-www-form-urlencoded', 'Accept' => 'application/json' }.merge(opts.delete(:headers) || {})
    GadgetsApp.call(env_for(method, path, body: body, headers: headers, **opts))
  end

  def test_valid_record_responds_with_201_style_json_payload
    status, headers, body = call('POST', '/gadgets', form: { name: 'wrench' })
    assert_equal 200, status
    assert_equal 'application/json', headers['Content-Type']
    payload = JSON.parse(body.join)
    assert_equal 'wrench', payload['name']
  end

  def test_invalid_record_responds_with_422_and_jsonapi_error_array
    status, headers, body = call('POST', '/gadgets', form: { name: '' })
    assert_equal 422, status
    assert_equal 'application/json', headers['Content-Type']

    payload = JSON.parse(body.join)
    errors = payload['errors']
    refute_nil errors
    assert(errors.any? { |e| e['source']['pointer'] == '/data/attributes/name' })
    assert(errors.all? { |e| e['status'] == '422' })
  end

  def test_missing_record_responds_with_404_and_jsonapi_error_object
    status, headers, body = call('GET', '/gadgets/999999')
    assert_equal 404, status
    assert_equal 'application/json', headers['Content-Type']

    payload = JSON.parse(body.join)
    errors = payload['errors']
    refute_nil errors
    assert_equal 1, errors.size
    assert_equal '404', errors.first['status']
    assert_nil errors.first['source']
    assert_equal 'gadget not found', errors.first['detail']
  end
end
