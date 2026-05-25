module Prism
  module Template
    module_function

    def render(source, locals = {}, view = nil)
      code = compile(source)
      scope = Context.new(view).__binding
      locals.each { |name, value| scope.local_variable_set(name.to_sym, value) }
      scope.eval(code, '(prism template)')
    end

    def compile(source)
      buffer = +"__out = +''\n"
      source.split(/(<%.*?%>)/m).each do |chunk|
        if chunk.start_with?('<%==')
          buffer << "__out << (#{chunk[4...-2]}).to_s\n"
        elsif chunk.start_with?('<%=')
          buffer << "__out << escape_html((#{chunk[3...-2]}).to_s)\n"
        elsif chunk.start_with?('<%')
          buffer << "#{chunk[2...-2]}\n"
        else
          buffer << "__out << #{chunk.inspect}\n"
        end
      end
      buffer << "__out\n"
      buffer
    end

    class Context
      def initialize(view = nil)
        @view = view
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

      def __binding
        binding
      end
    end
  end
end
