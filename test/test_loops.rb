# frozen_string_literal: true

require "test_helper"

class TestLoops < Minitest::Test
  def test_while_and_until
    assert_same_output(<<~RUBY)
      i = 0
      while i < 5
        i += 1
        next if i == 2
        break if i == 4
        p i
      end
      p i
      j = 10
      until j <= 7
        j -= 1
      end
      p j
      w = while false do end
      p w
    RUBY
  end

  def test_integer_iterators
    assert_same_output(<<~RUBY)
      s = 0
      10.times { |k| s += k }
      p s
      r = 3.times { |k| p k }
      p r
      1.upto(3) { |k| puts "up \#{k}" }
      3.downto(1) { |k| puts "down \#{k}" }
      p 5.upto(4) { p 0 }
      0.times { p 0 }
      n = 4
      n.times { n -= 1 }
      p n
    RUBY
  end

  def test_ranges_and_for
    assert_same_output(<<~RUBY)
      (1..3).each { |k| puts "inc \#{k}" }
      (1...3).each { |k| puts "exc \#{k}" }
      a = 2
      b = 4
      (a..b).each { |k| p k }
      for q in 2..4 do p q end
      p q
    RUBY
  end

  def test_loop_with_break_value
    assert_same_output(<<~RUBY)
      n = 0
      v = loop do
        n += 1
        break n * 10 if n == 3
      end
      p v
      u = loop { break }
      p u
    RUBY
  end

  def test_block_parameters_shadow_outer_variables
    assert_same_output(<<~RUBY)
      x = 5
      2.times { |x| p x }
      p x
      3.times do |i|
        y = i * 2
        x += y
      end
      p x
    RUBY
  end

  def test_nested_loops_with_break_and_next
    assert_same_output(<<~RUBY)
      total = 0
      3.times do |a|
        3.times do |b|
          next if b == 1
          break if a == 2
          total += a * 10 + b
        end
      end
      p total
      i = 0
      while i < 3
        i += 1
        j = 0
        while true
          j += 1
          break if j > i
          next if j == 2
          puts "\#{i} \#{j}"
        end
      end
    RUBY
  end

  def test_return_from_inside_loops
    assert_same_output(<<~RUBY)
      def find(limit)
        i = 0
        while true
          i += 1
          return i if i * i > limit
        end
      end
      def first_multiple(n)
        1.upto(100) do |k|
          10.times do |j|
            return k * 100 + j if (k * j) % n == 0 && j > 0
          end
        end
        nil
      end
      p find(50), first_multiple(7)
      i = 0
      loop do
        i += 1
        if i == 3
          puts "done"
          return
        end
      end
      puts "unreachable"
    RUBY
  end

  def test_loops_in_recursive_methods
    assert_same_output(<<~RUBY)
      def sum_tree(depth)
        return 1 if depth == 0
        s = 0
        2.times { s += sum_tree(depth - 1) }
        s + 1
      end
      p sum_tree(4)
    RUBY
  end

  def test_loops_are_immediate
    sim = boot(<<~RUBY)
      $n = 0
      1000.times { $n += 1 }
    RUBY
    sim.run_function("t:main")
    assert_equal 1000, sim.score("$n", "t.globals")
  end

  def test_runaway_loop_is_cut_by_the_chain_limit
    sim = boot("loop { $n = 1 }\n")
    sim.chain_limit = 10_000
    sim.run_function("t:main")
    assert_includes sim.log.last, "chain limit"
  end

  def test_inclusive_loops_stop_at_the_32_bit_limits
    assert_same_output(<<~RUBY)
      2147483647.upto(2147483647) { |i| p i }
      2147483646.upto(2147483647) { |i| next if i == 2147483647; p i }
      (-2147483647).downto(-2147483648) { |i| p i }
      (2147483646..2147483647).each { |i| p i }
      for x in -2147483648..-2147483647 do p x end
      (-2147483648...-2147483646).each { |i| p i }
      p((-2147483648).upto(-2147483648) { |i| p i })
    RUBY
  end

  def test_iterator_value_after_break
    assert_same_output(<<~RUBY)
      p(3.times { break })
      p(3.times { |i| break i * 5 if i == 1 })
      p(1.upto(4) { |i| break i if i == 3 })
      p(4.downto(1) { break })
      p 2.times { }
      p 1.upto(2) { }
      r = 3.times { |i| next if i == 0 }
      p r
    RUBY
  end

  def test_block_locals_start_each_invocation_as_nil
    assert_same_output(<<~RUBY)
      3.times { |i| y = 7 if i == 0; p y }
      n = 0
      loop do
        n += 1
        z = n if n == 1
        p z
        break if n == 2
      end
      2.times do |a|
        2.times { |b| w = a + b if b == 0; p w }
      end
      x = 1
      2.times { |i| x = i if i == 1; p x }
    RUBY
  end

  def test_using_a_range_value_is_rejected
    assert_compile_error(/Range#each is a Range/, "r = (1..2).each {}\np r")
    assert_compile_error(/for loop is a Range/, "r = (for x in 1..2 do end)\np r")
    assert_compile_error(/Range#each is a Range/, "def f\n  (1..2).each { }\nend\nf")
    assert_same_output("def f\n  (1..2).each { |i| p i }\n  nil\nend\np f\n")
  end

  def test_errors
    assert_compile_error(/break outside of a loop/, "break")
    assert_compile_error(/next outside of a loop/, "def f\n  next\nend")
    assert_compile_error(/at most one parameter/, "3.times { |a, b| }")
    assert_compile_error(/not supported/, "begin\n  x = 1\nend while false")
    assert_compile_error(/integer literals|Integer range/, "for x in 1 do end")
  end
end
