# frozen_string_literal: true

require "json"

module Cuprite
  # Lowers IR to .mcfunction commands.
  #
  # Conventions:
  # - Locals are fake players "$<fn>.<var>" in <ns>.vars, globals are "$<name>"
  #   in <ns>.globals, registers and constants live in <ns>.rt.
  # - nil is an unset score; booleans are 0/1.
  # - A method's return value is left in "$ret <ns>.rt".
  # - Nested blocks (if branches, ...) become functions under __b/. A block
  #   function ends with `return 0`; it returns 1 when control must leave the
  #   enclosing function too (return, and the cases added by later
  #   constructs). The caller then runs `execute if function <block> run
  #   return ...` to keep unwinding.
  # - "$ctl <ns>.rt" says why a block is unwinding: 0 for return,
  #   2 for break, 3 for next, 4 for a raised exception (the halt flag of
  #   design §7). Loops consume 2 and 3, rescue consumes 4.
  # - "$exc <ns>.rt" holds the raised exception's class ID; its class name
  #   and message are in storage <ns>:__runtime exc.
  class Codegen
    ANY = "-2147483648.."
    INT_MIN = -2_147_483_648
    INT_MAX = 2_147_483_647

    attr_reader :names, :constants

    def initialize(program, types, names, pack, test_mode: false, file: nil)
      @file = file
      @program = program
      @types = types
      @names = names
      @pack = pack
      @test_mode = test_mode
      @constants = Set.new
      @block_count = 0
    end

    def generate
      @calls = CallGraph.new(@program)
      compute_may_raise
      @program.functions.each_value { |fn| generate_function(fn) }
    end

    # Internal path of a method, used for calls from Ruby code. Entry points
    # are wrapped (truncation detection, uncaught exceptions), so Ruby calls
    # go to their body.
    def body_path(name)
      @program.functions.fetch(name).entry_point? ? "__body/#{name}" : function_path(name)
    end

    # Resource path of the function implementing Ruby method `name` (§4.5).
    def function_path(name)
      @paths ||= begin
        index = 0
        @program.functions.keys.to_h do |n|
          if n.match?(/\A[a-z0-9_]+\z/) && !n.start_with?("__")
            [n, n]
          else
            [n, "__m/#{index += 1}"]
          end
        end
      end
      @paths.fetch(name)
    end

    # Score reference "<holder> <objective>" for an operand slot.
    def ref(slot) = "#{holder(slot)} #{objective(slot)}"

    def holder(slot)
      case slot
      when IR::Local then "$#{slot.fn}.#{slot.name}"
      when IR::Global then slot.name
      when :ret then "$ret"
      when :scratch then "$t"
      else raise ArgumentError, "not a slot: #{slot.inspect}"
      end
    end

    def objective(slot)
      case slot
      when IR::Local then names.vars
      when IR::Global then names.globals
      else names.rt
      end
    end

    def const_ref(value)
      @constants << value
      "#{names.const(value)} #{names.rt}"
    end

    def rt(register) = "$#{register} #{names.rt}"

    # Text component "[ns] Class: message" for an error compound in storage.
    def error_text(path)
      st = names.storage
      %({"text":"[#{names.ns}] ","color":"red","extra":[{"nbt":"#{path}.class","storage":"#{st}"},) +
        %({"text":": "},{"nbt":"#{path}.message","storage":"#{st}"}]})
    end

    # Shared runtime helper functions, emitted on first use.
    def helper(name)
      path = "__#{name}"
      unless @pack.function?(path)
        lines = case name
                when :break then ["scoreboard players set #{rt(:ctl)} 2", "return 1"]
                when :next then ["scoreboard players set #{rt(:ctl)} 3", "return 1"]
                when :truncated
                  ["scoreboard players set #{rt(:ctl)} 0",
                   "data remove storage #{names.storage} stack",
                   "data modify storage #{names.storage} last_error set value " \
                   "{class:\"truncated\",message:\"the previous run hit the command chain limit\"}",
                   "execute if score #{rt(:debug)} matches 1 run tellraw @a " \
                   "{\"text\":\"[#{names.ns}] previous run was truncated by the command chain limit\",\"color\":\"red\"}"]
                when :uncaught
                  ["data modify storage #{names.storage} last_error set from storage #{names.storage} exc",
                   "execute if score #{rt(:debug)} matches 1 run tellraw @a #{error_text('exc')}",
                   "scoreboard players set #{rt(:ctl)} 0"]
                when :loop_exit
                  ["execute unless score #{rt(:ctl)} matches 2 run return 1",
                   "scoreboard players set #{rt(:ctl)} 0",
                   "return 0"]
                end
        @pack.add_function(path, lines)
      end
      names.function(path)
    end

    private

    def generate_function(fn)
      @fn = fn
      @nested = false
      @print_slots = 0
      lines = []
      fn.maybe_unassigned.each { |v| lines << "scoreboard players reset #{ref(v)}" }
      lines.concat(compile_block(fn.body))
      lines.pop if lines.last == "return 0" && fn.entry_point?
      @pack.add_function(body_path(fn.name), lines)
      generate_entry_wrapper(fn) if fn.entry_point?
    end

    # <ns>:main, on_load, on_tick: detect a truncated previous run (§6.7),
    # run the body, then report an uncaught exception (§7).
    def generate_entry_wrapper(fn)
      lines = [
        "execute if score #{rt(:running)} matches 1 run function #{helper(:truncated)}",
        "scoreboard players set #{rt(:running)} 1",
        "function #{names.function(body_path(fn.name))}"
      ]
      lines << "execute if score #{rt(:ctl)} matches 4 run function #{helper(:uncaught)}" if may_raise?(fn.name)
      lines << "scoreboard players set #{rt(:running)} 0"
      @pack.add_function(function_path(fn.name), lines)
    end

    # --- Exceptions --------------------------------------------------------

    def compute_may_raise
      @may_raise = Set.new
      loop do
        changed = false
        @program.functions.each_value do |fn|
          next if @may_raise.include?(fn.name)

          found = false
          IR.each_instr(fn.body) { |ins| found ||= raises_directly?(ins) }
          if found
            @may_raise << fn.name
            changed = true
          end
        end
        break unless changed
      end
    end

    def may_raise?(name) = @may_raise.include?(name)

    def raises_directly?(ins)
      case ins
      when IR::Raise then true
      when IR::Call then may_raise?(ins.fn)
      when IR::Arith then arith_checks?(ins)
      when IR::Compare then compare_checks?(ins)
      when IR::Score then ins.value && @types.nilable?(ins.value)
      else false
      end
    end

    def exec_raises?(ins)
      found = false
      IR.each_instr(ins.body) { |i| found ||= raises_directly?(i) }
      found
    end

    def arith_checks?(ins)
      return false if ins.a.is_a?(IR::Const) && ins.b.is_a?(IR::Const) && fold(ins.op, ins.a.value, ins.b.value)

      [ins.a, ins.b].any? { |x| @types.nilable?(x) } ||
        (%i[/ %].include?(ins.op) && !(ins.b.is_a?(IR::Const) && ins.b.value != 0))
    end

    def compare_checks?(ins)
      !%i[== !=].include?(ins.op) && [ins.a, ins.b].any? { |x| @types.nilable?(x) }
    end

    # A one-command raise of klass with message.
    def raise_command(klass, message)
      @raisers ||= {}
      key = [klass, message]
      @raisers[key] ||= begin
        path = "__raise/#{@raisers.size + 1}"
        exc = { "class" => klass, "message" => message }
        @pack.add_function(path, [
          "scoreboard players set #{rt(:exc)} #{@program.exceptions.id(klass)}",
          "data modify storage #{names.storage} exc set value #{snbt(exc)}",
          "scoreboard players set #{rt(:ctl)} 4",
          "return 1"
        ])
        names.function(path)
      end
      "return run function #{@raisers[key]}"
    end

    def snbt(hash)
      "{" + hash.map { |k, v| "#{k}:#{JSON.generate(v)}" }.join(",") + "}"
    end

    # Raises NoMethodError when operand is nil.
    def check_not_nil(operand, op, out)
      return unless @types.nilable?(operand)

      cmd = raise_command("NoMethodError", "undefined method '#{op}' for nil")
      if operand.is_a?(IR::Const) || types_of(operand) == Set[:nil]
        out << cmd
      else
        out << "execute unless score #{ref(operand)} matches #{ANY} run #{cmd}"
      end
    end

    # begin/rescue/else/ensure. See the class comment for the protocol.
    #
    # TRY (body, rescue and else):
    #   execute store success score F if function BODY
    #   execute if score F matches 0 run return run function ELSE
    #   execute unless score $ctl matches 4 run return 1
    #   execute if score $exc matches <ids of rescue 1> run return run function RESCUE1
    #   ...
    #   return 1
    #
    # With ensure, a wrapper runs TRY, saves $ctl / $exc, runs ENSURE with
    # $ctl cleared, then restores them and keeps unwinding if TRY did.
    def compile_try(ins, out)
      try_lines = []
      body = compile_nested(ins.body)
      body_fn = new_block_function(body + ["return 0"])
      try_lines << "execute store success score #{ref(ins.flag)} if function #{body_fn}"
      else_lines = compile_nested(ins.else_body)
      try_lines << if else_lines.empty?
                     "execute if score #{ref(ins.flag)} matches 0 run return 0"
                   else
                     "execute if score #{ref(ins.flag)} matches 0 run return run function " \
                       "#{new_block_function(else_lines + ['return 0'])}"
                   end
      try_lines << "execute unless score #{rt(:ctl)} matches 4 run return 1"
      ins.rescues.each do |clause|
        rescue_fn = new_block_function(["scoreboard players set #{rt(:ctl)} 0"] + compile_nested(clause.body) +
                                       ["return 0"])
        clause.classes.each do |klass|
          r = @program.exceptions.range(klass)
          try_lines << "execute if score #{rt(:exc)} matches #{r.first}..#{r.last} run return run function #{rescue_fn}"
        end
      end
      try_lines << "return 1"
      try_fn = new_block_function(try_lines)

      if ins.ensure_body.empty?
        out << "execute if function #{try_fn} run #{unwind}"
        return
      end

      ensure_lines = compile_nested(ins.ensure_body)
      ensure_fn = new_block_function(ensure_lines + ["return 0"])
      wrapper = [
        "execute store success score #{ref(ins.flag2)} if function #{try_fn}",
        "scoreboard players operation #{ref(ins.saved_ctl)} = #{rt(:ctl)}",
        "scoreboard players operation #{ref(ins.saved_exc)} = #{rt(:exc)}",
        "scoreboard players set #{rt(:ctl)} 0",
        "execute if function #{ensure_fn} run return 1",
        "scoreboard players operation #{rt(:ctl)} = #{ref(ins.saved_ctl)}",
        "scoreboard players operation #{rt(:exc)} = #{ref(ins.saved_exc)}",
        "execute if score #{ref(ins.flag2)} matches 1 run return 1",
        "return 0"
      ]
      out << "execute if function #{new_block_function(wrapper)} run #{unwind}"
    end

    def compile_block(block)
      out = []
      block.each do |ins|
        @line = ins.line
        compile_instr(ins, out)
      end
      out
    end

    # Compiles `block` as the body of a nested block function.
    def compile_nested(block)
      saved = @nested
      @nested = true
      compile_block(block)
    ensure
      @nested = saved
    end

    # The command that leaves the current function while unwinding.
    def unwind = @nested ? "return 1" : "return 0"

    def new_block_function(lines)
      @block_count += 1
      path = "__b/#{@block_count}"
      @pack.add_function(path, lines)
      names.function(path)
    end

    # Runs `block` under the execute prefix (e.g. "execute if score ...").
    def call_block(block, out, prefix)
      lines = compile_nested(block)
      return if lines.empty?

      unwinds = may_unwind?(block)
      # A single command can run in place. If it unwinds, it does so with
      # `return ...`, which leaves the enclosing function just as well; a
      # function at the top of a method ignores the value returned.
      if lines.size == 1
        out << (prefix == "execute" ? lines.first : "#{prefix} run #{lines.first}")
        return
      end
      fn = new_block_function(lines + ["return 0"])
      out << if unwinds
               "#{prefix} if function #{fn} run #{unwind}"
             else
               (prefix == "execute" ? "function #{fn}" : "#{prefix} run function #{fn}")
             end
    end

    # Whether running `block` can make control leave the enclosing function.
    def may_unwind?(block)
      block.any? { |ins| instr_unwinds?(ins) }
    end

    def instr_unwinds?(ins)
      case ins
      when IR::Return, IR::Break, IR::Next, IR::Raise, IR::Try then true
      when IR::If then may_unwind?(ins.then_body) || may_unwind?(ins.else_body)
      when IR::Loop then escapes_loop?(ins.body)
      when IR::Exec then exec_raises?(ins)
      else raises_directly?(ins)
      end
    end

    # Whether control can leave a loop with this body other than by its own
    # break: break and next are consumed by the loop.
    def escapes_loop?(block)
      block.any? do |ins|
        case ins
        when IR::Break, IR::Next then false
        when IR::If then escapes_loop?(ins.then_body) || escapes_loop?(ins.else_body)
        when IR::Loop then escapes_loop?(ins.body)
        else instr_unwinds?(ins)
        end
      end
    end

    # Whether `next` can reach the loop with this body.
    def has_next?(block)
      block.any? do |ins|
        case ins
        when IR::Next then true
        when IR::If then has_next?(ins.then_body) || has_next?(ins.else_body)
        else false
        end
      end
    end

    def compile_instr(ins, out)
      case ins
      when IR::Move then move(ins.dst, ins.src, out)
      when IR::Arith then arith(ins, out)
      when IR::Compare then compare(ins, out)
      when IR::InRange then in_range(ins, out)
      when IR::Not then logical_not(ins, out)
      when IR::If then compile_if(ins, out)
      when IR::Print then print(ins, out)
      when IR::Return then compile_return(ins, out)
      when IR::Call then call(ins, out)
      when IR::Loop then compile_loop(ins, out)
      when IR::Raise then out << raise_command(ins.klass, ins.message)
      when IR::Command then command(ins, out)
      when IR::Score then score(ins, out)
      when IR::Exec then compile_exec(ins, out)
      when IR::Try then compile_try(ins, out)
      when IR::Break then out << "return run function #{helper(:break)}"
      when IR::Next then out << "return run function #{helper(:next)}"
      else
        raise Error, "codegen: unsupported instruction #{ins.class}"
      end
    end

    def error(message)
      raise CompileError.new(message, file: @file, line: @line)
    end

    def types_of(operand) = @types.of(operand)

    # --- Moves -------------------------------------------------------------

    # dst = src, where src may be a constant, a slot, or nil.
    def move(dst, src, out)
      case src
      when IR::Const
        out << if src.value.nil?
                 "scoreboard players reset #{ref(dst)}"
               else
                 "scoreboard players set #{ref(dst)} #{src.value}"
               end
      else
        return if src == dst

        if @types.nilable?(src)
          out << "scoreboard players reset #{ref(dst)}" unless types_of(src) == Set[:nil]
          out << if types_of(src) == Set[:nil]
                   "scoreboard players reset #{ref(dst)}"
                 else
                   "execute if score #{ref(src)} matches #{ANY} run scoreboard players operation #{ref(dst)} = #{ref(src)}"
                 end
        else
          out << "scoreboard players operation #{ref(dst)} = #{ref(src)}"
        end
      end
    end

    def compile_return(ins, out)
      move(:ret, ins.src, out) unless @fn.entry_point?
      out << unwind
    end

    # --- Minecraft interop -------------------------------------------------

    # Cuprite.command. Literal commands are emitted as they are; interpolated
    # integers go through a function macro (design §9.2).
    def command(ins, out)
      dynamic = ins.parts.reject { |p| p.is_a?(String) }
      dynamic.each do |v|
        error("only Integers can be interpolated into commands") unless types_of(v) == Set[:int]
      end
      if dynamic.empty? || dynamic.all? { |v| v.is_a?(IR::Const) }
        line = ins.parts.map { |p| p.is_a?(String) ? p : p.value.to_s }.join
        error("Cuprite.command needs a single-line command") if line.include?("\n")
        out << (ins.dst ? "execute store result score #{ref(ins.dst)} run #{line}" : line)
        return
      end

      template = +""
      args = []
      ins.parts.each do |p|
        if p.is_a?(String)
          error("Cuprite.command needs a single-line command") if p.include?("\n")
          template << p
        elsif p.is_a?(IR::Const)
          template << p.value.to_s
        else
          key = "a#{args.size}"
          args << [key, p]
          template << "$(#{key})"
        end
      end
      @macros ||= {}
      path = @macros[template] ||= begin
        mpath = "__cmd/#{@macros.size + 1}"
        @pack.add_function(mpath, ["$return run #{template}"])
        mpath
      end
      args.each do |key, v|
        out << "execute store result storage #{names.storage} args.#{key} int 1 run scoreboard players get #{ref(v)}"
      end
      call = "function #{names.function(path)} with storage #{names.storage} args"
      out << (ins.dst ? "execute store result score #{ref(ins.dst)} run #{call}" : call)
    end

    def score(ins, out)
      target = "#{ins.target} #{ins.objective}"
      case ins.op
      when :get
        out << "scoreboard players reset #{ref(ins.dst)}"
        out << "execute if score #{target} matches #{ANY} run scoreboard players operation #{ref(ins.dst)} = #{target}"
      when :reset
        out << "scoreboard players reset #{target}"
      else
        v = ins.value
        error("scoreboard #{ins.op} needs an Integer") if types_of(v).include?(:bool)
        check_not_nil(v, ins.op, out)
        if v.is_a?(IR::Const)
          n = v.value
          case ins.op
          when :set then out << "scoreboard players set #{target} #{n}"
          when :add, :remove
            n = -n if ins.op == :remove
            out << if n == INT_MIN
                     "scoreboard players operation #{target} += #{const_ref(n)}"
                   elsif n >= 0
                     "scoreboard players add #{target} #{n}"
                   else
                     "scoreboard players remove #{target} #{-n}"
                   end
          end
        else
          op = { set: "=", add: "+=", remove: "-=" }.fetch(ins.op)
          out << "scoreboard players operation #{target} #{op} #{ref(v)}"
        end
      end
    end

    # A context block. The body runs once per execution context created by
    # the subcommands (e.g. once per entity for `as @a`). If the body can
    # raise, each run goes through a wrapper that keeps the first exception
    # aside so the other entities still run; it is re-raised afterwards
    # (design §9.3). `next` ends the current entity's run.
    def compile_exec(ins, out)
      prefix = "execute #{ins.subcommands}"
      raises = exec_raises?(ins)
      nexts = has_next?(ins.body)
      unless raises || nexts
        call_block(ins.body, out, prefix)
        return
      end

      body_fn = new_block_function(compile_nested(ins.body) + ["return 0"])
      wrapper = ["function #{body_fn}"]
      saved_exc = "#{names.storage} pending_exc.b#{@block_count}"
      if raises
        record = new_block_function([
          "scoreboard players set #{ref(ins.pending)} 1",
          "scoreboard players operation #{ref(ins.pending_exc)} = #{rt(:exc)}",
          "data modify storage #{saved_exc} set from storage #{names.storage} exc"
        ])
        wrapper << "execute if score #{rt(:ctl)} matches 4 unless score #{ref(ins.pending)} matches 1 run function #{record}"
      end
      wrapper << "scoreboard players set #{rt(:ctl)} 0"
      wrapper_fn = new_block_function(wrapper)
      out << "scoreboard players set #{ref(ins.pending)} 0" if raises
      out << "#{prefix} run function #{wrapper_fn}"
      return unless raises

      reraise = new_block_function([
        "scoreboard players operation #{rt(:exc)} = #{ref(ins.pending_exc)}",
        "data modify storage #{names.storage} exc set from storage #{saved_exc}",
        "scoreboard players set #{rt(:ctl)} 4",
        "return 1"
      ])
      out << "execute if score #{ref(ins.pending)} matches 1 run return run function #{reraise}"
    end

    # --- Loops -------------------------------------------------------------

    # A loop is a tail-recursive function L around a body function B:
    #
    #   execute if function B unless score $ctl matches 3 run return run function __loop_exit
    #   scoreboard players set $ctl 0      (only when the body uses next)
    #   return run function L
    #
    # __loop_exit turns a break into a normal (0) return and keeps any other
    # unwind going (1).
    def compile_loop(ins, out)
      @block_count += 1
      path = "__b/#{@block_count}"
      loop_fn = names.function(path)
      body = compile_nested(ins.body)
      lines = []
      if may_unwind?(ins.body)
        body_fn = new_block_function(body + ["return 0"])
        lines << "execute if function #{body_fn} unless score #{rt(:ctl)} matches 3 " \
                 "run return run function #{helper(:loop_exit)}"
        lines << "scoreboard players set #{rt(:ctl)} 0" if has_next?(ins.body)
      else
        # Without break the loop never ends normally; it can only be cut short
        # by the command chain limit.
        lines.concat(body)
      end
      lines << "return run function #{loop_fn}"
      @pack.add_function(path, lines)
      out << if escapes_loop?(ins.body)
               "execute if function #{loop_fn} run #{unwind}"
             else
               "function #{loop_fn}"
             end
    end

    # --- Calls -------------------------------------------------------------

    def call(ins, out)
      callee = @program.functions.fetch(ins.fn)
      recursive = @calls.recursive_call?(@fn.name, callee.name)
      # Save first: in a self-call the parameters being assigned are this
      # frame's own.
      saved = recursive ? save_locals(ins, out) : []
      callee.params.zip(ins.args).each { |param, arg| move(param, arg, out) }
      out << "function #{names.function(body_path(callee.name))}"
      restore_locals(saved, out) if recursive
      out << "execute if score #{rt(:ctl)} matches 4 run #{unwind}" if may_raise?(callee.name)
      ret_type = @types.return_type(callee.name)
      if ret_type == Set[:nil]
        out << "scoreboard players reset #{ref(ins.dst)}"
      elsif ret_type.include?(:nil)
        out << "scoreboard players reset #{ref(ins.dst)}"
        out << "execute if score #{ref(:ret)} matches #{ANY} run scoreboard players operation #{ref(ins.dst)} = #{ref(:ret)}"
      else
        move_raw(ins.dst, :ret, out)
      end
    end

    # Pushes this frame's locals onto the storage stack before a call that
    # may re-enter the current function (design §5). Unset locals are left
    # out of the frame and come back unset.
    def save_locals(ins, out)
      locals = (@fn.locals.to_a - [ins.dst]).sort_by(&:name)
      stack = "#{names.storage} stack"
      out << "data modify storage #{stack} append value {}"
      locals.each_with_index do |v, i|
        out << "execute if score #{ref(v)} matches #{ANY} store result storage #{stack}[-1].v#{i} int 1 " \
               "run scoreboard players get #{ref(v)}"
      end
      locals
    end

    def restore_locals(locals, out)
      stack = "#{names.storage} stack"
      locals.each_with_index do |v, i|
        out << "scoreboard players reset #{ref(v)}" if @types.nilable?(v)
        out << "execute if data storage #{stack}[-1].v#{i} store result score #{ref(v)} " \
               "run data get storage #{stack}[-1].v#{i}"
      end
      out << "data remove storage #{stack}[-1]"
    end

    # --- Arithmetic --------------------------------------------------------

    OPERATION = { :+ => "+=", :- => "-=", :* => "*=", :/ => "/=", :% => "%=" }.freeze

    def arith(ins, out)
      dst, op, a, b = ins.dst, ins.op, ins.a, ins.b
      [a, b].each do |x|
        error("#{op} is only defined for Integers here") if types_of(x).include?(:bool)
      end

      if a.is_a?(IR::Const) && b.is_a?(IR::Const) && (folded = fold(op, a.value, b.value))
        return move(dst, IR::Const.int(folded), out)
      end

      check_not_nil(a, op, out)
      check_not_nil(b, op, out) unless b == a
      if %i[/ %].include?(op)
        if b.is_a?(IR::Const)
          return out << raise_command("ZeroDivisionError", "divided by 0") if b.value.zero?
        else
          out << "execute if score #{ref(b)} matches 0 run #{raise_command('ZeroDivisionError', 'divided by 0')}"
        end
      end

      if op == :**
        unless b.is_a?(IR::Const) && b.value.is_a?(Integer) && b.value >= 0
          error("** needs a non-negative integer literal exponent")
        end
        src = a
        if a == dst
          move(:scratch, a, out)
          src = :scratch
        end
        out << "scoreboard players set #{ref(dst)} 1"
        b.value.times { apply_op(dst, :*, src, out) }
        return
      end

      if b == dst && a != dst
        move(:scratch, a, out)
        apply_op(:scratch, op, b, out)
        move_raw(dst, :scratch, out)
      else
        move(dst, a, out)
        apply_op(dst, op, b, out)
      end
    end

    def move_raw(dst, src, out)
      out << "scoreboard players operation #{ref(dst)} = #{ref(src)}"
    end

    # dst op= b
    def apply_op(dst, op, b, out)
      if b.is_a?(IR::Const)
        v = b.value
        if %i[+ -].include?(op) && v != INT_MIN
          v = -v if op == :-
          return if v.zero?

          out << (v.positive? ? "scoreboard players add #{ref(dst)} #{v}" : "scoreboard players remove #{ref(dst)} #{-v}")
          return
        end
        out << "scoreboard players operation #{ref(dst)} #{OPERATION.fetch(op)} #{const_ref(v)}"
      else
        out << "scoreboard players operation #{ref(dst)} #{OPERATION.fetch(op)} #{ref(b)}"
      end
    end

    def fold(op, a, b)
      return nil if a.nil? || b.nil?

      v = case op
          when :+ then a + b
          when :- then a - b
          when :* then a * b
          when :/ then b.zero? ? (return nil) : a.div(b)
          when :% then b.zero? ? (return nil) : a.modulo(b)
          when :** then b.negative? || b > 64 ? (return nil) : a.pow(b, 1 << 32)
          end
      wrap(v)
    end

    def wrap(v)
      v &= 0xffff_ffff
      v >= 0x8000_0000 ? v - 0x1_0000_0000 : v
    end

    # --- Comparisons -------------------------------------------------------

    MIRROR = { :< => :>, :<= => :>=, :> => :<, :>= => :<=, :== => :==, :!= => :!= }.freeze

    def set_bool(dst, value, out) = move(dst, IR::Const.bool(value), out)

    def compare(ins, out)
      dst, op, a, b = ins.dst, ins.op, ins.a, ins.b
      if a.is_a?(IR::Const) && !b.is_a?(IR::Const)
        a, b = b, a
        op = MIRROR.fetch(op)
      end

      if %i[== !=].include?(op)
        equality(dst, a, b, out, negate: op == :!=)
      else
        [a, b].each do |x|
          error("comparison with #{op} is only defined for Integers") unless (types_of(x) - [:nil]).subset?(Set[:int])
        end
        check_not_nil(a, op, out)
        check_not_nil(b, op, out)
        if b.is_a?(IR::Const)
          if a.is_a?(IR::Const)
            return set_bool(dst, a.value.public_send(op, b.value), out)
          end

          range = const_range(op, b.value)
          return set_bool(dst, false, out) if range.nil?

          out << "execute store success score #{ref(dst)} if score #{ref(a)} matches #{range}"
        else
          out << "execute store success score #{ref(dst)} if score #{ref(a)} #{op} #{ref(b)}"
        end
      end
    end

    def const_range(op, v)
      case op
      when :< then v == INT_MIN ? nil : "..#{v - 1}"
      when :<= then "..#{v}"
      when :> then v == INT_MAX ? nil : "#{v + 1}.."
      when :>= then "#{v}.."
      end
    end

    def equality(dst, a, b, out, negate:)
      ta = types_of(a)
      tb = types_of(b)
      if a.is_a?(IR::Const) && b.is_a?(IR::Const)
        return set_bool(dst, (a.type == b.type && a.value == b.value) != negate, out)
      end

      cond = if b.is_a?(IR::Const) && b.type == :nil
               "unless score #{ref(a)} matches #{ANY}"
             elsif ((ta - [:nil]) & (tb - [:nil])).empty?
               # Only nil == nil can be true.
               return set_bool(dst, negate, out) unless ta.include?(:nil) && tb.include?(:nil)

               "unless score #{ref(a)} matches #{ANY} unless score #{ref(b)} matches #{ANY}"
             elsif b.is_a?(IR::Const)
               "if score #{ref(a)} matches #{b.value}"
             elsif ta.include?(:nil) && tb.include?(:nil)
               out << "execute store success score #{ref(dst)} if score #{ref(a)} = #{ref(b)}"
               out << "execute unless score #{ref(a)} matches #{ANY} unless score #{ref(b)} matches #{ANY} " \
                      "run scoreboard players set #{ref(dst)} 1"
               out << "execute store success score #{ref(dst)} if score #{ref(dst)} matches 0" if negate
               return
             else
               "if score #{ref(a)} = #{ref(b)}"
             end
      if negate && cond.scan(/(?:\A| )(?:if|unless) /).size == 1
        cond = cond.start_with?("if ") ? cond.sub(/\Aif /, "unless ") : cond.sub(/\Aunless /, "if ")
        negate = false
      end
      out << "execute store success score #{ref(dst)} #{cond}"
      out << "execute store success score #{ref(dst)} if score #{ref(dst)} matches 0" if negate
    end

    def in_range(ins, out)
      error("range tests are only defined for Integers") unless (types_of(ins.src) - [:nil]).subset?(Set[:int])
      if ins.src.is_a?(IR::Const)
        v = ins.src.value
        return set_bool(ins.dst, !v.nil? && (ins.lo.nil? || v >= ins.lo) && (ins.hi.nil? || v <= ins.hi), out)
      end
      return set_bool(ins.dst, false, out) if ins.lo && ins.hi && ins.lo > ins.hi

      range = "#{ins.lo}..#{ins.hi}"
      range = ANY if range == ".."
      out << "execute store success score #{ref(ins.dst)} if score #{ref(ins.src)} matches #{range}"
    end

    # --- Truthiness and branches ------------------------------------------

    # :always, :never, or an execute condition (without if/unless) that holds
    # when `operand` is truthy.
    def truth_test(operand)
      if operand.is_a?(IR::Const)
        return operand.type == :nil || (operand.type == :bool && operand.value.zero?) ? :never : :always
      end

      t = types_of(operand)
      return :never if t == Set[:nil]
      return :always if t == Set[:int]
      return "score #{ref(operand)} matches 1" if t.include?(:bool)

      "score #{ref(operand)} matches #{ANY}"
    end

    def logical_not(ins, out)
      case (test = truth_test(ins.src))
      when :always then set_bool(ins.dst, false, out)
      when :never then set_bool(ins.dst, true, out)
      else out << "execute store success score #{ref(ins.dst)} unless #{test}"
      end
    end

    def compile_if(ins, out)
      case (test = truth_test(ins.cond))
      when :always then out.concat(compile_block(ins.then_body))
      when :never then out.concat(compile_block(ins.else_body))
      else
        call_block(ins.then_body, out, "execute if #{test}") unless ins.then_body.empty?
        call_block(ins.else_body, out, "execute unless #{test}") unless ins.else_body.empty?
      end
    end

    # --- Output ------------------------------------------------------------

    def print(ins, out)
      ins.lines.each { |parts| print_line(parts, out) }
    end

    # One printed line: tellraw (debug mode only) plus, in test mode, a copy
    # in storage <ns>:__test out as a list of {s:"..."} / {i:N} parts.
    def print_line(parts, out)
      components = []
      mirror = []
      parts.each do |part|
        case part
        when String then add_text(part, components, mirror)
        else
          operand, mode = part
          print_operand(operand, mode, components, mirror, out)
        end
      end
      text = components.empty? ? %({"text":""}) : %({"text":"","extra":[#{components.join(',')}]})
      out << "execute if score $debug #{names.rt} matches 1 run tellraw @a #{text}"
      return unless @test_mode

      out << "data modify storage #{names.test_storage} out append value []"
      mirror.each do |kind, value|
        case kind
        when :s then out << "data modify storage #{names.test_storage} out[-1] append value {s:#{JSON.generate(value)}}"
        when :score
          out << "data modify storage #{names.test_storage} out[-1] append value {i:0}"
          out << "execute store result storage #{names.test_storage} out[-1][-1].i int 1 " \
                 "run scoreboard players get #{ref(value)}"
        when :slot
          out << "data modify storage #{names.test_storage} out[-1] append from storage #{names.storage} #{value}"
        end
      end
    end

    def add_text(str, components, mirror)
      return if str.empty?

      if mirror.last&.first == :s
        mirror.last[1] += str
        components[-1] = JSON.generate("text" => mirror.last[1])
      else
        mirror << [:s, str.dup]
        components << JSON.generate("text" => str)
      end
    end

    def print_operand(operand, mode, components, mirror, out)
      if operand.is_a?(IR::Const)
        return add_text(const_text(operand, mode), components, mirror)
      end

      t = types_of(operand)
      if t == Set[:int]
        components << JSON.generate("score" => { "name" => holder(operand), "objective" => objective(operand) })
        mirror << [:score, operand]
        return
      end
      if t == Set[:nil]
        return add_text(mode == :inspect ? "nil" : "", components, mirror)
      end

      slot = "print.p#{@print_slots += 1}"
      store = "data modify storage #{names.storage} #{slot}"
      out << "#{store} set value {s:#{JSON.generate(mode == :inspect ? 'nil' : '')}}" if t.include?(:nil)
      if t.include?(:bool)
        out << "execute if score #{ref(operand)} matches 1 run #{store} set value {s:\"true\"}"
        out << "execute if score #{ref(operand)} matches 0 run #{store} set value {s:\"false\"}"
      end
      if t.include?(:int)
        out << "execute if score #{ref(operand)} matches #{ANY} run #{store} set value {}"
        out << "execute if score #{ref(operand)} matches #{ANY} store result storage #{names.storage} #{slot}.i int 1 " \
               "run scoreboard players get #{ref(operand)}"
      end
      components << JSON.generate("nbt" => "#{slot}.s", "storage" => names.storage)
      components << JSON.generate("nbt" => "#{slot}.i", "storage" => names.storage) if t.include?(:int)
      mirror << [:slot, slot]
    end

    def const_text(c, mode)
      case c.type
      when :nil then mode == :inspect ? "nil" : ""
      when :bool then (c.value == 1).to_s
      else c.value.to_s
      end
    end
  end
end
