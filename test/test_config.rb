# frozen_string_literal: true

require "test_helper"

class TestConfig < Minitest::Test
  def test_defaults
    c = Cuprite::Config.new({ "namespace" => "demo" }, root: "/p")
    assert_equal "src/main.rb", c.entry
    assert_equal "/p/build/demo", c.pack_dir
    assert_equal false, c.debug
    assert_nil c.world_datapack_dir
  end

  def test_world
    c = Cuprite::Config.new({ "namespace" => "demo", "world" => "/w" }, root: "/p")
    assert_equal "/w/datapacks/demo", c.world_datapack_dir
  end

  def test_requires_namespace
    assert_raises(Cuprite::ConfigError) { Cuprite::Config.new({}) }
  end

  def test_rejects_invalid_namespace
    assert_raises(Cuprite::ConfigError) { Cuprite::Config.new({ "namespace" => "Bad NS" }) }
    assert_raises(Cuprite::ConfigError) { Cuprite::Config.new({ "namespace" => "minecraft" }) }
  end

  def test_rejects_unknown_keys
    assert_raises(Cuprite::ConfigError) { Cuprite::Config.new({ "namespace" => "a", "nope" => 1 }) }
  end

  def test_rejects_non_boolean_debug
    assert_raises(Cuprite::ConfigError) { Cuprite::Config.new({ "namespace" => "a", "debug" => "yes" }) }
  end
end
