module Facet
  module Testing
    module IntegrationTest
      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        def integration_app(app = nil)
          @integration_app = app unless app.nil?
          @integration_app || (superclass.respond_to?(:integration_app) ? superclass.integration_app : nil)
        end

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

      def run
        configured = self.class.transactional_tests_stores
        return super unless configured

        stores = configured.map { |s| s == :default ? Facet::Orm.store : s }
        result = nil
        wrap_transactional_stores(stores) { result = super }
        result
      end

      def wrap_transactional_stores(stores, &body)
        return body.call if stores.empty?

        head, *tail = stores
        head.transaction_with_callbacks do
          wrap_transactional_stores(tail, &body)
          raise Facet::Orm::Rollback
        end
      end
      private :wrap_transactional_stores

      def session
        @facet_integration_session ||= IntegrationSession.new(app)
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
