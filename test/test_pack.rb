# frozen_string_literal: true

require "test_helper"

class TestPack < Minitest::Test
  def test_pack_mcmeta_uses_min_and_max_format
    meta = JSON.parse(compile("nil").files.fetch("pack.mcmeta"))
    assert_equal [121, 0], meta["pack"]["min_format"]
    assert_equal 121, meta["pack"]["max_format"]
    refute meta["pack"].key?("pack_format")
  end

  def test_init_is_registered_in_load
    pack = compile("nil")
    assert_equal ["t:__init"], pack.tag_values("minecraft", "load")
    assert pack.function?("main")
    assert pack.function?("debug/on")
    assert pack.function?("debug/off")
    assert pack.function?("debug/last_error")
  end

  def test_all_state_is_namespaced
    pack = compile("nil", ns: "foo")
    init = pack.function_lines("__init")
    assert_includes init, "scoreboard objectives add foo.vars dummy"
    assert_includes init, "scoreboard objectives add foo.globals dummy"
    assert_includes init, "scoreboard objectives add foo.rt dummy"
  end

  def test_debug_flag_initialised_only_if_unset
    sim = boot("nil", ns: "t")
    assert_equal 0, sim.score("$debug", "t.rt")
    sim.run_function("t:debug/on")
    sim.load # /reload keeps the state
    assert_equal 1, sim.score("$debug", "t.rt")

    on = Cuprite::Simulator.new(compile("nil", debug: true))
    on.load
    assert_equal 1, on.score("$debug", "t.rt")
  end

  def test_build_hash_changes_with_code
    a = boot("nil").score("$build", "t.rt")
    b = boot("nil", ns: "u").score("$build", "u.rt")
    refute_equal a, b
  end

  def test_last_error_without_error
    sim = boot("nil")
    sim.run_function("t:debug/last_error")
    assert_match "no error recorded", sim.chat.last
  end
end
