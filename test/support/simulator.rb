# frozen_string_literal: true

require "json"

module Cuprite
  # A small interpreter for the subset of Minecraft commands Cuprite emits.
  #
  # It exists so differential tests can run offline (the real-server harness
  # of design §3 needs network access to Mojang). It models the documented
  # command semantics Cuprite relies on: 32-bit wrapping scores, unset scores,
  # function return values, `execute if function`, macros, data storage, and
  # the command chain limit. It is a model, not the game: behaviour verified
  # only here is listed under "Open facts" in docs/design.md.
  class Simulator
    class CommandError < StandardError; end
    class ChainLimit < StandardError; end

    INT_MIN = -2_147_483_648
    INT_MAX = 2_147_483_647

    # Raised internally to unwind a function on `return`. `return 0` succeeds
    # with value 0; `return fail` fails, so success is carried separately.
    class ReturnSignal < StandardError
      attr_reader :success, :value

      def initialize(success, value)
        @success = success
        @value = value
        super("return")
      end
    end

    # Raised by `return run function ...` so the call runs in place of the
    # current frame (the game runs functions without growing a native stack).
    class TailCall < StandardError
      attr_reader :id, :args, :ctx

      def initialize(id, args, ctx)
        @id = id
        @args = args
        @ctx = ctx
        super("tail call")
      end
    end

    Entity = Struct.new(:uuid, :type, :name, :tags, :pos, :rot, :alive, :online, keyword_init: true) do
      def player? = type == "player"
    end

    # Execution context of a command.
    Context = Struct.new(:entity, :pos, :rot, keyword_init: true)

    attr_reader :scores, :storage, :chat, :objectives, :entities, :commands_run, :log
    attr_accessor :chain_limit, :strict

    def initialize(pack, chain_limit: 65_536, strict: true)
      @functions = {}
      @tags = {}
      pack.files.each do |path, content|
        if (m = path.match(%r{\Adata/([^/]+)/function/(.+)\.mcfunction\z}))
          @functions["#{m[1]}:#{m[2]}"] = content.split("\n").reject { |l| l.strip.empty? || l.start_with?("#") }
        elsif (m = path.match(%r{\Adata/([^/]+)/tags/function/(.+)\.json\z}))
          @tags["#{m[1]}:#{m[2]}"] = JSON.parse(content)["values"]
        end
      end
      # Objectives the compiler owns (design §5): those Names gives each
      # namespace of the pack. A user objective may end in ".vars" too.
      @compiler_objectives = pack.files.keys.filter_map { |path| path[%r{\Adata/([^/]+)/}, 1] }.uniq
                                 .reject { |ns| ns == "minecraft" }
                                 .flat_map { |ns| ["#{ns}.vars", "#{ns}.rt", "#{ns}.globals"] }.to_set
      @objectives = {}
      @scores = Hash.new { |h, k| h[k] = {} } # objective => { holder => value }
      @storage = Hash.new { |h, k| h[k] = {} }
      @chat = []
      @log = []
      @entities = []
      @next_uuid = 0
      @chain_limit = chain_limit
      @strict = strict
      @commands_run = 0
      @tick = 0
    end

    # --- World manipulation (for tests) ----------------------------------

    def spawn(type, name: nil, pos: [0, 64, 0], tags: [])
      @next_uuid += 1
      e = Entity.new(uuid: format("00000000-0000-0000-0000-%012d", @next_uuid), type: type, name: name,
                     tags: tags.dup, pos: pos.dup, rot: [0, 0], alive: true, online: true)
      @entities << e
      e
    end

    def kill(entity)
      entity.alive = false
      @entities.delete(entity)
      @scores.each_value { |h| h.delete(entity.uuid) }
    end

    def score(holder, objective)
      holder = holder.uuid if holder.is_a?(Entity)
      @scores.fetch(objective, {})[holder]
    end

    def set_score(holder, objective, value)
      holder = holder.uuid if holder.is_a?(Entity)
      @scores[objective][holder] = value
    end

    # --- Entry points ------------------------------------------------------

    # Runs the #minecraft:load tag (as on /reload or world load).
    def load
      run_tag("minecraft:load")
    end

    # Runs one game tick: #minecraft:tick.
    def tick
      @tick += 1
      run_tag("minecraft:tick")
    end

    def run_tag(tag)
      (@tags[tag] || []).each { |fn| run_function(fn) }
    end

    # Runs a function as the server (like /function from the console).
    # Returns the function's return value, or nil if it did not return.
    # A chain-limit overrun truncates the run silently, like the game.
    def run_function(id, context: nil)
      @commands_run = 0
      call_function(id, nil, context || server_context)
    rescue ChainLimit
      @log << "chain limit reached in #{id}"
      nil
    rescue SystemStackError
      # Function calls recurse through Ruby methods, so very deep recursion
      # exhausts Ruby's stack before the chain limit. Fail loudly rather than
      # pretend the game truncated the run.
      raise CommandError, "#{id}: function recursion exceeds the simulator's Ruby stack depth"
    end

    def server_context = Context.new(entity: nil, pos: [0, 0, 0], rot: [0, 0])

    def function?(id) = @functions.key?(id)

    # Runs a single command line (for tests).
    def command(line, context: nil)
      execute_line(line, context || server_context)
    end

    # Runs a function and returns its return value, or nil if it did not return.
    def call_function(id, macro_args, ctx)
      result = function_result(id, macro_args, ctx)
      result && result[1]
    end

    private

    # Runs a function; returns [success, value] if it returned, else nil.
    # `return run function f` runs f in place of the current frame (TailCall),
    # since the game does not grow a native stack for it.
    def function_result(id, macro_args, ctx)
      tail = false
      loop do
        run_lines(id, macro_args, ctx)
        # `return run function f` where f falls through returns 0.
        return tail ? [true, 0] : nil
      rescue ReturnSignal => e
        return [e.success, e.value]
      rescue CommandError
        # A tail-called function that cannot run (unknown, bad macro
        # arguments) fails its `return run function` like an ordinary call
        # would: the caller returns 0 unless the simulator is strict.
        raise if strict || !tail

        return [false, 0]
      rescue TailCall => t
        id = t.id
        macro_args = t.args
        ctx = t.ctx
        tail = true
      end
    end

    def run_lines(id, macro_args, ctx)
      lines = @functions[id] or raise CommandError, "unknown function #{id}"
      lines.each do |line|
        if line.start_with?("$")
          raise CommandError, "macro function #{id} called without arguments" unless macro_args

          line = line[1..].gsub(/\$\(([A-Za-z0-9_]+)\)/) do
            raise CommandError, "missing macro argument #{$1} for #{id}" unless macro_args.key?($1)

            nbt_to_macro(macro_args[$1])
          end
        end
        execute_line(line, ctx)
      end
    end

    # Executes one command, returning its result [success, value]. A command
    # nested under `execute ... run` or `return run` is part of the same
    # function command, so it is not charged to the chain budget again.
    def execute_line(line, ctx, charge: true)
      if charge
        @commands_run += 1
        raise ChainLimit if @commands_run > @chain_limit
      end

      r = Reader.new(line)
      result = dispatch(r, ctx)
      result || [false, 0]
    rescue CommandError => e
      raise CommandError, "#{e.message}\n  in: #{line}" if strict

      [false, 0]
    end

    def dispatch(r, ctx)
      cmd = r.word
      case cmd
      when "scoreboard" then cmd_scoreboard(r, ctx)
      when "execute" then cmd_execute(r, [ctx])
      when "function" then cmd_function(r, ctx)
      when "return" then cmd_return(r, ctx)
      when "data" then cmd_data(r, ctx)
      when "tellraw"
        r.word
        @chat << r.rest
        [true, 1]
      when "say", "give", "summon", "particle", "playsound", "effect", "tp", "kill", "setblock", "title", "tag"
        @log << "#{cmd} #{r.rest_peek}"
        side_effect(cmd, r, ctx)
      else
        raise CommandError, "unknown command #{cmd.inspect}"
      end
    end

    def side_effect(cmd, r, ctx)
      case cmd
      when "kill"
        targets = r.eof? ? [ctx.entity].compact : select(r.word, ctx)
        targets.each { |e| kill(e) }
        return [!targets.empty?, targets.size]
      when "tag"
        targets = select(r.word, ctx)
        op = r.word
        name = r.word
        # The result counts the entities whose tags actually changed.
        changed = targets.count do |e|
          if op == "add"
            next false if e.tags.include?(name)

            e.tags << name
          else
            !e.tags.delete(name).nil?
          end
        end

        return [changed.positive?, changed]
      end
      [true, 1]
    end

    # --- scoreboard --------------------------------------------------------

    def cmd_scoreboard(r, ctx)
      case r.word
      when "objectives"
        case r.word
        when "add"
          name = r.word
          crit = r.word
          return [false, 0] if @objectives.key?(name)

          @objectives[name] = crit
          [true, 1]
        when "remove"
          name = r.word
          raise CommandError, "unknown objective #{name}" unless @objectives.delete(name)

          @scores.delete(name)
          [true, 1]
        else raise CommandError, "bad scoreboard objectives"
        end
      when "players" then cmd_players(r, ctx)
      else raise CommandError, "bad scoreboard command"
      end
    end

    def cmd_players(r, ctx)
      op = r.word
      case op
      when "set", "add", "remove"
        holders = holders(r.word, ctx)
        obj = objective(r.word)
        n = r.int
        raise CommandError, "#{op} amount out of range" if op != "set" && n.negative?
        raise CommandError, "#{op} amount #{n} is not a 32-bit integer" unless n.between?(INT_MIN, INT_MAX)

        # The result is the sum of the resulting scores.
        total = holders.sum do |h|
          cur = @scores[obj][h] || 0
          @scores[obj][h] = case op
                            when "set" then n
                            when "add" then wrap(cur + n)
                            else wrap(cur - n)
                            end
        end
        [!holders.empty?, wrap(total)]
      when "reset"
        holders = holders(r.word, ctx)
        if r.eof?
          holders.each { |h| @scores.each_value { |s| s.delete(h) } }
        else
          obj = objective(r.word)
          holders.each { |h| @scores[obj].delete(h) }
        end
        [true, holders.size]
      when "get"
        h = single_holder(r.word, ctx)
        obj = objective(r.word)
        v = @scores[obj][h]
        raise CommandError, "no score for #{h} in #{obj}" if v.nil? && strict
        return [false, 0] if v.nil?

        [true, v]
      when "operation"
        targets = holders(r.word, ctx)
        tobj = objective(r.word)
        operation = r.word
        sources = holders(r.word, ctx)
        sobj = objective(r.word)
        targets.each do |t|
          sources.each do |s|
            sv = @scores[sobj][s]
            raise CommandError, "no score for source #{s} in #{sobj}" if sv.nil?

            tv = @scores[tobj][t]
            if tv.nil?
              # The game starts an unset target at 0. Cuprite's own slots never
              # rely on that, so strict mode flags it as a compiler bug.
              compiler_slot = @compiler_objectives.include?(tobj)
              raise CommandError, "operation #{operation} on unset target #{t}" if strict && compiler_slot && operation != "="

              tv = 0
            end
            case operation
            when "=" then @scores[tobj][t] = sv
            when "+=" then @scores[tobj][t] = wrap(tv + sv)
            when "-=" then @scores[tobj][t] = wrap(tv - sv)
            when "*=" then @scores[tobj][t] = wrap(tv * sv)
            when "/=" then @scores[tobj][t] = wrap(tv.div(sv)) unless sv.zero? # floor division
            when "%=" then @scores[tobj][t] = tv.modulo(sv) unless sv.zero?   # floor modulo
            when "<" then @scores[tobj][t] = [tv, sv].min
            when ">" then @scores[tobj][t] = [tv, sv].max
            when "><"
              @scores[tobj][t] = sv
              @scores[sobj][s] = tv
            else raise CommandError, "bad operation #{operation}"
            end
          end
        end
        # The result is the sum of the targets' resulting scores.
        [true, wrap(targets.sum { |t| @scores[tobj][t] || 0 })]
      else
        raise CommandError, "bad scoreboard players #{op}"
      end
    end

    def objective(name)
      raise CommandError, "unknown objective #{name}" unless @objectives.key?(name)

      name
    end

    def wrap(v)
      v &= 0xffff_ffff
      v >= 0x8000_0000 ? v - 0x1_0000_0000 : v
    end

    # Score holders named by a selector or a literal name.
    def holders(token, ctx)
      if token.start_with?("@")
        select(token, ctx).map(&:uuid)
      elsif token == "*"
        raise CommandError, "wildcard holders are not supported"
      else
        [token]
      end
    end

    def single_holder(token, ctx)
      hs = holders(token, ctx)
      raise CommandError, "expected one score holder for #{token}, got #{hs.size}" unless hs.size == 1

      hs.first
    end

    # --- selectors ---------------------------------------------------------

    def select(selector, ctx)
      m = selector.match(/\A@([aesprn])(?:\[(.*)\])?\z/) or raise CommandError, "bad selector #{selector}"
      kind = m[1]
      filters = parse_filters(m[2])
      list =
        case kind
        when "s" then ctx.entity && ctx.entity.alive ? [ctx.entity] : []
        when "a", "p", "r" then @entities.select { |e| e.player? && e.online }
        when "e", "n" then @entities.select { |e| e.online }
        end
      filters.each do |key, value|
        list = apply_filter(list, key, value, ctx)
      end
      list = list.first(1) if %w[p r n].include?(kind) && !filters.any? { |k, _| k == "limit" }
      list
    end

    def parse_filters(str)
      return [] if str.nil? || str.empty?

      out = []
      depth = 0
      cur = +""
      str.each_char do |ch|
        if ch == "," && depth.zero?
          out << cur
          cur = +""
          next
        end
        depth += 1 if ch == "{"
        depth -= 1 if ch == "}"
        cur << ch
      end
      out << cur
      out.map { |kv| kv.split("=", 2) }
    end

    def apply_filter(list, key, value, _ctx)
      case key
      when "type"
        neg = value.start_with?("!")
        t = value.delete_prefix("!").delete_prefix("minecraft:")
        list.select { |e| (e.type == t) != neg }
      when "tag"
        neg = value.start_with?("!")
        t = value.delete_prefix("!")
        list.select { |e| t.empty? ? (e.tags.empty? != neg) : (e.tags.include?(t) != neg) }
      when "name"
        list.select { |e| e.name == value }
      when "limit" then list.first(value.to_i)
      when "scores"
        conds = value.delete_prefix("{").delete_suffix("}").split(",").map { |c| c.split("=", 2) }
        list.select do |e|
          conds.all? do |obj, range|
            v = @scores.fetch(obj, {})[e.uuid]
            !v.nil? && in_range?(v, range)
          end
        end
      when "sort", "distance", "x", "y", "z" then list
      else raise CommandError, "unsupported selector filter #{key}"
      end
    end

    def in_range?(v, range)
      range.split("..").each do |bound|
        next if bound.empty?
        raise CommandError, "range bound #{bound} is not a 32-bit integer" unless Integer(bound).between?(-2**31, 2**31 - 1)
      end
      if range.include?("..")
        lo, hi = range.split("..", 2)
        (lo.empty? || v >= lo.to_i) && (hi.nil? || hi.empty? || v <= hi.to_i)
      else
        v == range.to_i
      end
    end

    # --- execute -----------------------------------------------------------

    def cmd_execute(r, ctxs)
      # Each branch is [context, stores]; a store's target is bound to the
      # context current at its `store` subcommand, not the final one.
      branches = ctxs.map { |c| [c, []] }
      until r.eof?
        return [false, 0] if branches.empty?

        sub = r.word
        case sub
        when "run"
          rest = r.rest
          results = branches.map do |c, stores|
            begin
              s, v = execute_line(rest, c, charge: false)
            rescue ReturnSignal => e
              # `run return ...` still reports its result to the stores.
              apply_stores(stores, e.success, e.value)
              raise
            end
            apply_stores(stores, s, v)
            [s, v]
          end
          return finish_execute(results)
        when "if", "unless"
          want = sub == "if"
          kind = r.word
          if kind == "function"
            id = r.word
            passed, failed = branches.partition do |c, _|
              res = function_result(id, nil, c)
              (!res.nil? && res[0] && res[1] != 0) == want
            end
          else
            pos = r.pos
            passed, failed = branches.partition do |c, _|
              r.pos = pos
              condition(kind, r, c) == want
            end
          end
          # A failing final condition stores 0; one before `run` stores nothing.
          failed.each { |_, stores| apply_stores(stores, false, 0) } if r.eof?
          branches = passed
          return [false, 0] if branches.empty?
        when "store"
          st = parse_store(r)
          branches.each { |c, stores| stores << [bind_store(st, c), c] }
        when "as"
          sel = r.word
          branches = branches.flat_map do |c, stores|
            select(sel, c).map { |e| [Context.new(entity: e, pos: c.pos, rot: c.rot), stores.dup] }
          end
        when "at"
          sel = r.word
          branches = branches.flat_map do |c, stores|
            select(sel, c).map { |e| [Context.new(entity: c.entity, pos: e.pos, rot: e.rot), stores.dup] }
          end
        when "positioned"
          coords = [r.word, r.word, r.word]
          branches = branches.map { |c, st| [Context.new(entity: c.entity, pos: resolve_pos(coords, c), rot: c.rot), st] }
        when "rotated"
          rot = [r.word, r.word]
          branches = branches.map { |c, st| [Context.new(entity: c.entity, pos: c.pos, rot: resolve_rot(rot, c)), st] }
        when "facing", "align", "anchored", "in", "on", "summon"
          # Accepted but not modelled beyond parsing their arguments.
          skip_subcommand(sub, r)
        else
          raise CommandError, "unsupported execute subcommand #{sub}"
        end
      end
      # Condition-only execute: each passing context succeeds with result 1.
      branches.each { |_, stores| apply_stores(stores, true, 1) }
      finish_execute(branches.map { [true, 1] })
    end

    def skip_subcommand(sub, r)
      case sub
      when "facing"
        if r.peek == "entity"
          r.word
          r.word
          r.word
        else
          3.times { r.word }
        end
      when "align", "anchored", "in", "on", "summon" then r.word
      end
    end

    def resolve_pos(coords, ctx)
      coords.each_with_index.map do |c, i|
        if c.start_with?("~")
          ctx.pos[i] + (c.length > 1 ? c[1..].to_f : 0)
        elsif c.start_with?("^")
          ctx.pos[i] # local coordinates are not modelled
        else
          c.to_f
        end
      end
    end

    def resolve_rot(rot, ctx)
      rot.each_with_index.map { |c, i| c.start_with?("~") ? ctx.rot[i] + c[1..].to_f : c.to_f }
    end

    def finish_execute(results)
      return [false, 0] if results.empty?

      [results.any? { |s, _| s }, results.sum { |_, v| v }]
    end

    def apply_stores(stores, success, value)
      stores.each { |st, ctx| apply_store(st, success, value, ctx) }
    end

    def parse_store(r)
      what = r.word # result / success
      target = r.word
      case target
      when "score"
        { what: what, kind: :score, holder: r.word, objective: r.word }
      when "storage"
        id = r.word
        path = r.word
        type = r.word
        scale = r.word.to_f
        { what: what, kind: :storage, id: id, path: path, type: type, scale: scale }
      else
        raise CommandError, "unsupported store target #{target}"
      end
    end

    # Score destinations are resolved when the store subcommand is parsed,
    # before the run command can change which entities a selector matches.
    def bind_store(store, ctx)
      return store unless store[:kind] == :score

      store.merge(holders: holders(store[:holder], ctx), objective: objective(store[:objective]))
    end

    def apply_store(store, success, value, ctx)
      v = store[:what] == "success" ? (success ? 1 : 0) : value
      case store[:kind]
      when :score
        targets = store[:holders] || holders(store[:holder], ctx)
        targets.each { |h| @scores[objective(store[:objective])][h] = wrap(v) }
      when :storage
        nbt_set(@storage[store[:id]], store[:path], nbt_number(store[:type], v * store[:scale]))
      end
    end

    INT_BITS = { "byte" => 8, "short" => 16, "int" => 32, "long" => 64 }.freeze

    # The game's Java casts: (float)/(double) keep fractions; integer types
    # truncate toward zero, saturate to int (long for `long`), then narrow.
    def nbt_number(type, x)
      case type
      when "double" then x.to_f
      when "float" then [x].pack("f").unpack1("f")
      else
        bits = INT_BITS[type] or raise CommandError, "unsupported store type #{type}"
        wide = bits == 64 ? 64 : 32
        n = x.truncate.clamp(-(1 << (wide - 1)), (1 << (wide - 1)) - 1)
        n &= (1 << bits) - 1
        n >= (1 << (bits - 1)) ? n - (1 << bits) : n
      end
    end

    def condition(kind, r, ctx)
      case kind
      when "score"
        holder = single_holder(r.word, ctx)
        obj = objective(r.word)
        op = r.word
        v = @scores[obj][holder]
        if op == "matches"
          range = r.word
          !v.nil? && in_range?(v, range)
        else
          h2 = single_holder(r.word, ctx)
          o2 = objective(r.word)
          w = @scores[o2][h2]
          return false if v.nil? || w.nil?

          case op
          when "=" then v == w
          when "<" then v < w
          when "<=" then v <= w
          when ">" then v > w
          when ">=" then v >= w
          else raise CommandError, "bad comparison #{op}"
          end
        end
      when "data"
        raise CommandError, "only storage data conditions are supported" unless r.word == "storage"

        id = r.word
        path = r.word
        !nbt_get(@storage[id], path).nil?
      when "entity"
        !select(r.word, ctx).empty?
      else
        raise CommandError, "unsupported condition #{kind}"
      end
    end

    # --- function / return -------------------------------------------------

    def cmd_function(r, ctx)
      id = r.word
      if id.start_with?("#")
        (@tags[id[1..]] || []).each { |f| call_function(f, nil, ctx) }
        return [true, 1]
      end
      function_result(id, function_args(r), ctx) || [true, 0]
    end

    def function_args(r)
      args = nil
      unless r.eof?
        raise CommandError, "expected 'with'" unless r.word == "with"
        raise CommandError, "only 'with storage' is supported" unless r.word == "storage"

        sid = r.word
        path = r.eof? ? nil : r.word
        args = path ? nbt_get(@storage[sid], path) : @storage[sid]
        raise CommandError, "macro arguments are not a compound" unless args.is_a?(Hash)
      end
      args
    end

    def cmd_return(r, ctx)
      token = r.word
      case token
      when "run"
        if r.peek == "function" && !r.rest_peek.include?("#")
          # Part of this function command: not charged to the chain budget.
          r.word
          id = r.word
          begin
            args = function_args(r)
          rescue CommandError
            # Bad macro arguments fail the function command, so the
            # `return run` returns 0 and this function stops here.
            raise if strict

            raise ReturnSignal.new(false, 0)
          end
          raise TailCall.new(id, args, ctx)
        end
        s, v = execute_line(r.rest, ctx, charge: false)
        raise ReturnSignal.new(s, s ? v : 0)
      when "fail" then raise ReturnSignal.new(false, 0)
      else raise ReturnSignal.new(true, Integer(token))
      end
    end

    # --- data --------------------------------------------------------------

    def cmd_data(r, ctx)
      op = r.word
      raise CommandError, "only storage is supported" unless r.word == "storage"

      id = r.word
      root = @storage[id]
      case op
      when "get"
        path = r.eof? ? nil : r.word
        v = path ? nbt_get(root, path) : root
        raise CommandError, "no data at #{path}" if v.nil?

        scale = r.eof? ? 1 : r.word.to_f
        n = case v
            when Integer, Float then (v * scale).floor
            when String, Array, Hash then v.size
            end
        [true, wrap(n)]
      when "remove"
        path = r.word
        ok = nbt_remove(root, path)
        [ok, ok ? 1 : 0]
      when "modify"
        path = r.word
        mode = r.word
        index = mode == "insert" ? r.int : nil
        source = r.word
        value =
          case source
          when "value" then SNBT.parse(r.rest)
          when "from"
            raise CommandError, "only storage sources" unless r.word == "storage"

            sv = nbt_get(@storage[r.word], r.word)
            raise CommandError, "no source data" if sv.nil?

            deep_copy(sv)
          when "string"
            raise CommandError, "only storage sources" unless r.word == "storage"

            sv = nbt_get(@storage[r.word], r.word)
            sv.to_s
          else raise CommandError, "unsupported data modify source #{source}"
          end
        case mode
        when "set" then nbt_set(root, path, value)
        when "append", "prepend", "insert"
          list = nbt_get(root, path)
          if list.nil?
            list = []
            nbt_set(root, path, list)
          end
          raise CommandError, "not a list at #{path}" unless list.is_a?(Array)

          case mode
          when "append" then list << value
          when "prepend" then list.unshift(value)
          else list.insert(index, value)
          end
        when "merge"
          target = nbt_get(root, path)
          raise CommandError, "not a compound" unless target.is_a?(Hash) && value.is_a?(Hash)

          target.merge!(value)
        else raise CommandError, "unsupported data modify mode #{mode}"
        end
        [true, 1]
      else
        raise CommandError, "unsupported data #{op}"
      end
    end

    def deep_copy(v) = Marshal.load(Marshal.dump(v))

    def nbt_to_macro(v)
      case v
      when String then v
      when Integer, Float then v.to_s
      else SNBT.dump(v)
      end
    end

    # NBT paths: key, "quoted key", [index], chained with dots.
    def parse_path(path)
      parts = []
      s = path.dup
      until s.empty?
        if s.start_with?('"')
          m = s.match(/\A"((?:[^"\\]|\\.)*)"/) or raise CommandError, "bad path #{path}"
          parts << m[1].gsub(/\\(.)/, '\1')
          s = s[m[0].size..]
        elsif s.start_with?("[")
          m = s.match(/\A\[(-?\d+)\]/) or raise CommandError, "bad path #{path}"
          parts << m[1].to_i
          s = s[m[0].size..]
        else
          m = s.match(/\A[^.\["]+/) or raise CommandError, "bad path #{path}"
          parts << m[0]
          s = s[m[0].size..]
        end
        s = s[1..] if s.start_with?(".")
      end
      parts
    end

    def nbt_get(root, path)
      parse_path(path).reduce(root) do |cur, key|
        case key
        when Integer
          return nil unless cur.is_a?(Array)

          cur[key]
        else
          return nil unless cur.is_a?(Hash)

          cur[key]
        end
      end
    end

    def nbt_set(root, path, value)
      parts = parse_path(path)
      parent = parts[0..-2].reduce(root) do |cur, key|
        if key.is_a?(Integer)
          raise CommandError, "no element #{key}" unless cur.is_a?(Array) && cur[key]

          cur[key]
        else
          raise CommandError, "not a compound" unless cur.is_a?(Hash)

          cur[key] ||= {}
        end
      end
      last = parts.last
      if last.is_a?(Integer)
        raise CommandError, "no element #{last}" unless parent.is_a?(Array) && parent[last]

        parent[last] = value
      else
        parent[last] = value
      end
    end

    def nbt_remove(root, path)
      parts = parse_path(path)
      parent = nbt_get(root, parts[0..-2].map { |p| p.is_a?(Integer) ? "[#{p}]" : %("#{p}") }.join(".").gsub(".[", "["))
      parent = root if parts.size == 1
      last = parts.last
      if parent.is_a?(Array) && last.is_a?(Integer) && parent[last]
        parent.delete_at(last)
        true
      elsif parent.is_a?(Hash) && parent.key?(last)
        parent.delete(last)
        true
      else
        false
      end
    end

    # Tokenizer for one command line.
    class Reader
      attr_accessor :pos

      def initialize(line)
        @s = line
        @pos = 0
      end

      def skip_ws
        @pos += 1 while @pos < @s.size && @s[@pos] == " "
      end

      def eof?
        skip_ws
        @pos >= @s.size
      end

      def peek
        save = @pos
        w = word
        @pos = save
        w
      end

      # A word; selectors with brackets may contain spaces inside [...].
      def word
        skip_ws
        raise CommandError, "unexpected end of command" if @pos >= @s.size

        start = @pos
        depth = 0
        while @pos < @s.size
          ch = @s[@pos]
          depth += 1 if ch == "[" || ch == "{"
          depth -= 1 if ch == "]" || ch == "}"
          break if ch == " " && depth <= 0

          @pos += 1
        end
        @s[start...@pos]
      end

      def int
        w = word
        Integer(w)
      rescue ArgumentError
        raise CommandError, "expected integer, got #{w}"
      end

      def rest_peek
        skip_ws
        @s[@pos..]
      end

      def rest
        skip_ws
        r = @s[@pos..]
        @pos = @s.size
        r
      end
    end

    # Minimal SNBT reader/writer: compounds, lists, strings, numbers.
    module SNBT
      module_function

      def parse(str)
        p = Parser.new(str)
        v = p.value
        p.skip_ws
        raise CommandError, "trailing SNBT: #{str}" unless p.eof?

        v
      end

      def dump(v)
        case v
        when Hash then "{" + v.map { |k, x| "#{k.to_s.match?(/\A[A-Za-z0-9_.+-]+\z/) ? k : k.inspect}:#{dump(x)}" }.join(",") + "}"
        when Array then "[" + v.map { |x| dump(x) }.join(",") + "]"
        when String then v.inspect
        else v.to_s
        end
      end

      class Parser
        def initialize(s)
          @s = s
          @i = 0
        end

        def eof? = @i >= @s.size

        def skip_ws
          @i += 1 while @i < @s.size && @s[@i] =~ /\s/
        end

        def value
          skip_ws
          case @s[@i]
          when "{" then compound
          when "[" then list
          when '"', "'" then string
          else scalar
          end
        end

        def compound
          @i += 1
          h = {}
          skip_ws
          if @s[@i] == "}"
            @i += 1
            return h
          end
          loop do
            skip_ws
            key = @s[@i] == '"' || @s[@i] == "'" ? string : bare
            skip_ws
            raise CommandError, "expected ':' in SNBT" unless @s[@i] == ":"

            @i += 1
            h[key] = value
            skip_ws
            case @s[@i]
            when "," then @i += 1
            when "}"
              @i += 1
              return h
            else raise CommandError, "bad SNBT compound"
            end
          end
        end

        def list
          @i += 1
          a = []
          skip_ws
          @i += 2 if @s[@i + 1] == ";" # typed arrays
          skip_ws
          if @s[@i] == "]"
            @i += 1
            return a
          end
          loop do
            a << value
            skip_ws
            case @s[@i]
            when "," then @i += 1
            when "]"
              @i += 1
              return a
            else raise CommandError, "bad SNBT list"
            end
          end
        end

        def string
          q = @s[@i]
          @i += 1
          out = +""
          loop do
            raise CommandError, "unterminated SNBT string" if @i >= @s.size

            ch = @s[@i]
            @i += 1
            return out if ch == q

            if ch == "\\"
              raise CommandError, "unterminated SNBT string" if @i >= @s.size

              ch = @s[@i]
              @i += 1
            end
            out << ch
          end
        end

        def bare
          start = @i
          @i += 1 while @i < @s.size && @s[@i].match?(/[A-Za-z0-9_.+-]/)
          @s[start...@i]
        end

        def scalar
          tok = bare
          case tok
          when /\A-?\d+[bBsSlL]?\z/ then tok.to_i
          when /\A-?\d*\.?\d+(?:[eE][-+]?\d+)?[fFdD]?\z/ then tok.to_f
          when "true" then 1
          when "false" then 0
          else tok
          end
        end
      end
    end
  end
end
