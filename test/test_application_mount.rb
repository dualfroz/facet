require 'minitest/autorun'
require 'prism'
require 'support'

class EchoMountedApp
  def call(env)
    [200, { 'Content-Type' => 'text/plain' },
     ["script_name=#{env['SCRIPT_NAME']} path_info=#{env['PATH_INFO']}"]]
  end
end

class MountApp < Prism::Application
  mount '/admin', EchoMountedApp.new

  get '/host-route' do
    'host app route'
  end
end

class MountPrecedenceApp < Prism::Application
  mount '/shared', EchoMountedApp.new

  get '/shared' do
    'host app route wins'
  end
end

class ApplicationMountTest < Minitest::Test
  include TestSupport

  def test_mounted_app_receives_rewritten_script_name_and_path_info
    status, _, body = MountApp.call(env_for('GET', '/admin/users/1'))
    assert_equal 200, status
    assert_equal 'script_name=/admin path_info=/users/1', body.join
  end

  def test_mounted_app_receives_root_path_info_at_bare_prefix
    _, _, body = MountApp.call(env_for('GET', '/admin'))
    assert_equal 'script_name=/admin path_info=/', body.join
  end

  def test_host_applications_own_routes_take_precedence_over_mounts
    status, _, body = MountPrecedenceApp.call(env_for('GET', '/shared'))
    assert_equal 200, status
    assert_equal 'host app route wins', body.join
  end

  def test_unmatched_path_outside_any_mount_still_404s
    status, = MountApp.call(env_for('GET', '/nowhere'))
    assert_equal 404, status
  end
end
