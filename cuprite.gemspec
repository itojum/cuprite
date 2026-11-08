# frozen_string_literal: true

require_relative "lib/cuprite/version"

Gem::Specification.new do |spec|
  spec.name = "cuprite"
  spec.version = Cuprite::VERSION
  spec.authors = ["itojum"]
  spec.email = ["tech@itojum.dev"]
  spec.homepage = "https://github.com/itojum/cuprite"
  spec.summary = "Ahead-of-time compiler from a subset of Ruby to Minecraft data packs"
  spec.description = <<~DESC
    Cuprite compiles a subset of Ruby to a Minecraft Java Edition data pack
    (.mcfunction files). See docs/design.md for the supported language.
  DESC
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.3"
  spec.files = Dir["lib/**/*.rb", "exe/*", "docs/**/*.md"]
  spec.bindir = "exe"
  spec.executables = ["cuprite"]
  spec.require_paths = ["lib"]
end
