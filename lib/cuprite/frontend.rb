# frozen_string_literal: true

module Cuprite
  # Lowers the Prism AST to Cuprite IR.
  class Frontend
    INT_MIN = -2_147_483_648
    INT_MAX = 2_147_483_647

    ARITH_OPS = %i[+ - * / % **].freeze
    COMPARE_OPS = %i[== != < <= > >=].freeze

    def initialize(file:)
      @file = file
    end

    def build(root)
      @program = IR::Program.new
      main = IR::Function.new("main", kind: :main, line: 1)
      @program.add_function(main)
      with_function(main) do
        compile_body(root.statements, used: false)
        emit IR::Return.new(src: IR::Const.nil)
      end
      @program
    end

    private

    # --- Context -----------------------------------------------------------

    def with_function(fn)
      saved = [@fn, @block, @assigned]
      @fn = fn
      @block = fn.body
      @assigned = Set.new(fn.params)
      yield
    ensure
      @fn, @block, @assigned = saved
    end

    # Emits into `block` while the given block runs.
    def into(block)
      saved = @block
      @block = block
      yield
      block
    ensure
      @block = saved
    end

    def emit(ins)
      ins.line ||= @line
      @block << ins
      ins
    end

    def error(message, node = nil)
      line = node ? node.location.start_line : @line
      raise CompileError.new(message, file: @file, line: line)
    end

    # Compiles a branch into a new block, tracking definite assignment.
    # Returns [block, locals assigned in it].
    def branch
      before = @assigned
      @assigned = before.dup
      block = into([]) { yield }
      assigned = @assigned
      @assigned = before
      [block, assigned]
    end

    # Prism renamed `consequent` to `subsequent`; support both.
    def subsequent(node)
      node.respond_to?(:subsequent) ? node.subsequent : node.consequent
    end

    # --- Statements and expressions ---------------------------------------

    # Compiles a StatementsNode (or nil) and returns the operand holding the
    # value of its last statement (nil when used is false).
    def compile_body(node, used: true)
      return IR::Const.nil if node.nil?

      stmts = node.is_a?(Prism::StatementsNode) ? node.body : [node]
      return IR::Const.nil if stmts.empty?

      stmts[0..-2].each { |stmt| compile_expr(stmt, used: false) }
      compile_expr(stmts.last, used: used)
    end

    def compile_expr(node, used: true)
      @line = node.location.start_line
      case node
      when Prism::NilNode then IR::Const.nil
      when Prism::TrueNode then IR::Const.bool(true)
      when Prism::FalseNode then IR::Const.bool(false)
      when Prism::IntegerNode then int_literal(node.value, node)
      when Prism::ParenthesesNode then compile_body(node.body, used: used)
      when Prism::StatementsNode then compile_body(node, used: used)
      when Prism::LocalVariableReadNode then read_local(node.name)
      when Prism::LocalVariableWriteNode then assign(local_slot(node.name), node.value)
      when Prism::LocalVariableOperatorWriteNode
        op_assign(local_slot(node.name), read_local(node.name), node_operator(node), node.value)
      when Prism::LocalVariableOrWriteNode then or_assign(local_slot(node.name), read_local(node.name), node.value)
      when Prism::LocalVariableAndWriteNode then and_assign(local_slot(node.name), read_local(node.name), node.value)
      when Prism::GlobalVariableReadNode then global(node.name)
      when Prism::GlobalVariableWriteNode then assign(global(node.name), node.value)
      when Prism::GlobalVariableOperatorWriteNode
        g = global(node.name)
        op_assign(g, g, node_operator(node), node.value)
      when Prism::GlobalVariableOrWriteNode
        g = global(node.name)
        or_assign(g, g, node.value)
      when Prism::GlobalVariableAndWriteNode
        g = global(node.name)
        and_assign(g, g, node.value)
      when Prism::AndNode then logical(:and, node.left, node.right)
      when Prism::OrNode then logical(:or, node.left, node.right)
      when Prism::IfNode then compile_if(node.predicate, node.statements, subsequent(node), used: used)
      when Prism::UnlessNode then compile_if(node.predicate, node.statements, node_else_body(node), used: used, negate: true)
      when Prism::ElseNode then compile_body(node.statements, used: used)
      when Prism::CaseNode then compile_case(node, used: used)
      when Prism::CallNode then compile_call(node, used: used)
      when Prism::StringNode, Prism::InterpolatedStringNode
        error("strings are only supported as arguments to puts, p and raise", node)
      else
        error("unsupported syntax: #{node.type.to_s.delete_suffix('_node')}", node)
      end
    end

    def node_else_body(node)
      e = subsequent(node)
      e&.statements
    end

    def node_operator(node)
      op = node.respond_to?(:binary_operator) ? node.binary_operator : node.operator
      op.to_s.delete_suffix("=").to_sym
    end

    def int_literal(value, node)
      error("integer literal #{value} is outside the 32-bit range", node) unless value.between?(INT_MIN, INT_MAX)

      IR::Const.int(value)
    end

    # --- Variables ---------------------------------------------------------

    def local_slot(name) = @fn.local(name.to_s)

    def read_local(name)
      slot = local_slot(name)
      @fn.maybe_unassigned << slot unless @assigned.include?(slot)
      slot
    end

    def global(name)
      g = IR::Global.new(name.to_s)
      @program.globals << g
      g
    end

    def assign(slot, value_node)
      value = compile_expr(value_node)
      emit IR::Move.new(dst: slot, src: value)
      @assigned << slot if slot.is_a?(IR::Local)
      slot
    end

    def op_assign(slot, current, op, value_node)
      value = compile_expr(value_node)
      error("unsupported operator #{op}=") unless ARITH_OPS.include?(op)

      emit IR::Arith.new(dst: slot, op: op, a: current, b: value)
      @assigned << slot if slot.is_a?(IR::Local)
      slot
    end

    # x ||= v  →  x = v unless x
    def or_assign(slot, current, value_node)
      else_body, = branch { emit IR::Move.new(dst: slot, src: compile_expr(value_node)) }
      emit IR::If.new(cond: current, then_body: [], else_body: else_body)
      @assigned << slot if slot.is_a?(IR::Local)
      slot
    end

    # x &&= v  →  x = v if x
    def and_assign(slot, current, value_node)
      then_body, = branch { emit IR::Move.new(dst: slot, src: compile_expr(value_node)) }
      emit IR::If.new(cond: current, then_body: then_body, else_body: [])
      slot
    end

    # A slot holding `operand` that later code cannot change: temporaries
    # are assigned once, so only variables need a copy.
    def stable(operand)
      return operand if operand.is_a?(IR::Const) || temp?(operand)

      t = @fn.temp
      emit IR::Move.new(dst: t, src: operand)
      t
    end

    def temp?(operand) = operand.is_a?(IR::Local) && operand.name.start_with?("%")

    # --- Control flow ------------------------------------------------------

    # a && b / a || b with Ruby's value semantics and short-circuiting.
    def logical(kind, left, right)
      dst = @fn.temp
      emit IR::Move.new(dst: dst, src: compile_expr(left))
      body, = branch { emit IR::Move.new(dst: dst, src: compile_expr(right)) }
      if kind == :and
        emit IR::If.new(cond: dst, then_body: body, else_body: [])
      else
        emit IR::If.new(cond: dst, then_body: [], else_body: body)
      end
      dst
    end

    def compile_if(predicate, then_node, else_node, used:, negate: false)
      cond = compile_expr(predicate)
      dst = used ? @fn.temp : nil
      then_body, then_assigned = branch do
        v = compile_expr_or_nil(then_node, used: used)
        emit IR::Move.new(dst: dst, src: v) if dst
      end
      else_body, else_assigned = branch do
        v = compile_expr_or_nil(else_node, used: used)
        emit IR::Move.new(dst: dst, src: v) if dst
      end
      then_body, else_body = else_body, then_body if negate
      @assigned.merge(then_assigned & else_assigned)
      # Both branches are tested against cond, so the first must not change it.
      cond = stable(cond) unless then_body.empty? || else_body.empty?
      emit IR::If.new(cond: cond, then_body: then_body, else_body: else_body)
      dst || IR::Const.nil
    end

    def compile_expr_or_nil(node, used:)
      node.nil? ? IR::Const.nil : compile_expr(node, used: used)
    end

    def compile_case(node, used:)
      subject = node.predicate && stable(compile_expr(node.predicate))
      dst = used ? @fn.temp : nil
      whens = node.conditions
      else_node = subsequent(node)
      build_when = lambda do |index|
        if index == whens.size
          v = else_node ? compile_body(else_node.statements, used: used) : IR::Const.nil
          emit IR::Move.new(dst: dst, src: v) if dst
          next
        end
        w = whens[index]
        error("pattern matching (case/in) is not supported", w) unless w.is_a?(Prism::WhenNode)

        cond = when_condition(subject, w.conditions)
        then_body, then_assigned = branch do
          v = compile_body(w.statements, used: used)
          emit IR::Move.new(dst: dst, src: v) if dst
        end
        else_body, else_assigned = branch { build_when.call(index + 1) }
        @assigned.merge(then_assigned & else_assigned)
        emit IR::If.new(cond: cond, then_body: then_body, else_body: else_body)
      end
      build_when.call(0)
      dst || IR::Const.nil
    end

    # The truth value of one `when a, b, c` clause.
    def when_condition(subject, conditions)
      dst = @fn.temp
      conditions.each_with_index do |c, i|
        test = lambda do
          v = if subject.nil?
                compile_expr(c)
              elsif c.is_a?(Prism::RangeNode)
                range_test(subject, c)
              else
                t = @fn.temp
                emit IR::Compare.new(dst: t, op: :==, a: subject, b: compile_expr(c))
                t
              end
          emit IR::Move.new(dst: dst, src: v)
        end
        if i.zero?
          test.call
        else
          body, = branch { test.call }
          emit IR::If.new(cond: dst, then_body: [], else_body: body)
        end
      end
      dst
    end

    def range_test(subject, range)
      lo = range.left && const_int(range.left)
      hi = range.right && const_int(range.right)
      exclusive = range.respond_to?(:exclude_end?) ? range.exclude_end? : range.operator_loc.slice == "..."
      hi -= 1 if hi && exclusive
      t = @fn.temp
      emit IR::InRange.new(dst: t, src: subject, lo: lo, hi: hi)
      t
    end

    # Constant-folds integer arithmetic with 32-bit wrapping.
    def fold(op, a, b)
      return nil unless a.is_a?(IR::Const) && b.is_a?(IR::Const) && a.type == :int && b.type == :int

      x = a.value
      y = b.value
      v = case op
          when :+ then x + y
          when :- then x - y
          when :* then x * y
          when :/ then y.zero? ? (return nil) : x.div(y)
          when :% then y.zero? ? (return nil) : x.modulo(y)
          when :** then y.negative? || y > 64 ? (return nil) : x.pow(y, 1 << 32)
          end
      v &= 0xffff_ffff
      IR::Const.int(v >= 0x8000_0000 ? v - 0x1_0000_0000 : v)
    end

    def const_int(node)
      v = compile_expr(node)
      error("range bounds must be integer literals", node) unless v.is_a?(IR::Const) && v.type == :int

      v.value
    end

    # --- Calls -------------------------------------------------------------

    def compile_call(node, used:)
      name = node.name
      args = node.arguments&.arguments || []
      recv = node.receiver

      if recv && ARITH_OPS.include?(name) && args.size == 1 && !node.block
        a = compile_expr(recv)
        b = compile_expr(args.first)
        folded = fold(name, a, b)
        return folded if folded

        dst = @fn.temp
        emit IR::Arith.new(dst: dst, op: name, a: a, b: b)
        return dst
      end
      if recv && COMPARE_OPS.include?(name) && args.size == 1
        a = compile_expr(recv)
        b = compile_expr(args.first)
        dst = @fn.temp
        emit IR::Compare.new(dst: dst, op: name, a: a, b: b)
        return dst
      end
      if recv && args.empty? && !node.block
        case name
        when :-@
          v = compile_expr(recv)
          return int_literal(-v.value, node) if v.is_a?(IR::Const) && v.type == :int

          dst = @fn.temp
          emit IR::Arith.new(dst: dst, op: :-, a: IR::Const.int(0), b: v)
          return dst
        when :+@ then return compile_expr(recv)
        when :!
          dst = @fn.temp
          emit IR::Not.new(dst: dst, src: compile_expr(recv))
          return dst
        end
      end

      if recv.nil?
        case name
        when :puts then return compile_print(node, args, :puts)
        when :p then return compile_print(node, args, :p, used: used)
        end
      end

      error("undefined method '#{name}'", node)
    end

    def compile_print(node, args, kind, used: false)
      error("#{kind} does not take a block", node) if node.block
      if kind == :puts
        lines = args.empty? ? [[]] : args.map { |a| print_parts(a, :to_s) }
        emit IR::Print.new(lines: lines)
        return IR::Const.nil
      end

      lines = args.map { |a| print_parts(a, :inspect) }
      emit IR::Print.new(lines: lines) unless lines.empty?
      return IR::Const.nil if args.empty? || !used

      error("p with several arguments returns an Array, which is not supported", node) if args.size > 1
      lines.first.size == 1 && lines.first.first.is_a?(Array) ? lines.first.first.first : IR::Const.nil
    end

    # Parts of one printed line for argument node `arg`.
    def print_parts(arg, mode)
      case arg
      when Prism::StringNode
        [mode == :inspect ? arg.unescaped.inspect : arg.unescaped]
      when Prism::InterpolatedStringNode
        parts = []
        parts << '"' if mode == :inspect
        arg.parts.each do |part|
          case part
          when Prism::StringNode
            parts << (mode == :inspect ? arg_inspect_inner(part.unescaped) : part.unescaped)
          when Prism::EmbeddedStatementsNode
            sub = part.statements&.body || []
            if sub.size == 1 && sub.first.is_a?(Prism::StringNode)
              parts << sub.first.unescaped
            else
              parts << [compile_body(part.statements), :to_s]
            end
          else
            error("unsupported string interpolation", part)
          end
        end
        parts << '"' if mode == :inspect
        parts
      else
        [[compile_expr(arg), mode]]
      end
    end

    def arg_inspect_inner(str) = str.inspect[1..-2]
  end
end
