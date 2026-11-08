# frozen_string_literal: true

require "test_helper"

class TestInterop < Minitest::Test
  SCORES = <<~RUBY
    class Scores < Cuprite::Scoreboard
      objective :kills
      objective :deaths, criteria: :deathCount
      objective :mana, name: "t_mana"
    end
  RUBY

  def world(source)
    sim = Cuprite::Simulator.new(compile(source))
    sim.load
    players = %w[A B].map { |n| sim.spawn("player", name: n) }
    [sim, *players]
  end

  def test_declared_objectives_are_created_in_init
    sim = boot(SCORES)
    assert_equal "dummy", sim.objectives["kills"]
    assert_equal "deathCount", sim.objectives["deaths"]
    assert_equal "dummy", sim.objectives["t_mana"]
  end

  def test_score_operations
    sim, a, b = world(SCORES + <<~RUBY)
      Scores.kills.set(10, target: "@a")
      Scores.kills.add(5, target: "@p")
      Scores.kills.remove(3, target: "@p")
      p Scores.kills.get(target: "@p")
      n = 7
      Scores.mana.set(n, target: "$shared")
      Scores.mana.add(n, target: "$shared")
      Scores.mana.remove(1, target: "$shared")
      p Scores.mana.get(target: "$shared")
      p Scores.mana.get(target: "$unset")
      Scores.kills.reset(target: "@a")
      p Scores.kills.get(target: "@p")
      Scores.mana.add(-2, target: "$shared")
      p Scores.mana.get(target: "$shared")
    RUBY
    sim.run_function("t:main")
    assert_equal %w[12 13 nil nil 11], output_lines(sim)
    assert_nil sim.score(b, "kills")
    assert_nil sim.score(a, "kills")
  end

  def test_commands
    sim, = world(<<~RUBY)
      Cuprite.command "say hello"
      Cuprite.command "/say slash"
      n = 3
      Cuprite.command "give @p diamond \#{n}"
      Cuprite.command "give @p emerald \#{n * 2}"
      r = Cuprite.command("tag @a add t")
      p r
    RUBY
    sim.run_function("t:main")
    assert_equal ["say hello", "say slash", "give @p diamond 3", "give @p emerald 6", "tag @a add t"], sim.log
    assert_equal ["2"], output_lines(sim)
  end

  def test_literal_command_is_verbatim
    pack = compile('Cuprite.command "say hi"')
    assert_includes pack.function_lines("__body/main"), "say hi"
    refute pack.files.keys.any? { |k| k.include?("__cmd") }
  end

  def test_interpolated_command_uses_a_macro
    pack = compile("n = 1\nCuprite.command \"give @p diamond \#{n}\"")
    assert_equal ["$return run give @p diamond $(a0)"], pack.function_lines("__cmd/1")
  end

  def test_context_blocks
    sim, a, b = world(SCORES + <<~RUBY)
      count = 0
      as("@a") do
        count += 1
        Scores.kills.set(count, target: "@s")
      end
      p count
      as("@a[name=B]") do
        at("@s") do
          positioned("~ ~1 ~") do
            rotated("0 0") do
              execute("facing entity @p eyes") do
                Cuprite.command "tag @s add seen"
              end
            end
          end
        end
      end
    RUBY
    sim.run_function("t:main")
    assert_equal ["2"], output_lines(sim)
    assert_equal 1, sim.score(a, "kills")
    assert_equal 2, sim.score(b, "kills")
    assert_equal [], a.tags
    assert_equal ["seen"], b.tags
  end

  def test_methods_called_in_context_see_the_executor
    sim, a, b = world(SCORES + <<~RUBY)
      def reward(n)
        Scores.kills.add(n, target: "@s")
      end
      as("@a") { reward(4) }
    RUBY
    sim.run_function("t:main")
    assert_equal [4, 4], [sim.score(a, "kills"), sim.score(b, "kills")]
  end

  def test_next_ends_one_entity
    sim, a, b = world(SCORES + <<~RUBY)
      as("@a") do
        next if Cuprite.command("execute if entity @s[name=A]") == 1
        Scores.kills.set(1, target: "@s")
      end
    RUBY
    sim.run_function("t:main")
    assert_nil sim.score(a, "kills")
    assert_equal 1, sim.score(b, "kills")
  end

  def test_exception_in_one_entity_lets_others_finish_then_propagates
    sim, a, b = world(SCORES + <<~RUBY)
      class Boom < StandardError; end
      begin
        as("@a") do
          raise Boom, "first" if Cuprite.command("execute if entity @s[name=A]") == 1
          Scores.kills.set(1, target: "@s")
        end
        puts "not reached"
      rescue Boom
        puts "rescued"
      end
      as("@a") { raise "uncaught" }
      puts "not reached either"
    RUBY
    sim.run_function("t:main")
    assert_equal ["rescued"], output_lines(sim)
    assert_nil sim.score(a, "kills")
    assert_equal 1, sim.score(b, "kills")
    assert_equal "uncaught", sim.storage["t:__runtime"]["last_error"]["message"]
  end

  def test_errors
    assert_compile_error(/needs a block/, 'as("@a")')
    assert_compile_error(/string literal/, "x = 1\nas(x) { }")
    assert_compile_error(/use the block instead of 'run'/, 'execute("as @a run say") { }')
    assert_compile_error(/break inside a context block/, 'as("@a") { break }')
    assert_compile_error(/return inside a context block/, "def f\n  as(\"@a\") { return }\nend")
    assert_compile_error(/has no objective/, SCORES + 'Scores.nope.get(target: "@s")')
    assert_compile_error(/needs target/, SCORES + "Scores.kills.get")
    assert_compile_error(/unknown scoreboard operation/, SCORES + 'Scores.kills.frob(target: "@s")')
    assert_compile_error(/only contain objective/, "class S < Cuprite::Scoreboard\n  def x; end\nend")
    assert_compile_error(/only Integers can be interpolated/, "b = true\nCuprite.command \"say \#{b}\"")
  end
end
