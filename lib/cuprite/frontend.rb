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
      saved = [@fn, @block, @assigned, @scopes, @loops, @terminated]
      @fn = fn
      @block = fn.body
      @assigned = Set.new(fn.params)
      # Ruby local scopes, innermost last: maps a Ruby name to its slot name.
      # The method scope maps names to themselves.
      @scopes = [{}]
      # Result slots of the enclosing loops, innermost last.
      @loops = []
      # Whether control has unconditionally left the method (return).
      @terminated = false
      yield
    ensure
      @fn, @block, @assigned, @scopes, @loops, @terminated = saved
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
      when Prism::LocalVariableReadNode then read_local(node.name, node.depth)
      when Prism::LocalVariableWriteNode then assign(local_slot(node.name, node.depth), node.value)
      when Prism::LocalVariableOperatorWriteNode
        op_assign(local_slot(node.name, node.depth), read_local(node.name, node.depth), node_operator(node), node.value)
      when Prism::LocalVariableOrWriteNode
        or_assign(local_slot(node.name, node.depth), read_local(node.name, node.depth), node.value)
      when Prism::LocalVariableAndWriteNode
        and_assign(local_slot(node.name, node.depth), read_local(node.name, node.depth), node.value)
      when Prism::WhileNode then compile_while(node, until_loop: false, used: used)
      when Prism::UntilNode then compile_while(node, until_loop: true, used: used)
      when Prism::ForNode then compile_for(node, used: used)
      when Prism::BreakNode then compile_break(node)
      when Prism::NextNode then compile_next(node)
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

    def local_slot(name, depth = 0)
      scope = @scopes[-1 - depth] or error("cannot resolve local variable #{name}")
      @fn.local(scope.fetch(name.to_s, name.to_s))
    end

    def read_local(name, depth = 0)
      slot = local_slot(name, depth)
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
      error("unsupported operator #{op}=") unless ARITH_OPS.include?(op)

      current = stable(current) unless pure?(value_node)
      value = compile_expr(value_node)

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

    # Whether evaluating `node` cannot change any variable, so operands
    # compiled before it need no snapshot (see #stable).
    def pure?(node)
      case node
      when nil, Prism::NilNode, Prism::TrueNode, Prism::FalseNode, Prism::IntegerNode,
           Prism::LocalVariableReadNode, Prism::GlobalVariableReadNode, Prism::StringNode
        true
      when Prism::ParenthesesNode then pure?(node.body)
      when Prism::StatementsNode then node.body.all? { |n| pure?(n) }
      when Prism::AndNode, Prism::OrNode then pure?(node.left) && pure?(node.right)
      when Prism::InterpolatedStringNode
        node.parts.all? { |part| part.is_a?(Prism::StringNode) || pure?(part.statements) }
      when Prism::CallNode
        args = node.arguments&.arguments || []
        operator = (ARITH_OPS + COMPARE_OPS).include?(node.name) && args.size == 1
        unary = %i[-@ +@ !].include?(node.name) && args.empty?
        node.receiver && !node.block && (operator || unary) && pure?(node.receiver) && args.all? { |a| pure?(a) }
      else
        false
      end
    end

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
          when :** then y.negative? ? (return nil) : x.pow(y, 1 << 32)
          end
      v &= 0xffff_ffff
      IR::Const.int(v >= 0x8000_0000 ? v - 0x1_0000_0000 : v)
    end

    def const_int(node)
      v = compile_expr(node)
      error("range bounds must be integer literals", node) unless v.is_a?(IR::Const) && v.type == :int

      v.value
    end

    # --- Loops (design §6.1: loops run to completion within the tick) -----

    # Runs the given block as a Loop body. Yields to emit the loop header
    # inside the body; the result slot (if used) holds nil unless a `break`
    # supplies a value.
    def emit_loop(used:, initial: IR::Const.nil)
      dst = used ? @fn.temp : nil
      emit IR::Move.new(dst: dst, src: initial) if dst
      before = @assigned.dup
      outer_terminated = @terminated
      @loops << dst
      body = into([]) { yield }
      @loops.pop
      # A loop body may not run at all: its assignments are not definite and
      # a return inside it does not end the code after the loop.
      @assigned = before
      @terminated = outer_terminated
      emit IR::Loop.new(body: body)
      dst || IR::Const.nil
    end

    # Emits `break unless cond` (or `break if cond` when negate).
    def break_unless(cond, negate: false)
      brk = [IR::Break.new(line: @line)]
      if negate
        emit IR::If.new(cond: cond, then_body: brk, else_body: [])
      else
        emit IR::If.new(cond: cond, then_body: [], else_body: brk)
      end
    end

    def compile_while(node, until_loop:, used:)
      if node.respond_to?(:begin_modifier?) && node.begin_modifier?
        error("begin ... end while is not supported; use loop with break", node)
      end

      emit_loop(used: used) do
        break_unless(compile_expr(node.predicate), negate: until_loop)
        compile_body(node.statements, used: false)
      end
    end

    def compile_loop_block(block, used:)
      with_block_scope(block) do
        emit_loop(used: used) { block_body { compile_body(block.body, used: false) } }
      end
    end

    # Integer#times / upto / downto and Range#each with a block.
    def compile_iterator(node, name, recv, args, used:)
      block = node.block
      return nil unless block.is_a?(Prism::BlockNode)

      case name
      when :times
        return nil unless args.empty?

        n = stable(compile_expr(recv))
        count_loop(block, IR::Const.int(0), n, step: 1, inclusive: false, used: used, result: n)
      when :upto, :downto
        return nil unless args.size == 1

        from = stable(compile_expr(recv))
        to = stable(compile_expr(args.first))
        count_loop(block, from, to, step: name == :upto ? 1 : -1, inclusive: true, used: used, result: from)
      when :each
        range = recv.is_a?(Prism::ParenthesesNode) ? recv.body&.body&.first : recv
        return nil unless range.is_a?(Prism::RangeNode) && args.empty?

        error("the value of Range#each is a Range, which is not supported (end the method or expression with nil if the value is not needed)", node) if used
        from, to, exclusive = range_bounds(range)
        count_loop(block, from, to, step: 1, inclusive: !exclusive, used: false, result: IR::Const.nil)
      end
    end

    def range_bounds(range)
      error("endless and beginless ranges cannot be iterated", range) unless range.left && range.right

      from = stable(compile_expr(range.left))
      to = stable(compile_expr(range.right))
      exclusive = range.respond_to?(:exclude_end?) ? range.exclude_end? : range.operator_loc.slice == "..."
      [from, to, exclusive]
    end

    # for i in a..b
    def compile_for(node, used:)
      target = node.index
      error("for needs a single loop variable", target) unless target.is_a?(Prism::LocalVariableTargetNode)
      range = node.collection
      range = range.body&.body&.first if range.is_a?(Prism::ParenthesesNode)
      error("for loops need an Integer range", node) unless range.is_a?(Prism::RangeNode)
      error("the value of a for loop is a Range, which is not supported (end the method or expression with nil if the value is not needed)", node) if used

      from, to, exclusive = range_bounds(range)
      var = local_slot(target.name, target.depth)
      counted_loop(from, to, step: 1, inclusive: !exclusive, var: var, used: false) do
        compile_body(node.statements, used: false)
      end
      IR::Const.nil
    end

    # A loop with a hidden counter from `from` towards `to`; the block's
    # first parameter (if any) receives the counter.
    def count_loop(block, from, to, step:, inclusive:, used:, result:)
      params = block_param_names(block)
      error("this block takes at most one parameter", block) if params.size > 1

      with_block_scope(block) do
        var = params.empty? ? nil : local_slot(params.first)
        # The iterator returns its receiver, or the value of a `break`.
        counted_loop(from, to, step: step, inclusive: inclusive, var: var, used: used, initial: result) do
          block_body([var].compact) { compile_body(block.body, used: false) }
        end
      end
    end

    # An inclusive loop stops after the iteration whose counter equals `to`
    # rather than stepping past it: past INT_MAX / INT_MIN the counter would
    # wrap around and still satisfy the bound.
    def counted_loop(from, to, step:, inclusive:, var:, used:, initial: IR::Const.nil)
      counter = @fn.temp
      emit IR::Move.new(dst: counter, src: from)
      emit IR::Arith.new(dst: counter, op: :-, a: counter, b: IR::Const.int(step))
      last = nil
      if inclusive
        last = @fn.temp
        emit IR::Move.new(dst: last, src: IR::Const.bool(false))
      end
      emit_loop(used: used, initial: initial) do
        break_unless(last, negate: true) if last
        emit IR::Arith.new(dst: counter, op: :+, a: counter, b: IR::Const.int(step))
        op = if step.positive?
               inclusive ? :<= : :<
             else
               inclusive ? :>= : :>
             end
        t = @fn.temp
        emit IR::Compare.new(dst: t, op: op, a: counter, b: to)
        break_unless(t)
        emit IR::Compare.new(dst: last, op: :==, a: counter, b: to) if last
        if var
          emit IR::Move.new(dst: var, src: counter)
          @assigned << var
        end
        yield
      end
    end

    def block_param_names(block)
      bp = block.parameters
      return [] if bp.nil?
      error("numbered block parameters are not supported", block) unless bp.is_a?(Prism::BlockParametersNode)

      ps = bp.parameters
      return [] if ps.nil?

      extra = !ps.optionals.empty? || ps.rest || !ps.posts.empty? || !ps.keywords.empty? || ps.keyword_rest || ps.block
      error("only simple block parameters are supported", block) if extra

      ps.requireds.map do |r|
        error("destructuring block parameters are not supported", r) unless r.is_a?(Prism::RequiredParameterNode)

        r.name.to_s
      end
    end

    # Opens a Ruby block scope: the block's own locals (parameters and
    # variables first assigned inside it) get slots distinct from any
    # outer variable with the same name.
    def with_block_scope(block)
      @block_scopes = (@block_scopes || 0) + 1
      id = @block_scopes
      @scopes << block.locals.to_h { |n| [n.to_s, "#{n}@#{id}"] }
      yield
    ensure
      @scopes.pop
    end

    # Compiles one invocation of a block's body. Locals owned by the block
    # start each invocation as nil, so those the body may read before
    # assigning are reset at its start.
    def block_body(params = [])
      start = @block.size
      yield
      resets = @scopes.last.values.map { |n| IR::Local.new(@fn.name, n) }.select do |slot|
        @fn.maybe_unassigned.include?(slot) && !params.include?(slot)
      end
      resets.reverse_each { |slot| @block.insert(start, IR::Move.new(dst: slot, src: IR::Const.nil, line: @line)) }
    end

    def compile_break(node)
      error("break outside of a loop", node) if @loops.empty?
      args = node.arguments&.arguments || []
      error("break with several values is not supported", node) if args.size > 1
      dst = @loops.last
      v = args.size == 1 ? compile_expr(args.first) : IR::Const.nil
      emit IR::Move.new(dst: dst, src: v) if dst
      emit IR::Break.new
      IR::Const.nil
    end

    def compile_next(node)
      error("next outside of a loop", node) if @loops.empty?
      (node.arguments&.arguments || []).each { |a| compile_expr(a, used: false) }
      emit IR::Next.new
      IR::Const.nil
    end

    # --- Calls -------------------------------------------------------------

    def compile_call(node, used:)
      name = node.name
      args = node.arguments&.arguments || []
      recv = node.receiver

      if recv && ARITH_OPS.include?(name) && args.size == 1 && !node.block
        a = compile_operand(recv, before: args.first)
        b = compile_expr(args.first)
        folded = fold(name, a, b)
        return folded if folded

        dst = @fn.temp
        emit IR::Arith.new(dst: dst, op: name, a: a, b: b)
        return dst
      end
      if recv && COMPARE_OPS.include?(name) && args.size == 1
        a = compile_operand(recv, before: args.first)
        b = compile_expr(args.first)
        dst = @fn.temp
        emit IR::Compare.new(dst: dst, op: name, a: a, b: b)
        return dst
      end
      if recv && args.empty? && !node.block
        case name
        when :-@
          v = compile_expr(recv)
          folded = fold(:-, IR::Const.int(0), v)
          return folded if folded

          dst = @fn.temp
          emit IR::Arith.new(dst: dst, op: :-, a: IR::Const.int(0), b: v)
          return dst
        when :+@
          v = compile_expr(recv)
          return v if v.is_a?(IR::Const) && v.type == :int

          # x + 0: a plain copy, but type-checked like other arithmetic.
          dst = @fn.temp
          emit IR::Arith.new(dst: dst, op: :+, a: v, b: IR::Const.int(0))
          return dst
        when :!
          dst = @fn.temp
          emit IR::Not.new(dst: dst, src: compile_expr(recv))
          return dst
        end
      end

      if recv && node.block && (result = compile_iterator(node, name, recv, args, used: used))
        return result
      end

      if recv.nil? || recv.is_a?(Prism::SelfNode)
        case name
        when :puts then return compile_print(node, args, :puts)
        when :p then return compile_print(node, args, :p, used: used)
        when :loop
          error("loop needs a block", node) unless node.block.is_a?(Prism::BlockNode) && args.empty?
          return compile_loop_block(node.block, used: used)
        end
        result = compile_method_call(node, name, args)
        return result if result
      end

      error("undefined method '#{name}'", node)
    end

    # Compiles `node`, copying the result if evaluating `later` (compiled
    # after it) could change the variable it reads.
    def compile_operand(node, before:)
      v = compile_expr(node)
      pure?(before) ? v : stable(v)
    end

    def compile_print(node, args, kind, used: false)
      error("#{kind} does not take a block", node) if node.block
      if kind == :puts
        lines = args.empty? ? [[]] : print_args(args, :to_s)
        emit IR::Print.new(lines: lines)
        return IR::Const.nil
      end

      lines = print_args(args, :inspect)
      emit IR::Print.new(lines: lines) unless lines.empty?
      return IR::Const.nil if args.empty? || !used

      error("p with several arguments returns an Array, which is not supported", node) if args.size > 1
      unless lines.first.size == 1 && lines.first.first.is_a?(Array)
        error("p with a String argument returns a String, which is not supported", node)
      end
      lines.first.first.first
    end

    # Printed lines for `args`. Values are read only when the Print runs, so
    # a value is snapshotted if a later argument could change it.
    def print_args(args, mode)
      args.each_with_index.map do |a, i|
        print_parts(a, mode, snapshot: !args[(i + 1)..].all? { |later| pure?(later) })
      end
    end

    # Parts of one printed line for argument node `arg`.
    def print_parts(arg, mode, snapshot: false)
      case arg
      when Prism::StringNode
        [mode == :inspect ? arg.unescaped.inspect : arg.unescaped]
      when Prism::InterpolatedStringNode
        parts = []
        parts << '"' if mode == :inspect
        arg.parts.each_with_index do |part, i|
          case part
          when Prism::StringNode
            parts << (mode == :inspect ? arg_inspect_inner(part.unescaped) : part.unescaped)
          when Prism::EmbeddedStatementsNode
            sub = part.statements&.body || []
            if sub.size == 1 && sub.first.is_a?(Prism::StringNode)
              str = sub.first.unescaped
              parts << (mode == :inspect ? arg_inspect_inner(str) : str)
            else
              v = compile_body(part.statements)
              later_pure = arg.parts[(i + 1)..].all? { |q| q.is_a?(Prism::StringNode) || pure?(q.statements) }
              v = stable(v) if snapshot || !later_pure
              parts << [v, :to_s]
            end
          else
            error("unsupported string interpolation", part)
          end
        end
        parts << '"' if mode == :inspect
        parts
      else
        v = compile_expr(arg)
        [[snapshot ? stable(v) : v, mode]]
      end
    end

    def arg_inspect_inner(str) = str.inspect[1..-2]
  end
end
