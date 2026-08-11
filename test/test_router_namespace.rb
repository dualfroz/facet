require 'minitest/autorun'
require 'prism'
require 'support'

module Admin
  class DashboardController < Prism::Controller
    def index
      html('admin dashboard')
    end
  end

  class WidgetsController < Prism::Controller
    def index
      html('admin widgets index')
    end

    def show
      html("admin widget #{params['id']}")
    end
  end

  class GadgetsController < Prism::Controller
    def index
      html('admin gadgets under widget ' + params['widget_id'])
    end
  end

  # Lives directly under Admin (not Admin::LegacyUi) - proves that
  # `module: false` on an INNER namespace only skips its own module
  # contribution, while the enclosing `admin` module still applies.
  class ArchivedController < Prism::Controller
    def index
      html('admin archived (legacy_ui contributed no module)')
    end
  end

  # Registered AFTER the `legacy_ui, module: false` block closes (see
  # NamespacedApp below) - only resolves correctly if closing that block
  # popped exactly its own frame off module_stack, leaving ["admin"]
  # behind for this route instead of popping "admin" too.
  class AuditsController < Prism::Controller
    def index
      html('admin audits after legacy_ui closed')
    end
  end
end

module Api
  module V1
    class ReportsController < Prism::Controller
      def index
        html('api v1 reports')
      end
    end
  end
end

module Legacy
  class DashboardController < Prism::Controller
    def index
      html('legacy ping')
    end
  end
end

# Deliberately NOT inside a `Settings` module - this is exactly what
# `module: false` is for: a URL that looks namespaced without forcing the
# controller into a matching Ruby module/directory.
class ProfilesController < Prism::Controller
  def show
    html("moduleless profile #{params['id']}")
  end
end

class NamespacedApp < Prism::Application
  namespace :admin do
    root to: 'dashboard#index'
    resources :widgets do
      resources :gadgets, only: [:index]
    end

    namespace :legacy_ui, module: false do
      resources :archived, only: [:index]
    end

    resources :audits, only: [:index]
  end

  namespace :api do
    namespace :v1 do
      resources :reports, only: [:index]
    end
  end

  namespace :legacy, path: '/old' do
    get '/ping', to: 'dashboard#index', as: :ping
  end

  namespace :settings, module: false do
    resources :profiles, only: [:show]
  end
end

class RouterNamespaceTest < Minitest::Test
  include TestSupport

  def call(method, path, **opts)
    NamespacedApp.call(env_for(method, path, **opts))
  end

  def test_namespaced_root_dispatches_to_nested_module_controller
    status, _, body = call('GET', '/admin/')
    assert_equal 200, status
    assert_equal 'admin dashboard', body.join
  end

  def test_namespaced_resources_dispatch_to_nested_module_controller
    status, _, body = call('GET', '/admin/widgets')
    assert_equal 200, status
    assert_equal 'admin widgets index', body.join

    _, _, body = call('GET', '/admin/widgets/7')
    assert_equal 'admin widget 7', body.join
  end

  def test_nested_resources_under_namespace_carry_the_parent_id
    _, _, body = call('GET', '/admin/widgets/3/gadgets')
    assert_equal 'admin gadgets under widget 3', body.join
  end

  def test_double_nested_namespace_dispatches_to_double_nested_module
    status, _, body = call('GET', '/api/v1/reports')
    assert_equal 200, status
    assert_equal 'api v1 reports', body.join
  end

  def test_named_routes_are_prefixed_with_the_namespace_name
    assert_equal '/admin/widgets', NamespacedApp.router.path_to(:admin_widgets)
    assert_equal '/admin/widgets/7', NamespacedApp.router.path_to(:admin_widget, id: 7)
    assert_equal '/admin/', NamespacedApp.router.path_to(:admin_root)
  end

  def test_nested_namespace_names_join_with_underscores
    assert_equal '/api/v1/reports', NamespacedApp.router.path_to(:api_v1_reports)
  end

  def test_namespace_accepts_a_custom_path_independent_of_the_name
    status, _, body = call('GET', '/old/ping')
    assert_equal 200, status
    assert_equal 'legacy ping', body.join
    assert_equal '/old/ping', NamespacedApp.router.path_to(:legacy_ping)
  end

  def test_controller_path_keeps_the_full_module_for_view_resolution
    assert_equal 'admin/widgets', Admin::WidgetsController.controller_path
    assert_equal 'api/v1/reports', Api::V1::ReportsController.controller_path
  end

  def test_module_false_keeps_the_url_prefix_but_dispatches_to_a_top_level_controller
    status, _, body = call('GET', '/settings/profiles/9')
    assert_equal 200, status
    assert_equal 'moduleless profile 9', body.join
  end

  def test_module_false_still_prefixes_the_route_name
    assert_equal '/settings/profiles/9', NamespacedApp.router.path_to(:settings_profile, id: 9)
  end

  def test_nested_module_false_keeps_the_enclosing_module_but_skips_its_own
    status, _, body = call('GET', '/admin/legacy_ui/archived')
    assert_equal 200, status
    assert_equal 'admin archived (legacy_ui contributed no module)', body.join
    assert_equal '/admin/legacy_ui/archived', NamespacedApp.router.path_to(:admin_legacy_ui_archived)
  end

  def test_module_false_does_not_leak_into_a_route_declared_after_it_closes
    # Regression guard for the `ensure` block: if `module_stack.pop` ran
    # unconditionally (instead of only `if use_module`) it would pop one
    # frame too many once `legacy_ui`'s block above closes, silently
    # popping "admin" too - this route (declared right after) would then
    # resolve to a top-level AuditsController instead of Admin::Audits.
    status, _, body = call('GET', '/admin/audits')
    assert_equal 200, status
    assert_equal 'admin audits after legacy_ui closed', body.join
  end
end
