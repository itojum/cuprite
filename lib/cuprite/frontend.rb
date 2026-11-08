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
      root.statements.body.each do |stmt|
        case stmt
        when Prism::DefNode then declare_method(stmt)
        when Prism::ClassNode then declare_class(stmt)
        end
      end

      with_function(main) do
        compile_body(root.statements, used: false)
        emit IR::Return.new(src: IR::Const.nil)
      end
      @defs.each do |name, node|
        fn = @program.functions.fetch(name)
        with_function(fn) do
          @line = node.location.start_line
          value = compile_method_body(node.body)
          emit IR::Return.new(src: value)
        end
      end
      @program
    end

    private

    # --- Context -----------------------------------------------------------

    def with_function(fn)
      saved = [@fn, @block, @assigned, @scopes, @loops]
      @fn = fn
      @block = fn.body
      @assigned = Set.new(fn.params)
      # Ruby local scopes, innermost last: maps a Ruby name to its slot name.
      # The method scope maps names to themselves.
      @scopes = [{}]
      # Result slots of the enclosing loops, innermost last.
      @loops = []
      yield
    ensure
      @fn, @block, @assigned, @scopes, @loops = saved
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
        default = with_function(IR::Function.new("(default)", kind: :method)) { compile_expr(o.value) }
        error("#{name}: default value of #{o.name} must be a literal", o) unless default.is_a?(IR::Const)

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

    # --- Exceptions (design §7) -------------------------------------------

    def declare_class(node)
      @line = node.location.start_line
      name = constant_name(node.constant_path)
      superclass = node.superclass && constant_name(node.superclass)
      return declare_scoreboard(node, name) if superclass == "Cuprite::Scoreboard"

      unless superclass && @program.exceptions.known?(superclass)
        error("only exception classes (subclasses of StandardError and friends) can be defined", node)
      end
      error("class #{name} is already defined", node) if @program.exceptions.known?(name)
      error("exception classes cannot have a body", node) if node.body

      @program.exceptions.define(name, superclass)
    end

    # --- Minecraft interop (design §9) -------------------------------------

    OBJECTIVE_NAME = /\A[A-Za-z0-9_.+-]+\z/

    def declare_scoreboard(node, name)
      error("scoreboard class #{name} is already defined", node) if @program.scoreboards.key?(name)

      objectives = {}
      (node.body&.body || []).each do |stmt|
        unless stmt.is_a?(Prism::CallNode) && stmt.name == :objective && stmt.receiver.nil?
          error("a Cuprite::Scoreboard body may only contain objective declarations", stmt)
        end

        args = stmt.arguments&.arguments || []
        sym = args.first
        error("objective needs a symbol name", stmt) unless sym.is_a?(Prism::SymbolNode)

        method = sym.unescaped
        opts = args[1] ? keyword_args(args[1], %w[criteria name]) : {}
        error("objective takes a name and options", stmt) if args.size > 2
        objective = opts.fetch("name", method)
        error("invalid objective name #{objective.inspect}", stmt) unless objective.match?(OBJECTIVE_NAME)
        error("objective #{method} is declared twice", stmt) if objectives.key?(method)

        objectives[method] = IR::Objective.new(objective, opts.fetch("criteria", "dummy"))
      end
      @program.scoreboards[name] = objectives
    end

    # Literal keyword arguments: { "key" => String }.
    def keyword_args(node, allowed)
      error("expected keyword arguments", node) unless node.is_a?(Prism::KeywordHashNode)

      node.elements.to_h do |assoc|
        key = assoc.key
        error("expected keyword arguments", assoc) unless assoc.is_a?(Prism::AssocNode) && key.is_a?(Prism::SymbolNode)
        error("unknown keyword #{key.unescaped}", assoc) unless allowed.include?(key.unescaped)

        [key.unescaped, assoc.value]
      end.transform_values do |v|
        case v
        when Prism::SymbolNode then v.unescaped
        when Prism::StringNode then v.unescaped
        else v
        end
      end
    end

    # Cuprite.command "..." (design §9.2)
    def compile_command(node, args, used:)
      error("Cuprite.command takes one string", node) unless args.size == 1 && !node.block

      arg = args.first
      parts =
        case arg
        when Prism::StringNode then [arg.unescaped]
        when Prism::InterpolatedStringNode
          arg.parts.map do |part|
            case part
            when Prism::StringNode then part.unescaped
            when Prism::EmbeddedStatementsNode then compile_body(part.statements)
            else error("unsupported string interpolation", part)
            end
          end
        else error("Cuprite.command needs a string literal", arg)
        end
      first = parts.first
      parts[0] = first.delete_prefix("/") if first.is_a?(String)
      dst = used ? @fn.temp : nil
      emit IR::Command.new(dst: dst, parts: parts)
      dst || IR::Const.nil
    end

    SCORE_OPS = %w[get set add remove reset].freeze

    # Scores.kills.get(target: "@p") and friends (design §9.1).
    def compile_score_call(node, name, recv, args)
      return nil unless recv.is_a?(Prism::CallNode) && recv.receiver && recv.arguments.nil? && !recv.block
      return nil unless recv.receiver.is_a?(Prism::ConstantReadNode) || recv.receiver.is_a?(Prism::ConstantPathNode)

      board = @program.scoreboards[constant_name(recv.receiver)] or return nil
      objective = board[recv.name.to_s] or error("#{constant_name(recv.receiver)} has no objective #{recv.name}", recv)
      op = name.to_s
      error("unknown scoreboard operation #{op} (use #{SCORE_OPS.join(', ')})", node) unless SCORE_OPS.include?(op)

      kwargs = args.last.is_a?(Prism::KeywordHashNode) ? args.pop : nil
      opts = kwargs ? keyword_args(kwargs, %w[target]) : {}
      target = opts["target"]
      error("#{op} needs target: \"<selector or name>\"", node) unless target.is_a?(String)
      error("invalid score holder #{target.inspect}", node) if target.empty? || target.match?(/\s(?![^\[]*\])/)

      takes_value = %w[set add remove].include?(op)
      error("#{op} takes #{takes_value ? 'a value and ' : ''}target:", node) unless args.size == (takes_value ? 1 : 0)

      value = takes_value ? compile_expr(args.first) : nil
      dst = op == "get" ? @fn.temp : nil
      emit IR::Score.new(op: op.to_sym, dst: dst, objective: objective.name, target: target, value: value)
      dst || IR::Const.nil
    end

    CONTEXT_BLOCKS = { as: "as", at: "at", positioned: "positioned", rotated: "rotated", execute: nil }.freeze

    # as("@a") { ... }, at, positioned, rotated, execute("...") (design §9.3)
    def compile_context_block(node, name, args)
      block = node.block
      error("#{name} needs a block", node) unless block.is_a?(Prism::BlockNode)
      error("#{name} takes one string argument", node) unless args.size == 1
      if args.first.is_a?(Prism::KeywordHashNode) || args.size > 1
        error("#{name}: unsupported arguments", node)
      end
      arg = args.first
      error("#{name} needs a string literal argument", arg) unless arg.is_a?(Prism::StringNode)

      text = arg.unescaped.strip
      error("#{name} needs a non-empty argument", arg) if text.empty?
      subcommands = CONTEXT_BLOCKS[name] ? "#{CONTEXT_BLOCKS[name]} #{text}" : text.delete_prefix("execute ")
      error("#{name}: use the block instead of 'run'", arg) if subcommands.match?(/(?:\A| )run(?: |\z)/)
      error("block parameters are not supported for #{name}", block) if block.parameters

      body = with_block_scope(block) do
        @loops << :context
        before = @assigned.dup
        b = into([]) { compile_body(block.body, used: false) }
        @assigned = before
        @loops.pop
        b
      end
      emit IR::Exec.new(subcommands: subcommands, body: body, pending: @fn.temp, pending_exc: @fn.temp)
      IR::Const.nil
    end

    # "Foo" or "Cuprite::Foo" for a constant reference node.
    def constant_name(node)
      case node
      when Prism::ConstantReadNode then node.name.to_s
      when Prism::ConstantPathNode
        parent = node.respond_to?(:parent) ? node.parent : nil
        child = node.respond_to?(:name) ? node.name.to_s : node.child.name.to_s
        parent ? "#{constant_name(parent)}::#{child}" : child
      else error("expected a constant", node)
      end
    end

    def exception_class(node)
      name = constant_name(node)
      error("unknown exception class #{name}", node) unless @program.exceptions.known?(name)
      name
    end

    def compile_raise(node, args)
      error("raise needs an exception class or message (re-raising is not supported)", node) if args.empty?
      error("too many arguments for raise", node) if args.size > 2

      first = args.first
      klass, message =
        case first
        when Prism::StringNode then ["RuntimeError", first.unescaped]
        when Prism::ConstantReadNode, Prism::ConstantPathNode then [exception_class(first), nil]
        when Prism::CallNode
          unless first.name == :new && first.receiver && (first.arguments.nil? || first.arguments.arguments.size <= 1)
            error("raise needs an exception class or a string literal", first)
          end

          msg = first.arguments&.arguments&.first
          [exception_class(first.receiver), msg && string_literal(msg)]
        else error("raise needs an exception class or a string literal", first)
        end
      error("raise with a message needs an exception class first", node) if args.size == 2 && first.is_a?(Prism::StringNode)

      message = string_literal(args[1]) if args.size == 2
      emit IR::Raise.new(klass: klass, message: message || klass)
      IR::Const.nil
    end

    def string_literal(node)
      error("exception messages must be string literals", node) unless node.is_a?(Prism::StringNode)

      node.unescaped
    end

    def compile_begin(node, used:)
      if node.rescue_clause.nil? && node.ensure_clause.nil?
        error("else without rescue is not supported", node) if node.else_clause
        return compile_body(node.statements, used: used)
      end

      dst = used ? @fn.temp : nil
      before = @assigned.dup
      body, = branch do
        v = compile_body(node.statements, used: used && node.else_clause.nil?)
        emit IR::Move.new(dst: dst, src: v) if dst && node.else_clause.nil?
      end
      rescues = []
      clause = node.rescue_clause
      while clause
        if clause.reference
          error("rescue => variable is not supported", clause)
        end
        classes = clause.exceptions.map { |e| exception_class(e) }
        classes = ["StandardError"] if classes.empty?
        rbody, = branch do
          v = compile_body(clause.statements, used: used)
          emit IR::Move.new(dst: dst, src: v) if dst
        end
        rescues << IR::RescueClause.new(classes, rbody)
        clause = subsequent(clause)
      end
      else_body, = branch do
        if node.else_clause
          v = compile_body(node.else_clause.statements, used: used)
          emit IR::Move.new(dst: dst, src: v) if dst
        end
      end
      @assigned = before
      ensure_body = []
      if node.ensure_clause
        ensure_body = into([]) { compile_body(node.ensure_clause.statements, used: false) }
      end
      emit_try(body, rescues, else_body, ensure_body)
      dst || IR::Const.nil
    end

    def emit_try(body, rescues, else_body, ensure_body)
      emit IR::Try.new(body: body, rescues: rescues, else_body: else_body, ensure_body: ensure_body,
                       flag: @fn.temp, flag2: @fn.temp, saved_ctl: @fn.temp, saved_exc: @fn.temp,
                       saved_ret: @fn.temp)
    end

    # expr rescue fallback
    def compile_rescue_modifier(node, used:)
      dst = @fn.temp
      before = @assigned.dup
      body, = branch { emit IR::Move.new(dst: dst, src: compile_expr(node.expression)) }
      rbody, = branch { emit IR::Move.new(dst: dst, src: compile_expr(node.rescue_expression)) }
      @assigned = before
      emit_try(body, [IR::RescueClause.new(["StandardError"], rbody)], [], [])
      used ? dst : IR::Const.nil
    end

    def compile_return(node)
      error("return inside a context block (as, at, ...) is not supported", node) if @loops.include?(:context)
      args = node.arguments&.arguments || []
      error("returning several values is not supported", node) if args.size > 1
      value = args.empty? ? IR::Const.nil : compile_expr(args.first)
      value = IR::Const.nil if @fn.entry_point?
      emit IR::Return.new(src: value)
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
        # A self-call assigns this frame's own parameters, so later arguments
        # must not read a parameter that an earlier one has overwritten.
        fn.name == @fn.name ? stable(v) : v
      end
      ops += fn.defaults[args.size..]
      dst = @fn.temp
      emit IR::Call.new(dst: dst, fn: fn.name, args: ops)
      dst
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
      when Prism::RescueModifierNode then compile_rescue_modifier(node, used: used)
      when Prism::ClassNode
        error("classes can only be defined at the top level", node) unless @fn.kind == :main && @block.equal?(@fn.body)

        IR::Const.nil
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

    # --- Loops (design §6.1: loops run to completion within the tick) -----

    # Runs the given block as a Loop body. Yields to emit the loop header
    # inside the body; the result slot (if used) holds nil unless a `break`
    # supplies a value.
    def emit_loop(used:, initial: IR::Const.nil)
      dst = used ? @fn.temp : nil
      emit IR::Move.new(dst: dst, src: initial) if dst
      before = @assigned.dup
      @loops << dst
      body = into([]) { yield }
      @loops.pop
      # Assignments in a loop body may not happen at all.
      @assigned = before
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
        emit_loop(used: used) { compile_body(block.body, used: false) }
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
        counted_loop(from, to, step: step, inclusive: inclusive, var: var, used: false) do
          compile_body(block.body, used: false)
        end
      end
      used ? result : IR::Const.nil
    end

    def counted_loop(from, to, step:, inclusive:, var:, used:)
      counter = @fn.temp
      emit IR::Move.new(dst: counter, src: from)
      emit IR::Arith.new(dst: counter, op: :-, a: counter, b: IR::Const.int(step))
      emit_loop(used: used) do
        emit IR::Arith.new(dst: counter, op: :+, a: counter, b: IR::Const.int(step))
        op = if step.positive?
               inclusive ? :<= : :<
             else
               inclusive ? :>= : :>
             end
        t = @fn.temp
        emit IR::Compare.new(dst: t, op: op, a: counter, b: to)
        break_unless(t)
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

    def compile_break(node)
      error("break outside of a loop", node) if @loops.empty?
      error("break inside a context block (as, at, ...) is not supported; use next", node) if @loops.last == :context
      args = node.arguments&.arguments || []
      error("break with several values is not supported", node) if args.size > 1
      dst = @loops.last
      if args.size == 1 && dst.is_a?(IR::Local)
        v = compile_expr(args.first)
        emit IR::Move.new(dst: dst, src: v) if dst
      end
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

      if recv && node.block && (result = compile_iterator(node, name, recv, args, used: used))
        return result
      end
      if recv.is_a?(Prism::ConstantReadNode) && recv.name == :Cuprite && name == :command
        return compile_command(node, args, used: used)
      end
      if recv && (result = compile_score_call(node, name, recv, args.dup))
        return result
      end

      if recv.nil? || recv.is_a?(Prism::SelfNode)
        case name
        when :puts then return compile_print(node, args, :puts)
        when :p then return compile_print(node, args, :p, used: used)
        when :raise then return compile_raise(node, args)
        when *CONTEXT_BLOCKS.keys then return compile_context_block(node, name, args)
        when :loop
          error("loop needs a block", node) unless node.block.is_a?(Prism::BlockNode) && args.empty?
          return compile_loop_block(node.block, used: used)
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
