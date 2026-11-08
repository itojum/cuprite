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

    # Kernel control constructs (design §9.0) and built-ins that user
    # methods may not shadow (design §4.5).
    RESERVED = %w[main wait sleep next_tick wait_until as at positioned rotated execute
                  puts p raise loop].freeze

    def build(root)
      @program = IR::Program.new
      main = IR::Function.new("main", kind: :main, line: 1)
      @program.add_function(main)
      @defs = {}
      root.statements.body.each { |stmt| declare_method(stmt) if stmt.is_a?(Prism::DefNode) }

      with_function(main) do
        compile_body(root.statements, used: false)
        emit IR::Return.new(src: IR::Const.nil)
      end
      @defs.each do |name, node|
        fn = @program.functions.fetch(name)
        with_function(fn) do
          @line = node.location.start_line
          value = compile_method_body(node.body)
          # A body that always returns has no implicit return; emitting one
          # would feed an unreachable value into return-type inference.
          emit IR::Return.new(src: value) unless @terminated
        end
      end
      @program
    end

    private

    # --- Context -----------------------------------------------------------

    def with_function(fn)
      saved = [@fn, @block, @assigned, @terminated]
      @fn = fn
      @block = fn.body
      @assigned = Set.new(fn.params)
      @terminated = false
      yield
    ensure
      @fn, @block, @assigned, @terminated = saved
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

    # Compiles a branch into a new block, tracking definite assignment and
    # whether the branch always returns. Returns [block, locals assigned in
    # it, terminated]. A branch that always returns is treated as having
    # assigned everything, since code after it only runs via the other path.
    def branch
      before = @assigned
      outer_terminated = @terminated
      @assigned = before.dup
      @terminated = false
      block = into([]) { yield }
      assigned = @assigned
      terminated = @terminated
      @assigned = before
      @terminated = outer_terminated
      [block, assigned, terminated]
    end

    # Locals definitely assigned after two alternative branches.
    def merge_assigned(a, a_term, b, b_term)
      return b if a_term
      return a if b_term

      a & b
    end

    # Prism renamed `consequent` to `subsequent`; support both.
    def subsequent(node)
      node.respond_to?(:subsequent) ? node.subsequent : node.consequent
    end

    # --- Methods -----------------------------------------------------------

    def declare_method(node)
      @line = node.location.start_line
      name = node.name.to_s
      error("methods with a receiver (def self.#{name}) are not supported", node) if node.receiver
      if RESERVED.include?(name) || name.start_with?("__")
        error("'#{name}' is reserved and cannot be defined as a method", node)
      end
      error("method '#{name}' is defined twice", node) if @defs.key?(name)

      kind = { "on_load" => :on_load, "on_tick" => :on_tick }.fetch(name, :method)
      params, defaults = method_params(node, name)
      error("#{name} cannot take parameters", node) if kind != :method && !params.empty?

      fn = IR::Function.new(name, kind: kind, line: node.location.start_line)
      params.each { |pname| fn.params << fn.local(pname) }
      fn.defaults = defaults
      @program.add_function(fn)
      @defs[name] = node
    end

    # Required and optional parameters. Optional parameters need literal
    # defaults, filled in by the caller.
    def method_params(node, name)
      ps = node.parameters
      return [[], []] if ps.nil?

      unsupported = ps.rest || !ps.posts.empty? || !ps.keywords.empty? || ps.keyword_rest || ps.block
      error("#{name}: only required and optional positional parameters are supported", node) if unsupported

      names = ps.requireds.map do |r|
        error("#{name}: destructuring parameters are not supported", r) unless r.is_a?(Prism::RequiredParameterNode)

        r.name.to_s
      end
      defaults = Array.new(names.size)
      ps.optionals.each do |o|
        scratch = IR::Function.new("(default)", kind: :method)
        default = with_function(scratch) { compile_expr(o.value) }
        # Defaults are filled in by the caller as constants, so anything that
        # emits code (e.g. puts) would silently lose its side effects.
        unless default.is_a?(IR::Const) && scratch.body.empty?
          error("#{name}: default value of #{o.name} must be a literal", o)
        end

        names << o.name.to_s
        defaults << default
      end
      [names, defaults]
    end

    def compile_method_body(body)
      case body
      when nil then IR::Const.nil
      when Prism::BeginNode then compile_begin(body, used: true)
      else compile_body(body, used: true)
      end
    end

    def compile_begin(node, used:)
      error("rescue / ensure are not supported yet", node) if node.rescue_clause || node.ensure_clause || node.else_clause

      compile_body(node.statements, used: used)
    end

    def compile_return(node)
      args = node.arguments&.arguments || []
      error("returning several values is not supported", node) if args.size > 1
      value = args.empty? ? IR::Const.nil : compile_expr(args.first)
      value = IR::Const.nil if @fn.entry_point?
      emit IR::Return.new(src: value)
      @terminated = true
      IR::Const.nil
    end

    def compile_method_call(node, name, args)
      fn = @program.functions[name.to_s]
      return nil if fn.nil? || fn.kind == :main

      error("#{name} does not take a block", node) if node.block
      min = fn.defaults.count(&:nil?)
      unless args.size.between?(min, fn.params.size)
        expected = min == fn.params.size ? min.to_s : "#{min}..#{fn.params.size}"
        error("wrong number of arguments for #{name} (given #{args.size}, expected #{expected})", node)
      end
      ops = args.map do |a|
        error("splat and keyword arguments are not supported", a) unless a.is_a?(Prism::Node) && !a.is_a?(Prism::SplatNode) && !a.is_a?(Prism::KeywordHashNode)

        v = compile_expr(a)
        # Snapshot each argument as it is evaluated: a later argument may
        # change a variable an earlier one read (f(x, x = 2)). A self-call
        # also assigns this frame's own parameters one by one, so there even
        # the last argument must not be a parameter slot.
        last = a.equal?(args.last) && fn.name != @fn.name
        last ? v : stable(v)
      end
      ops += fn.defaults[args.size..]
      dst = @fn.temp
      emit IR::Call.new(dst: dst, fn: fn.name, args: ops)
      # Assignment syntax (self.x = v) evaluates to v, not the setter's result.
      return ops.last if setter_assignment?(node)

      dst
    end

    def setter_assignment?(node)
      node.name.to_s.end_with?("=") && node.respond_to?(:attribute_write?) && node.attribute_write?
    end

    # --- Statements and expressions ---------------------------------------

    # Compiles a StatementsNode (or nil) and returns the operand holding the
    # value of its last statement (nil when used is false).
    def compile_body(node, used: true)
      return IR::Const.nil if node.nil?

      stmts = node.is_a?(Prism::StatementsNode) ? node.body : [node]
      return IR::Const.nil if stmts.empty?

      stmts[0..-2].each do |stmt|
        compile_expr(stmt, used: false)
        # Statements after an unconditional return never run.
        return IR::Const.nil if @terminated
      end
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
      when Prism::DefNode
        error("methods can only be defined at the top level", node) unless @fn.kind == :main && @block.equal?(@fn.body)

        IR::Const.nil
      when Prism::ReturnNode then compile_return(node)
      when Prism::BeginNode then compile_begin(node, used: used)
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
      then_body, then_assigned, then_term = branch do
        v = compile_expr_or_nil(then_node, used: used)
        emit IR::Move.new(dst: dst, src: v) if dst && !@terminated
      end
      else_body, else_assigned, else_term = branch do
        v = compile_expr_or_nil(else_node, used: used)
        emit IR::Move.new(dst: dst, src: v) if dst && !@terminated
      end
      then_body, else_body = else_body, then_body if negate
      @assigned.merge(merge_assigned(then_assigned, then_term, else_assigned, else_term))
      @terminated ||= then_term && else_term
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
          emit IR::Move.new(dst: dst, src: v) if dst && !@terminated
          next
        end
        w = whens[index]
        error("pattern matching (case/in) is not supported", w) unless w.is_a?(Prism::WhenNode)

        cond = when_condition(subject, w.conditions)
        then_body, then_assigned, then_term = branch do
          v = compile_body(w.statements, used: used)
          emit IR::Move.new(dst: dst, src: v) if dst && !@terminated
        end
        else_body, else_assigned, else_term = branch { build_when.call(index + 1) }
        @assigned.merge(merge_assigned(then_assigned, then_term, else_assigned, else_term))
        @terminated ||= then_term && else_term
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

      if recv.nil? || recv.is_a?(Prism::SelfNode)
        case name
        when :puts then return compile_print(node, args, :puts)
        when :p then return compile_print(node, args, :p, used: used)
        end
        result = compile_method_call(node, name, args)
        return result if result
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
