# frozen_string_literal: true

require "test_helper"

class TestExceptions < Minitest::Test
  def test_rescue_else_ensure
    assert_same_output(<<~RUBY)
      class MyError < StandardError; end
      class SubError < MyError; end
      def risky(n)
        raise SubError, "sub" if n == 1
        raise "plain" if n == 2
        raise ArgumentError.new("arg") if n == 3
        10 / n
      end
      5.times do |i|
        begin
          p risky(i)
        rescue ZeroDivisionError
          puts "zero"
        rescue MyError
          puts "mine"
        rescue TypeError, ArgumentError
          puts "type or arg"
        rescue
          puts "other"
        else
          puts "ok"
        ensure
          puts "ensure \#{i}"
        end
      end
    RUBY
  end

  def test_unmatched_rescue_propagates
    assert_same_output(<<~RUBY)
      def inner
        begin
          raise ArgumentError
        rescue ZeroDivisionError
          puts "wrong"
        end
        puts "not reached"
      end
      begin
        inner
      rescue ArgumentError
        puts "outer"
      end
    RUBY
  end

  def test_ensure_runs_on_return_break_next
    assert_same_output(<<~RUBY)
      def with_ensure
        begin
          return 1
        ensure
          puts "in ensure"
        end
      end
      p with_ensure
      3.times do |i|
        begin
          next if i == 0
          break if i == 2
          puts "body \#{i}"
        ensure
          puts "ens \#{i}"
        end
      end
    RUBY
  end

  def test_ensure_order_with_nested_handlers
    assert_same_output(<<~RUBY)
      begin
        begin
          raise "x"
        ensure
          puts "inner ensure"
        end
      rescue
        puts "outer rescue"
      ensure
        puts "outer ensure"
      end
    RUBY
  end

  def test_rescue_values_and_modifier
    assert_same_output(<<~RUBY)
      x = (1 / 0 rescue 42)
      p x
      v = begin
        7
      rescue
        8
      end
      p v
      w = begin
        raise "x"
      rescue
        9
      end
      p w
      e = begin
        1
      rescue
        2
      else
        3
      end
      p e
      def cleanup(n)
        10 / n
      rescue ZeroDivisionError
        0
      end
      p cleanup(2), cleanup(0)
    RUBY
  end

  def test_exceptions_through_recursion_and_loops
    assert_same_output(<<~RUBY)
      def deep(n)
        return 10 / n if n == 0
        deep(n - 1) + 1
      end
      begin
        deep(3)
      rescue ZeroDivisionError
        puts "deep zero"
      end
      i = 0
      begin
        loop do
          i += 1
          raise "stop" if i == 5
        end
      rescue
        p i
      end
    RUBY
  end

  def test_runtime_checks
    assert_same_output(<<~RUBY)
      y = nil
      begin
        y + 1
      rescue NoMethodError
        puts "nil add"
      end
      z = 0
      begin
        p 5 % z
      rescue ZeroDivisionError
        puts "mod zero"
      end
      begin
        p 5 / 0
      rescue ZeroDivisionError
        puts "const zero"
      end
      begin
        p y < 3
      rescue NoMethodError
        puts "nil compare"
      end
    RUBY
  end

  def test_rescue_does_not_catch_non_standard_errors_by_default
    assert_same_output(<<~RUBY)
      begin
        begin
          raise Exception
        rescue
          puts "standard"
        end
      rescue Exception
        puts "exception"
      end
    RUBY
  end

  def test_uncaught_exception_stops_and_is_recorded
    sim = boot(<<~RUBY)
      puts "before"
      raise ArgumentError, "boom"
      puts "after"
    RUBY
    sim.run_function("t:main")
    assert_equal ["before"], output_lines(sim)
    assert_equal({ "class" => "ArgumentError", "message" => "boom" }, sim.storage["t:__runtime"]["last_error"])
    assert_equal 0, sim.score("$ctl", "t.rt")
    assert_empty sim.chat, "errors print only in debug mode"

    sim.run_function("t:debug/on")
    sim.run_function("t:main")
    assert(sim.chat.any? { |line| line.include?("last_error") || line.include?("exc.class") })
    sim.run_function("t:debug/last_error")
    assert_includes sim.chat.last, "last_error.class"
  end

  def test_uncaught_in_on_tick_does_not_stop_later_ticks
    sim = boot(<<~RUBY)
      def on_tick
        $n ||= 0
        $n += 1
        raise "odd" if $n % 2 == 1
      end
    RUBY
    3.times { sim.tick }
    assert_equal 3, sim.score("$n", "t.globals")
    assert_equal "odd", sim.storage["t:__runtime"]["last_error"]["message"]
  end

  def test_truncation_is_detected
    sim = boot(<<~RUBY)
      def f(n) = n == 0 ? 0 : f(n - 1) + 1
      $depth ||= 0
      $r = f($depth)
    RUBY
    sim.chain_limit = 2000
    sim.command("scoreboard players set $depth t.globals 500")
    sim.run_function("t:main")
    assert_equal 1, sim.score("$running", "t.rt")
    refute_empty sim.storage["t:__runtime"]["stack"]

    sim.chain_limit = 65_536
    sim.command("scoreboard players set $depth t.globals 3")
    sim.run_function("t:main")
    assert_equal 3, sim.score("$r", "t.globals")
    assert_equal "truncated", sim.storage["t:__runtime"]["last_error"]["class"]
    assert_equal 0, sim.score("$running", "t.rt")
    assert_empty sim.storage["t:__runtime"]["stack"].to_a
  end

  def test_truncation_detected_on_load
    sim = boot("loop { $x = 1 }")
    sim.chain_limit = 1000
    sim.run_function("t:main")
    sim.load
    assert_equal "truncated", sim.storage["t:__runtime"]["last_error"]["class"]
    assert_equal 0, sim.score("$running", "t.rt")
  end

  def test_ruby_calls_to_entry_points_skip_the_wrapper
    sim = boot(<<~RUBY)
      def on_load
        $loads ||= 0
        $loads += 1
      end
      on_load
      puts "ok"
    RUBY
    sim.run_function("t:main")
    assert_equal ["ok"], output_lines(sim)
    assert_nil sim.storage["t:__runtime"]["last_error"]
  end

  def test_errors
    assert_compile_error(/unknown exception class Nope/, "raise Nope")
    assert_compile_error(/rescue => variable/, "begin\nrescue => e\nend")
    assert_compile_error(/string literal/, "x = 1\nraise x")
    assert_compile_error(/re-raising is not supported/, "raise")
    assert_compile_error(/only exception classes/, "class Foo; end")
    assert_compile_error(/cannot have a body/, "class E < StandardError\n  def x; end\nend")
  end
end
