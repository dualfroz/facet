require_relative 'i18n/backend'
require_relative 'i18n/translator'

module Facet
  module I18n
    class << self
      def backend
        @backend ||= Backend.new
      end

      def default_locale
        @default_locale ||= :en
      end

      def default_locale=(locale)
        @translator = nil
        @default_locale = locale.to_sym
      end

      def fallbacks
        @fallbacks ||= {}
      end

      def fallbacks=(hash)
        @translator = nil
        @fallbacks = hash
      end

      def locale
        Thread.current[:facet_i18n_locale] || default_locale
      end

      def locale=(new_locale)
        Thread.current[:facet_i18n_locale] = new_locale&.to_sym
      end

      def with_locale(new_locale)
        previous = locale
        self.locale = new_locale
        yield
      ensure
        self.locale = previous
      end

      def load_path
        @load_path ||= []
      end

      def load_translations!
        load_path.each do |path|
          Dir.glob(File.join(path, '**', '*.json')).sort.each { |file| backend.load_file(file) }
        end
        @translator = nil
      end

      def store_translations(locale, data)
        @translator = nil
        backend.store_translations(locale, data)
      end

      def available_locales
        backend.locales
      end

      def translate(key, **options)
        options[:locale] ||= locale
        translator.translate(key, **options)
      end
      alias_method :t, :translate

      def localize(value, **options)
        options[:locale] ||= locale
        translator.localize(value, **options)
      end
      alias_method :l, :localize

      def best_locale_from_accept(header, available: available_locales)
        return nil if header.nil? || header.strip.empty?
        wanted = available.map(&:to_s)
        parse_accept_language(header).each do |tag|
          exact = wanted.find { |candidate| candidate.casecmp?(tag) }
          return exact.to_sym if exact
          primary = tag.split('-').first
          match = wanted.find { |candidate| candidate.casecmp?(primary) }
          return match.to_sym if match
        end
        nil
      end

      def reset!
        @backend = nil
        @translator = nil
        @default_locale = nil
        @fallbacks = nil
        @load_path = nil
        Thread.current[:facet_i18n_locale] = nil
      end

      private

      def translator
        @translator ||= Translator.new(backend, default_locale: default_locale, fallbacks: fallbacks)
      end

      def parse_accept_language(header)
        entries = header.split(',').filter_map do |part|
          tag, *params = part.strip.split(';').map(&:strip)
          next if tag.nil? || tag.empty?
          quality = 1.0
          params.each { |param| quality = param.sub('q=', '').to_f if param.start_with?('q=') }
          [tag, quality]
        end
        entries.sort_by.with_index { |(_, quality), index| [-quality, index] }.map(&:first)
      end
    end
  end
end
