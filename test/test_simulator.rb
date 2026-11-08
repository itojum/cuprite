# frozen_string_literal: true

require "test_helper"

# Sanity checks for the test simulator itself.
class TestSimulator < Minitest::Test
  def sim_with(functions)
    pack = Cuprite::Pack.new("s")
    functions.each { |path, lines| pack.add_function(path, lines) }
    sim = Cuprite::Simulator.new(pack)
    sim.command("scoreboard objectives add o dummy")
    sim
  end

  def test_wrapping_and_floor_division
    sim = sim_with({})
    sim.command("scoreboard players set a o 2147483647")
    sim.command("scoreboard players add a o 1")
    assert_equal(-2_147_483_648, sim.score("a", "o"))
    sim.command("scoreboard players set a o -7")
    sim.command("scoreboard players set b o 2")
    sim.command("scoreboard players operation a o /= b o")
    assert_equal(-4, sim.score("a", "o"))
    sim.command("scoreboard players set a o -7")
    sim.command("scoreboard players operation a o %= b o")
    assert_equal 1, sim.score("a", "o")
  end

  def test_execute_if_function_uses_return_value
    sim = sim_with("one" => ["return 1"], "zero" => ["return 0"], "none" => ["scoreboard players set x o 5"])
    sim.command("execute store success score r o if function s:one")
    assert_equal 1, sim.score("r", "o")
    sim.command("execute store success score r o if function s:zero")
    assert_equal 0, sim.score("r", "o")
    sim.command("execute store success score r o if function s:none")
    assert_equal 0, sim.score("r", "o")
    assert_equal 5, sim.score("x", "o")
  end

  def test_return_stops_function
    sim = sim_with("f" => ["scoreboard players set x o 1", "return 0", "scoreboard players set x o 2"])
    sim.run_function("s:f")
    assert_equal 1, sim.score("x", "o")
  end

  def test_macros
    sim = sim_with("m" => ["$scoreboard players set x o $(v)"])
    sim.command("data modify storage s:a args set value {v: 42}")
    sim.command("function s:m with storage s:a args")
    assert_equal 42, sim.score("x", "o")
  end

  def test_chain_limit_truncates
    sim = sim_with("loop" => ["scoreboard players add x o 1", "function s:loop"])
    sim.chain_limit = 100
    sim.run_function("s:loop")
    assert_equal 50, sim.score("x", "o")
  end

  def test_storage_paths
    sim = sim_with({})
    sim.command("data modify storage s:a stack append value {}")
    sim.command("execute store result storage s:a stack[-1].v0 int 1 run scoreboard players set q o 7")
    assert_equal [{ "v0" => 7 }], sim.storage["s:a"]["stack"]
    sim.command('data modify storage s:a pending."3" set value 5')
    assert_equal({ "3" => 5 }, sim.storage["s:a"]["pending"])
    sim.command('data remove storage s:a pending."3"')
    sim.command("data remove storage s:a stack[-1]")
    assert_equal [], sim.storage["s:a"]["stack"]
  end

  def test_scoreboard_results_are_score_sums
    sim = sim_with({})
    p1 = sim.spawn("player")
    p2 = sim.spawn("player")
    sim.command("execute store result score r o run scoreboard players set @a o 7")
    assert_equal 14, sim.score("r", "o")
    sim.command("execute store result score r o run scoreboard players add @a o 1")
    assert_equal 16, sim.score("r", "o")
    sim.command("execute store result score r o run scoreboard players remove @a o 3")
    assert_equal 10, sim.score("r", "o")
    sim.set_score(p1, "o", 1)
    sim.set_score(p2, "o", 2)
    sim.command("scoreboard players set b o 4")
    sim.command("execute store result score r o run scoreboard players operation @a o += b o")
    assert_equal 11, sim.score("r", "o")
    sim.command("scoreboard players set a o 7")
    sim.command("scoreboard players set b o 2")
    sim.command("execute store result score r o run scoreboard players operation a o += b o")
    assert_equal 9, sim.score("r", "o")
  end

  def test_store_applies_before_return
    sim = sim_with("f" => ["execute store result score r o run return 7"],
                   "g" => ["execute store success score r o run return fail"])
    assert_equal 7, sim.run_function("s:f")
    assert_equal 7, sim.score("r", "o")
    sim.command("scoreboard players set r o 5")
    assert_equal 0, sim.run_function("s:g")
    assert_equal 0, sim.score("r", "o")
  end

  def test_store_target_bound_at_store_subcommand
    sim = sim_with({})
    player = sim.spawn("player")
    pig = sim.spawn("pig")
    sim.command("scoreboard players set x o 3")
    sim.command("execute as @a store result score @s o as @e[type=pig] run scoreboard players get x o")
    assert_equal 3, sim.score(player, "o")
    assert_nil sim.score(pig, "o")
  end

  def test_function_success_is_separate_from_return_value
    sim = sim_with("zero" => ["return 0"], "fail" => ["return fail"], "seven" => ["return 7"])
    sim.command("execute store success score r o run function s:zero")
    assert_equal 1, sim.score("r", "o")
    sim.command("execute store success score r o run function s:fail")
    assert_equal 0, sim.score("r", "o")
    sim.command("execute store result score r o run function s:seven")
    assert_equal 7, sim.score("r", "o")
    sim.command("execute store success score r o if function s:fail")
    assert_equal 0, sim.score("r", "o")
  end

  def test_execute_run_counts_once_against_chain_limit
    sim = sim_with("loop" => ["execute run scoreboard players add x o 1", "function s:loop"])
    sim.chain_limit = 100
    sim.run_function("s:loop")
    assert_equal 50, sim.score("x", "o")
  end

  def test_store_into_storage_respects_nbt_type
    sim = sim_with({})
    sim.command("scoreboard players set v o 7")
    sim.command("execute store result storage s:a d double 0.1 run scoreboard players get v o")
    assert_in_delta 0.7, sim.storage["s:a"]["d"], 1e-9
    sim.command("execute store result storage s:a f float 0.5 run scoreboard players get v o")
    assert_equal 3.5, sim.storage["s:a"]["f"]
    sim.command("scoreboard players set v o 128")
    sim.command("execute store result storage s:a b byte 1 run scoreboard players get v o")
    assert_equal(-128, sim.storage["s:a"]["b"])
    sim.command("scoreboard players set v o 40000")
    sim.command("execute store result storage s:a s short 1 run scoreboard players get v o")
    assert_equal(-25_536, sim.storage["s:a"]["s"])
    sim.command("scoreboard players set v o 2000000000")
    sim.command("execute store result storage s:a l long 2 run scoreboard players get v o")
    assert_equal 4_000_000_000, sim.storage["s:a"]["l"]
    sim.command("scoreboard players set v o -7")
    sim.command("execute store result storage s:a i int 0.5 run scoreboard players get v o")
    assert_equal(-3, sim.storage["s:a"]["i"]) # Java casts truncate toward zero
  end

  def test_unterminated_snbt_string_is_rejected
    sim = sim_with({})
    assert_raises(Cuprite::Simulator::CommandError) { sim.command('data modify storage s:a x set value "abc') }
    assert_raises(Cuprite::Simulator::CommandError) { sim.command('data modify storage s:a x set value "abc\\') }
    sim.command('data modify storage s:a x set value "a\\"b"')
    assert_equal 'a"b', sim.storage["s:a"]["x"]
  end

  def test_ruby_stack_overflow_is_reported_not_truncated
    # Known limitation: recursion depth is bounded by Ruby's stack, not only
    # the chain limit. It must surface as an error, never as silent truncation.
    sim = sim_with("loop" => ["scoreboard players add x o 1", "function s:loop"])
    err = assert_raises(Cuprite::Simulator::CommandError) { sim.run_function("s:loop") }
    assert_match "Ruby stack depth", err.message
  end
end
