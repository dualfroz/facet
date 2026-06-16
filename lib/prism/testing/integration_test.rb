module Prism
  module Testing
    # Mixin for Minitest::Test subclasses that exercises a full request
    # cycle (router -> middleware -> controller -> view) without a real
    # socket, the way ActionDispatch::IntegrationTest does in Rails.
    # Deliberately does NOT require 'minitest' itself: it only calls
    # #assert, which the including class already has from
    # Minitest::Test/Minitest::Assertions.
    #
    #   class SignupFlowTest < Minitest::Test
    #     include Prism::Testing::IntegrationTest
    #     integration_app MyApp
    #
    #     def test_signup_then_authenticated_page
    #       get '/signup'
    #       post '/users', params: { user: { email: 'a@b.com', password: 'secret123' } }
    #       assert_response :redirect
    #       follow_redirect!
    #       assert_response :success
    #     end
    #   end
    module IntegrationTest
      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        def integration_app(app = nil)
          @integration_app = app unless app.nil?
          @integration_app || (superclass.respond_to?(:integration_app) ? superclass.integration_app : nil)
        end

        # Opts this test class into Rails-style "transactional fixtures":
        # every test method (setup, body, and teardown together) runs
        # inside one `Orm::Store` transaction that is unconditionally
        # rolled back once the method finishes, pass or fail, so writes
        # made by one test never leak into the next - no truncating or
        # reseeding tables between tests. Defaults to `Prism::Orm.store`;
        # pass `store:` for a test suite that connects a different one, or
        # `stores:` (an array) when a single test method writes through more
        # than one independent `Store` (e.g. the app's main store and a
        # separate jobs queue store) and both need to unwind together.
        def use_transactional_tests(store: :default, stores: nil)
          @transactional_tests_stores = stores ? Array(stores) : [store]
        end

        def transactional_tests_stores
          @transactional_tests_stores ||
            (superclass.respond_to?(:transactional_tests_stores) ? superclass.transactional_tests_stores : nil)
        end

        def transactional_tests_store
          transactional_tests_stores&.first
        end
      end

      def app
        self.class.integration_app
      end

      # Overrides Minitest::Test#run only when `use_transactional_tests`
      # was declared; otherwise defers straight to `super` so every
      # existing test class (which never calls it) behaves exactly as
      # before. `super` inside the innermost block still refers to
      # Minitest::Test#run - Ruby resolves it from the method's lexical
      # scope, not the block's, even though that block is handed to
      # #wrap_transactional_stores and only actually invoked several stack
      # frames away - so setup/the test method/teardown run exactly once,
      # nested inside every configured store's transaction.
      def run
        configured = self.class.transactional_tests_stores
        return super unless configured

        stores = configured.map { |s| s == :default ? Prism::Orm.store : s }
        result = nil
        wrap_transactional_stores(stores) { result = super }
        result
      end

      # Each store gets its OWN `TransactionRegistry`, and that registry's
      # #within rescues Prism::Orm::Rollback itself rather than re-raising
      # it - so a single `raise Rollback` deep inside a chain of nested
      # `store.transaction_with_callbacks` calls only ever unwinds the
      # INNERMOST store; every store around it would see its block return
      # normally and commit for real. Naively reusing the single-store
      # "run the body, then raise Rollback" shape here would roll back only
      # the last configured store. Instead each recursion level opens its
      # own store's transaction, recurses to run everything inside it
      # (ultimately reaching `body` exactly once at the bottom), and THEN
      # raises its OWN Rollback once that unwinds back to it - so every
      # store gets an explicit rollback signal at its own nesting level.
      # First store in the list ends up outermost.
      def wrap_transactional_stores(stores, &body)
        return body.call if stores.empty?

        head, *tail = stores
        head.transaction_with_callbacks do
          wrap_transactional_stores(tail, &body)
          raise Prism::Orm::Rollback
        end
      end
      private :wrap_transactional_stores

      def session
        @prism_integration_session ||= IntegrationSession.new(app)
      end

      def get(path, params: nil, headers: {}, remote_addr: '127.0.0.1')
        session.get(path, params: params, headers: headers, remote_addr: remote_addr)
      end

      def head(path, params: nil, headers: {}, remote_addr: '127.0.0.1')
        session.head(path, params: params, headers: headers, remote_addr: remote_addr)
      end

      def post(path, params: nil, headers: {}, remote_addr: '127.0.0.1')
        session.post(path, params: params, headers: headers, remote_addr: remote_addr)
      end

      def patch(path, params: nil, headers: {}, remote_addr: '127.0.0.1')
        session.patch(path, params: params, headers: headers, remote_addr: remote_addr)
      end

      def put(path, params: nil, headers: {}, remote_addr: '127.0.0.1')
        session.put(path, params: params, headers: headers, remote_addr: remote_addr)
      end

      def delete(path, params: nil, headers: {}, remote_addr: '127.0.0.1')
        session.delete(path, params: params, headers: headers, remote_addr: remote_addr)
      end

      def follow_redirect!
        session.follow_redirect!
      end

      def response
        session.response
      end

      def cookies
        session.cookies
      end

      def assert_response(expected)
        actual = response.status
        assert(response_matches?(expected, actual),
               "expected response #{expected.inspect}, got #{actual} (body: #{response.body})")
      end

      def assert_redirected_to(path)
        assert_response(:redirect)
        location = response.location
        assert(location && location.end_with?(path.to_s),
               "expected redirect to #{path.inspect}, got #{location.inspect}")
      end

      private

      def response_matches?(expected, actual)
        case expected
        when Integer then actual == expected
        when :success, :ok then (200..299).cover?(actual)
        when :redirect then (300..399).cover?(actual)
        when :missing, :not_found then actual == 404
        when :unprocessable then actual == 422
        when :forbidden then actual == 403
        when :unauthorized then actual == 401
        when :too_many_requests then actual == 429
        when :client_error then (400..499).cover?(actual)
        when :server_error then (500..599).cover?(actual)
        else raise ArgumentError, "unknown expected response: #{expected.inspect}"
        end
      end
    end
  end
end
