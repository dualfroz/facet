module Prism
  module Template
    module_function

    def render(source, locals = {}, view = nil, helpers = nil)
      code = compile(source)
      scope = Context.new(view, helpers).__binding
      locals.each { |name, value| scope.local_variable_set(name.to_sym, value) }
      scope.eval(code, '(prism template)')
    end

    def compile(source)
      buffer = +"@__out = +''\n"
      source.split(/(<%.*?%>)/m).each do |chunk|
        if chunk.start_with?('<%==')
          buffer << "@__out << (#{chunk[4...-2]}).to_s\n"
        elsif chunk.start_with?('<%=')
          buffer << "@__out << escape_html((#{chunk[3...-2]}).to_s)\n"
        elsif chunk.start_with?('<%')
          buffer << "#{chunk[2...-2]}\n"
        else
          buffer << "@__out << #{chunk.inspect}\n"
        end
      end
      buffer << "@__out\n"
      buffer
    end

    # Rendering context for compiled templates. Block-taking view helpers
    # (form_for, content_tag with a block, ...) are invoked from a plain
    # `<% %>` tag, so they append their own markup to @__out directly
    # instead of returning a string; `capture` lets them do that safely by
    # temporarily swapping the buffer so nested `<%=`/`<%==` output lands
    # in the captured fragment rather than the surrounding page.
    class Context
      def initialize(view = nil, helpers = nil)
        @view = view
        @helpers = helpers
      end

      def escape_html(text)
        CGI.escapeHTML(text)
      end
      alias_method :h, :escape_html

      def partial(name, locals: {})
        raise 'no view attached to this template' unless @view
        @view.render_partial(name, locals: locals)
      end

      def render_collection(name, collection, locals: {}, as: nil)
        raise 'no view attached to this template' unless @view
        @view.render_collection(name, collection, locals: locals, as: as)
      end

      def capture
        previous = @__out
        @__out = +''
        yield
        @__out
      ensure
        @__out = previous
      end

      def method_missing(name, *args, **kwargs, &block)
        return @helpers.public_send(name, *args, **kwargs, &block) if @helpers&.respond_to?(name)
        super
      end

      def respond_to_missing?(name, include_private = false)
        (@helpers && @helpers.respond_to?(name, include_private)) || super
      end

      def __binding
        binding
      end
    end
  end
end
