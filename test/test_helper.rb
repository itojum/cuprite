# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "cuprite"
require "minitest/autorun"
require "open3"
require "tmpdir"
require_relative "support/simulator"

module CupriteTestHelpers
  NS = "t"
  SHIM = File.expand_path("support/shim.rb", __dir__)

  def compile(source, ns: NS, test_mode: true, debug: false)
    Cuprite::Compiler.new(source, namespace: ns, debug: debug, test_mode: test_mode, file: "test.rb").compile
  end

  # Loads the pack into a fresh simulator (running #minecraft:load).
  def boot(source, ns: NS, debug: false, **opts)
    sim = Cuprite::Simulator.new(compile(source, ns: ns, debug: debug), **opts)
    sim.load
    sim
  end

  # Output lines mirrored into storage by test mode (design §3).
  def output_lines(sim, ns: NS)
    (sim.storage["#{ns}:__test"]["out"] || []).map { |parts| parts.map { |part| (part["s"] || part["i"]).to_s }.join }
  end

  # Compiles and runs `source` as /function <ns>:main; returns its output.
  def run_mc(source, ns: NS, **opts)
    sim = boot(source, ns: ns, **opts)
    sim.run_function("#{ns}:main")
    output_lines(sim, ns: ns)
  end

  def run_cruby(source)
    out, err, status = Open3.capture3(RbConfig.ruby, "-r", SHIM, "-e", source)
    raise "CRuby failed: #{err}" unless status.success? || err.empty?

    [out.lines.map(&:chomp), err, status]
  end

  # Differential test: the program must print the same in CRuby and in the
  # simulated game.
  def assert_same_output(source)
    expected, = run_cruby(source)
    actual = run_mc(source)
    assert_equal expected, actual
  end

  def assert_compile_error(pattern, source)
    e = assert_raises(Cuprite::CompileError) { compile(source) }
    assert_match pattern, e.message
    e
  end
end

class Minitest::Test
  include CupriteTestHelpers
end
