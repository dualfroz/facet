module Prism
  module I18n
    # Resolves a translate/localize call against a Backend: locale fallback
    # chains, %{name} interpolation, and English-style count pluralization
    # (:zero/:one/:other keys, falling back to :other).
    class Translator
      MissingTranslationError = Class.new(StandardError)
      MissingInterpolationError = Class.new(StandardError)

      DEFAULT_TIME_FORMAT = '%Y-%m-%d %H:%M:%S'
      DEFAULT_DATE_FORMAT = '%Y-%m-%d'

      def initialize(backend, default_locale: :en, fallbacks: {})
        @backend = backend
        @default_locale = default_locale.to_sym
        @fallbacks = fallbacks.transform_keys(&:to_sym).transform_values { |chain| Array(chain).map(&:to_sym) }
      end

      def translate(key, locale: @default_locale, count: nil, default: nil, **interpolations)
        entry = resolve(key, locale)
        if entry.nil?
          return interpolate(default, count: count, **interpolations) unless default.nil?
          raise MissingTranslationError, "translation missing: #{locale}.#{key}"
        end
        entry = pluralize(entry, count) if entry.is_a?(Hash) && !count.nil?
        interpolate(entry, count: count, **interpolations)
      end
      alias_method :t, :translate

      def localize(value, locale: @default_locale, format: :default)
        pattern = resolve("#{scope_for(value)}.formats.#{format}", locale) ||
                  default_format_for(value)
        value.strftime(pattern)
      end
      alias_method :l, :localize

      private

      def resolve(key, locale)
        chain_for(locale).each do |candidate|
          value = @backend.lookup(candidate, key)
          return value unless value.nil?
        end
        nil
      end

      def chain_for(locale)
        locale = locale.to_sym
        chain = [locale] + @fallbacks.fetch(locale, [])
        chain << @default_locale unless chain.include?(@default_locale)
        chain.uniq
      end

      def pluralize(rules, count)
        key = plural_key(count, rules)
        rules[key] || rules[:other] || rules.values.first
      end

      def plural_key(count, rules)
        return :zero if count == 0 && rules.key?(:zero)
        return :one if count == 1
        :other
      end

      def interpolate(text, count: nil, **interpolations)
        return text unless text.is_a?(String)
        values = interpolations.dup
        values[:count] = count unless count.nil?
        text.gsub(/%\{(\w+)\}/) do
          key = Regexp.last_match(1).to_sym
          values.fetch(key) { raise MissingInterpolationError, "missing interpolation argument #{key.inspect} for #{text.inspect}" }.to_s
        end
      end

      def scope_for(value)
        value.is_a?(Time) ? 'time' : 'date'
      end

      def default_format_for(value)
        value.is_a?(Time) ? DEFAULT_TIME_FORMAT : DEFAULT_DATE_FORMAT
      end
    end
  end
end
