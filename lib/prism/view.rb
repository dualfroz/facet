module Prism
  class View
    class TemplateNotFound < StandardError; end

    def initialize(roots, helpers: nil)
      @roots = Array(roots)
      @helpers = helpers
      @namespace_stack = []
    end

    def render(name, locals: {}, layout: nil)
      @content_store = {}
      content = render_template(name.to_s, locals)
      return content unless layout
      render_template("layouts/#{layout}", locals.merge('content' => content))
    end

    # content_for(:slot) { ... } inside the content template accumulates
    # here; the layout template rendered right after reads it back with a
    # plain content_for(:slot) call. Reset once per top-level #render so
    # slots don't leak between unrelated requests that reuse this View.
    def content_for(name)
      (@content_store ||= {})[name.to_sym].to_s
    end

    def append_content_for(name, text)
      store = (@content_store ||= {})
      store[name.to_sym] = "#{store[name.to_sym]}#{text}"
    end

    def content_for?(name)
      !(@content_store ||= {})[name.to_sym].to_s.empty?
    end

    # Turns a fragment-cache key argument into a single cache key string.
    # Arrays let callers mix static scope names with model instances, e.g.
    # `cache [:sidebar, current_user, post]`; anything responding to
    # #cache_key (Orm::Model) contributes its own key, everything else is
    # stringified as-is.
    def expand_cache_key(key)
      Array(key).map { |part| part.respond_to?(:cache_key) ? part.cache_key : part.to_s }.join('/')
    end

    def render_partial(name, locals: {})
      render_template(partial_name(qualify(name)), locals)
    end

    def render_collection(name, collection, locals: {}, as: nil)
      local_name = (as || Inflector.underscore(name.to_s.split('/').last)).to_s
      collection.each_with_index.map do |item, index|
        render_partial(name, locals: locals.merge(local_name => item, "#{local_name}_counter" => index + 1))
      end.join
    end

    def resolve(name)
      @roots.each do |root|
        path = File.join(root, "#{name}.erb")
        return path if File.file?(path)
      end
      raise TemplateNotFound, "no template #{name.inspect} in #{@roots.join(', ')}"
    end

    private

    def render_template(name, locals)
      Instrumentation.instrument('render_template.prism', identifier: name) do
        source = File.read(resolve(name))
        @namespace_stack.push(File.dirname(name))
        Template.render(source, locals, self, @helpers)
      end
    ensure
      @namespace_stack.pop
    end

    def qualify(name)
      text = name.to_s
      return text if text.include?('/')
      namespace = @namespace_stack.last
      namespace && namespace != '.' ? File.join(namespace, text) : text
    end

    def partial_name(path)
      directory, base = File.split(path)
      directory == '.' ? "_#{base}" : File.join(directory, "_#{base}")
    end
  end
end
