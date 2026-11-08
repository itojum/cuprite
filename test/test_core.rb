# frozen_string_literal: true

require "test_helper"

class TestCore < Minitest::Test
  def test_arithmetic
    assert_same_output(<<~RUBY)
      a = 17
      b = 5
      p a + b, a - b, a * b, a / b, a % b
      p(-a / b, -a % b, a / -b, a % -b)
      p 2 ** 10, -a, +a
      c = a
      c += 1
      c -= 3
      c *= 2
      c /= 4
      c %= 5
      p c
      p 1 + 2 * 3 - (4 - 1)
    RUBY
  end

  def test_arithmetic_with_variable_on_both_sides
    assert_same_output(<<~RUBY)
      x = 3
      y = 10
      y = x - y
      p y
      x = x * x
      p x
      x **= 3
      p x
    RUBY
  end

  def test_comparisons
    assert_same_output(<<~RUBY)
      a = 3
      b = 7
      p a < b, a <= b, a > b, a >= b, a == b, a != b
      p a < 3, a <= 3, a > 3, a >= 3, a == 3, a != 3
      p 3 < a, 3 == a
      p a == nil, nil == a, a != nil
      t = true
      p t == true, t == false, t != false
    RUBY
  end

  def test_equality_across_types_and_nil
    assert_same_output(<<~RUBY)
      n = nil
      m = nil
      x = 1
      p n == m, n != m, n == nil
      p x == true, true == 1
      y = 1 if false
      z = 1 if false
      p y == z
      y = 2
      p y == z, z == y, y != z
    RUBY
  end

  def test_logical_operators
    assert_same_output(<<~RUBY)
      t = true
      f = false
      p t && f, t || f, !t, !f, (not t)
      p((t and f))
      p((f or t))
      n = nil
      p n || 5, n && 5, 3 && 4, 3 || 4
      p !n, !3
    RUBY
  end

  def test_short_circuit
    assert_same_output(<<~RUBY)
      f = false
      f && puts("not printed")
      f || puts("printed")
      true || puts("not printed")
    RUBY
  end

  def test_if_unless_and_modifiers
    assert_same_output(<<~RUBY)
      x = 4
      if x > 3
        puts "big"
      elsif x > 1
        puts "medium"
      else
        puts "small"
      end
      unless x == 4
        puts "not four"
      else
        puts "four"
      end
      puts "even" if x % 2 == 0
      puts "odd" unless x % 2 == 0
      y = if x > 10 then 1 elsif x > 2 then 2 else 3 end
      p y
      z = x > 2 ? 10 : 20
      p z
      w = (puts "side" if false)
      p w
    RUBY
  end

  def test_branch_may_change_condition_variable
    assert_same_output(<<~RUBY)
      c = true
      if c
        c = false
        puts "then"
      else
        puts "else"
      end
    RUBY
  end

  def test_case_ranges
    src = ->(v) { <<~RUBY }
      v = #{v}
      r = case v
          when 0 then 0
          when 1, 2 then 1
          when 3..5 then 2
          when 6...8 then 3
          when 9.. then 4
          else 5
          end
      p r
      case
      when v > 100 then puts "huge"
      when v > 5 then puts "big"
      end
      s = case v when 1 then 1 end
      p s
    RUBY
    [-3, 0, 1, 2, 4, 7, 8, 9, 50].each { |v| assert_same_output(src.call(v)) }
  end

  def test_nil_and_unassigned_locals
    assert_same_output(<<~RUBY)
      x = 1 if false
      p x
      puts "x=\#{x}."
      y = nil
      p y
      y = 3
      p y
    RUBY
  end

  def test_unassigned_local_is_nil_on_every_run
    sim = boot(<<~RUBY)
      x = 5 if $go
      p x
      $go = !$go
    RUBY
    3.times { sim.run_function("t:main") }
    assert_equal %w[nil 5 nil], output_lines(sim)
  end

  def test_puts_and_p_formatting
    assert_same_output(<<~RUBY)
      puts "hello"
      puts
      puts 42, true, nil
      p "str"
      p true, false, nil
      x = 3
      b = x > 1
      puts "x=\#{x} b=\#{b} n=\#{nil} lit=\#{"s"}"
      p "x=\#{x}"
      puts "quote \\" and backslash \\\\"
    RUBY
  end

  def test_globals
    assert_same_output(<<~RUBY)
      p $g
      $g ||= 10
      $g += 1
      p $g
      $h = true
      $h &&= false
      p $h
    RUBY
  end

  def test_globals_persist_across_runs
    sim = boot(<<~RUBY)
      $count ||= 0
      $count += 1
      p $count
    RUBY
    3.times { sim.run_function("t:main") }
    sim.load
    sim.run_function("t:main")
    assert_equal %w[1 2 3 4], output_lines(sim)
    assert_equal 4, sim.score("$count", "t.globals")
  end

  def test_output_only_in_debug_mode
    sim = boot('puts "hi"', debug: false)
    sim.run_function("t:main")
    assert_empty sim.chat
    sim.run_function("t:debug/on")
    sim.run_function("t:main")
    assert_includes sim.chat.last, '"hi"'
  end

  def test_integers_wrap
    out = run_mc(<<~RUBY)
      a = 2147483647
      a += 1
      p a
      b = -2147483648
      b -= 1
      p b
      c = 65536
      p c * c
      p((2147483647 + 1) / 2)
      d = 2147483647
      p((d + 1) / 2)
      p 2 ** 31
    RUBY
    assert_equal %w[-2147483648 2147483647 0 -1073741824 -1073741824 -2147483648], out
  end

  def test_negative_constant_operands
    assert_same_output(<<~RUBY)
      a = 10
      a += -3
      a -= -4
      p a
      a = a - -2147483600
      p a
    RUBY
  end

  def test_literal_out_of_range
    assert_compile_error(/outside the 32-bit range/, "x = 2147483648")
    assert_compile_error(/outside the 32-bit range/, "x = -2147483649")
    compile("x = -2147483648")
  end

  def test_mixed_integer_and_boolean_is_an_error
    assert_compile_error(/both Integer and true\/false/, "x = 1\nx = true")
    assert_compile_error(/both Integer and true\/false/, "y = true && 1")
  end

  def test_arithmetic_on_booleans_is_an_error
    assert_compile_error(/only defined for Integers/, "b = true\np b + 1")
    assert_compile_error(/only defined for Integers/, "b = true\np b < 1")
  end

  def test_unsupported_syntax
    assert_compile_error(/unsupported syntax/, "x = [1, 2]")
    assert_compile_error(/strings are only supported/, 'x = "a"')
    assert_compile_error(/undefined method 'foo'/, "foo(1)")
  end

  def test_errors_report_line
    e = assert_compile_error(/outside/, "x = 1\n\ny = 9999999999")
    assert_equal 3, e.line
    e = assert_compile_error(/both Integer/, "x = 1\nx = true")
    assert_equal 2, e.line
    e = assert_compile_error(/only defined for Integers/, "b = true\np b + 1")
    assert_equal 2, e.line
    assert_equal "test.rb", e.file
  end
end
