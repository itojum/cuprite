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
end
