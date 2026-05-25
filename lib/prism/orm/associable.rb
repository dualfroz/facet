module Prism
  module Orm
    module Associable
      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        def associations
          @associations ||= {}
        end

        def belongs_to(name, class_name: nil, foreign_key: nil)
          target = class_name || Inflector.camelize(name.to_s)
          key = (foreign_key || "#{name}_id").to_s
          associations[name.to_sym] = { type: :belongs_to, class_name: target, foreign_key: key }

          define_method(name) do
            value = self[key]
            next nil if value.nil?
            @association_cache ||= {}
            @association_cache[name] ||= Object.const_get(target).find(value)
          end

          define_method("#{name}=") do |record|
            self[key] = record&.id
            @association_cache ||= {}
            @association_cache[name] = record
          end
        end

        def has_many(name, class_name: nil, foreign_key: nil)
          target = class_name || Inflector.classify(name.to_s)
          key = (foreign_key || "#{Inflector.underscore(self.name)}_id").to_s
          associations[name.to_sym] = { type: :has_many, class_name: target, foreign_key: key }

          define_method(name) do
            Object.const_get(target).where(key => id)
          end
        end
      end
    end
  end
end
