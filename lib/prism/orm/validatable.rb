module Prism
  module Orm
    module Validatable
      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        def validators
          @validators ||= []
        end

        def validates(*attributes, **rules)
          attributes.each do |attribute|
            rules.each { |kind, config| validators << { attribute: attribute, kind: kind, config: config } }
          end
        end
      end

      def errors
        @errors ||= Errors.new
      end

      def valid?
        errors.clear
        self.class.validators.each { |validator| run_validator(validator) }
        errors.empty?
      end

      def invalid?
        !valid?
      end

      private

      def run_validator(validator)
        case validator[:kind]
        when :presence then validate_presence(validator[:attribute], validator[:config])
        when :uniqueness then validate_uniqueness(validator[:attribute], validator[:config])
        when :format then validate_format(validator[:attribute], validator[:config])
        when :length then validate_length(validator[:attribute], validator[:config])
        else raise ArgumentError, "unknown validator #{validator[:kind]}"
        end
      end

      def validate_presence(attribute, config)
        return unless config
        value = self[attribute]
        return unless value.nil? || (value.respond_to?(:empty?) && value.empty?)
        errors.add(attribute, message_for(config, 'must be present'))
      end

      def validate_uniqueness(attribute, config)
        return unless config
        value = self[attribute]
        return if value.nil?
        conflict = self.class.where(attribute => value).any? { |record| !persisted? || record.id != id }
        errors.add(attribute, message_for(config, 'must be unique')) if conflict
      end

      def validate_format(attribute, config)
        pattern = config.is_a?(Hash) ? config[:with] : config
        return unless pattern
        value = self[attribute]
        return if value.nil?
        return if value.to_s.match?(pattern)
        errors.add(attribute, message_for(config, 'is invalid'))
      end

      def validate_length(attribute, config)
        value = self[attribute].to_s
        errors.add(attribute, "is too short (minimum #{config[:minimum]})") if config[:minimum] && value.length < config[:minimum]
        errors.add(attribute, "is too long (maximum #{config[:maximum]})") if config[:maximum] && value.length > config[:maximum]
      end

      def message_for(config, default)
        config.is_a?(Hash) && config[:message] ? config[:message] : default
      end
    end
  end
end
