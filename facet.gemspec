Gem::Specification.new do |spec|
  spec.name = 'facet'
  spec.version = '0.1.0'
  spec.authors = ['Michał Fox']
  spec.summary = 'A Ruby web framework built on the standard library only.'
  spec.description = 'Routing DSL, controllers, ERB views, a file-backed ORM with migrations, ' \
                     'background jobs, mailers, WebSockets, i18n, caching and security helpers, ' \
                     'served by its own HTTP/1.1 server. No runtime gem dependencies.'
  spec.homepage = 'https://github.com/dualfroz/facet'
  spec.license = 'MIT'
  spec.required_ruby_version = '>= 3.3'

  spec.metadata = {
    'source_code_uri' => spec.homepage,
    'bug_tracker_uri' => "#{spec.homepage}/issues",
    'rubygems_mfa_required' => 'true'
  }

  spec.files = Dir['lib/**/*.rb'] + %w[bin/facet README.md LICENSE]
  spec.bindir = 'bin'
  spec.executables = ['facet']
  spec.require_paths = ['lib']
end
