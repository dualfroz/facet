module Prism
  class View
    class TemplateNotFound < StandardError; end

    def initialize(roots)
      @roots = Array(roots)
      @namespace_stack = []
    end

    def render(name, locals: {}, layout: nil)
      content = render_template(name.to_s, locals)
      return content unless layout
      render_template("layouts/#{layout}", locals.merge('content' => content))
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
      source = File.read(resolve(name))
      @namespace_stack.push(File.dirname(name))
      Template.render(source, locals, self)
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
