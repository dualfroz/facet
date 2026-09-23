module Facet
  module Orm
    module Validatable
      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        def validators
          @validators ||= []
        end

        def custom_validators
          @custom_validators ||= []
        end

        def validates(*attributes, **rules)
          attributes.each do |attribute|
            rules.each { |kind, config| validators << { attribute: attribute, kind: kind, config: config } }
          end
        end

        def validates_numericality_of(*attributes, **options)
          validates(*attributes, numericality: options)
        end

        def validates_inclusion_of(*attributes, **options)
          validates(*attributes, inclusion: options)
        end

        def validates_exclusion_of(*attributes, **options)
          validates(*attributes, exclusion: options)
        end

        def validate(method_name = nil, &block)
          custom_validators << (method_name || block)
        end
      end

      def errors
        @errors ||= Errors.new
      end

      def valid?
        errors.clear
        return false unless run_callbacks(:before_validation)
        self.class.validators.each { |validator| run_validator(validator) }
        self.class.custom_validators.each { |validator| run_custom_validator(validator) }
        run_callbacks(:after_validation)
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
        when :numericality then validate_numericality(validator[:attribute], validator[:config])
        when :inclusion then validate_inclusion(validator[:attribute], validator[:config])
        when :exclusion then validate_exclusion(validator[:attribute], validator[:config])
        else raise ArgumentError, "unknown validator #{validator[:kind]}"
        end
      end

      def run_custom_validator(validator)
        validator.is_a?(Proc) ? instance_exec(&validator) : send(validator)
      end

      def validate_presence(attribute, config)
        return unless config
        value = public_send(attribute)
        return unless value.nil? || (value.respond_to?(:empty?) && value.empty?)
        errors.add(attribute, message_for(config, 'must be present'))
      end

      def validate_uniqueness(attribute, config)
        return unless config
        value = public_send(attribute)
        return if value.nil?
        scope = config.is_a?(Hash) ? Array(config[:scope]) : []
        candidates = scope.inject(self.class.where(attribute => value)) do |relation, scope_attribute|
          relation.where(scope_attribute => public_send(scope_attribute))
        end
        conflict = candidates.any? { |record| !persisted? || record.id != id }
        errors.add(attribute, message_for(config, 'must be unique')) if conflict
      end

      def validate_format(attribute, config)
        pattern = config.is_a?(Hash) ? config[:with] : config
        return unless pattern
        value = public_send(attribute)
        return if value.nil?
        return if value.to_s.match?(pattern)
        errors.add(attribute, message_for(config, 'is invalid'))
      end

      def validate_length(attribute, config)
        value = public_send(attribute).to_s
        errors.add(attribute, "is too short (minimum #{config[:minimum]})") if config[:minimum] && value.length < config[:minimum]
        errors.add(attribute, "is too long (maximum #{config[:maximum]})") if config[:maximum] && value.length > config[:maximum]
      end

      NUMERICALITY_CHECKS = {
        greater_than: ->(n, v) { n > v },
        greater_than_or_equal_to: ->(n, v) { n >= v },
        less_than: ->(n, v) { n < v },
        less_than_or_equal_to: ->(n, v) { n <= v },
        equal_to: ->(n, v) { n == v },
        other_than: ->(n, v) { n != v }
      }.freeze

      def validate_numericality(attribute, config)
        config = config.is_a?(Hash) ? config : {}
        value = public_send(attribute)
        return if value.nil? && config[:allow_nil]

        number = coerce_number(value)
        return errors.add(attribute, message_for(config, 'is not a number')) if number.nil?

        if config[:only_integer] && number != number.to_i
          return errors.add(attribute, message_for(config, 'must be an integer'))
        end

        NUMERICALITY_CHECKS.each do |key, check|
          next unless config.key?(key)
          next if check.call(number, config[key])
          errors.add(attribute, message_for(config, "must be #{key.to_s.tr('_', ' ')} #{config[key]}"))
        end

        errors.add(attribute, message_for(config, 'must be odd')) if config[:odd] && number.to_i.even?
        errors.add(attribute, message_for(config, 'must be even')) if config[:even] && number.to_i.odd?
      end

      def coerce_number(value)
        return value if value.is_a?(Numeric)
        return nil if value.nil?

        Float(value.to_s)
      rescue ArgumentError, TypeError
        nil
      end

      def validate_inclusion(attribute, config)
        config = config.is_a?(Hash) ? config : { in: config }
        value = public_send(attribute)
        return if value.nil? && config[:allow_nil]
        set = config[:in] || config[:within]
        errors.add(attribute, message_for(config, 'is not included in the list')) unless set.include?(value)
      end

      def validate_exclusion(attribute, config)
        config = config.is_a?(Hash) ? config : { in: config }
        value = public_send(attribute)
        return if value.nil? && config[:allow_nil]
        set = config[:in] || config[:within]
        errors.add(attribute, message_for(config, 'is reserved')) if set.include?(value)
      end

      def message_for(config, default)
        config.is_a?(Hash) && config[:message] ? config[:message] : default
      end
    end
  end
end
