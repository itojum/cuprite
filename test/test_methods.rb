# frozen_string_literal: true

require "test_helper"

class TestMethods < Minitest::Test
  def test_calls_arguments_and_return
    assert_same_output(<<~RUBY)
      def add(a, b = 10) = a + b
      def nothing; end
      def early(x)
        return 1 if x > 5
        return if x < 0
        2
      end
      def greet(x)
        puts "hi \#{x}"
      end
      p add(1), add(1, 2)
      p nothing
      p early(9), early(-1), early(3)
      greet(3)
      p greet(4)
    RUBY
  end

  def test_methods_can_be_called_before_their_definition_in_other_methods
    assert_same_output(<<~RUBY)
      def a = b + 1
      def b = 41
      p a
    RUBY
  end

  def test_recursion
    assert_same_output(<<~RUBY)
      def fib(n)
        return n if n < 2
        fib(n - 1) + fib(n - 2)
      end
      def fact(n) = n <= 1 ? 1 : n * fact(n - 1)
      p fib(10), fact(10)
    RUBY
  end

  def test_mutual_recursion
    assert_same_output(<<~RUBY)
      def even?(n) = n == 0 ? true : odd?(n - 1)
      def odd?(n) = n == 0 ? false : even?(n - 1)
      p even?(10), odd?(7), even?(7)
    RUBY
  end

  def test_self_call_with_swapped_arguments
    assert_same_output(<<~RUBY)
      def swap_sub(a, b, depth)
        return a - b if depth == 0
        swap_sub(b, a, depth - 1)
      end
      p swap_sub(10, 3, 3), swap_sub(10, 3, 4)
    RUBY
  end

  def test_recursion_keeps_nil_locals_nil
    assert_same_output(<<~RUBY)
      def f(n)
        x = 1 if n > 2
        f(n + 1) if n < 3
        x
      end
      p f(0), f(3)
    RUBY
  end

  def test_locals_are_per_method
    assert_same_output(<<~RUBY)
      def f(x)
        y = x * 2
        y
      end
      y = 5
      p f(3), y
    RUBY
  end

  def test_globals_shared_between_methods
    assert_same_output(<<~RUBY)
      def bump
        $n ||= 0
        $n += 1
      end
      bump
      bump
      p bump, $n
    RUBY
  end

  def test_non_recursive_calls_have_no_stack_overhead
    pack = compile(<<~RUBY)
      def sq(x) = x * x
      p sq(3)
    RUBY
    refute pack.files.values.any? { |c| c.include?(" stack") }
  end

  def test_recursive_calls_use_the_stack
    pack = compile(<<~RUBY)
      def f(n) = n == 0 ? 0 : f(n - 1)
      p f(3)
    RUBY
    assert pack.files.values.any? { |c| c.include?("stack append value {}") }
  end

  def test_function_naming
    pack = compile(<<~RUBY)
      def foo = 1
      def ready? = true
      def activate! = nil
      def Upper = 2
      def snake_case2 = 3
      p foo, ready?, activate!, Upper(), snake_case2
    RUBY
    assert pack.function?("foo")
    assert pack.function?("snake_case2")
    assert pack.function?("__m/1")
    assert pack.function?("__m/2")
    assert pack.function?("__m/3")
    refute pack.files.keys.any? { |k| k.include?("ready") || k.include?("Upper") }
  end

  def test_exported_function_callable_from_commands
    sim = boot(<<~RUBY)
      def hello
        puts "hello"
      end
    RUBY
    sim.run_function("t:hello")
    assert_equal ["hello"], output_lines(sim)
  end

  def test_reserved_names
    %w[main __x wait sleep next_tick wait_until as at positioned rotated execute puts p raise].each do |name|
      assert_compile_error(/reserved/, "def #{name}; end")
    end
  end

  def test_on_load_and_on_tick
    sim = boot(<<~RUBY)
      def on_load
        $loads ||= 0
        $loads += 1
      end
      def on_tick
        $ticks ||= 0
        $ticks += 1
      end
    RUBY
    pack = compile("def on_load; end\ndef on_tick; end")
    assert_equal %w[t:__init t:on_load], pack.tag_values("minecraft", "load")
    assert_equal %w[t:on_tick], pack.tag_values("minecraft", "tick")
    3.times { sim.tick }
    sim.load
    assert_equal 2, sim.score("$loads", "t.globals")
    assert_equal 3, sim.score("$ticks", "t.globals")
  end

  def test_entry_points_take_no_parameters
    assert_compile_error(/cannot take parameters/, "def on_tick(x); end")
    assert_compile_error(/cannot take parameters/, "def on_load(x = 1); end")
  end

  def test_arity
    assert_compile_error(/wrong number of arguments for f \(given 0, expected 1\)/, "def f(a) = a\nf")
    assert_compile_error(/given 3, expected 1\.\.2/, "def f(a, b = 1) = a\nf(1, 2, 3)")
  end

  def test_unsupported_definitions
    assert_compile_error(/must be a literal/, "def f(a, b = a) = b")
    assert_compile_error(/only be defined at the top level/, "if true\n  def f; end\nend")
    assert_compile_error(/only be defined at the top level/, "def f\n  def g; end\nend")
    assert_compile_error(/defined twice/, "def f; end\ndef f; end")
    assert_compile_error(/only required and optional/, "def f(*a); end")
    assert_compile_error(/receiver/, "def self.f; end")
  end

  def test_mixed_return_types_are_an_error
    assert_compile_error(/may return both/, "def f(x) = x > 0 ? 1 : true\np f(1)")
  end

  def test_top_level_return
    assert_same_output(<<~RUBY)
      puts "a"
      x = 1
      if x == 1
        puts "b"
        return
      end
      puts "c"
    RUBY
  end
end
