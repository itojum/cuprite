# frozen_string_literal: true

module Cuprite
  # Generates the compiler-owned functions and tags: __init, debug/*, and the
  # #minecraft:load / #minecraft:tick registrations (design §4.3, §8).
  class Runtime
    def initialize(program, names, pack, codegen, debug:)
      @program = program
      @names = names
      @pack = pack
      @codegen = codegen
      @debug = debug
    end

    def generate
      @codegen.helper(:truncated)
      hash = build_hash
      generate_debug
      generate_init(hash)
      generate_tags
    end

    private

    attr_reader :names

    # A 31-bit hash of the generated code, used to detect code changes on load
    # (design §6.6).
    def build_hash
      digest = Digest::SHA256.new
      @pack.files.sort.each { |path, content| digest << path << "\0" << content << "\0" }
      digest.hexdigest[0, 8].to_i(16) & 0x7fffffff
    end

    def generate_init(hash)
      rt = names.rt
      lines = [
        "scoreboard objectives add #{names.vars} dummy",
        "scoreboard objectives add #{names.globals} dummy",
        "scoreboard objectives add #{rt} dummy",
        "execute unless score $debug #{rt} matches 0..1 run scoreboard players set $debug #{rt} #{@debug ? 1 : 0}",
        "execute if score $running #{rt} matches 1 run function #{names.function('__truncated')}",
        "scoreboard players set $running #{rt} 0",
        "scoreboard players set $ctl #{rt} 0",
        "scoreboard players set $exc #{rt} 0"
      ]
      @program.objectives.each do |o|
        lines << "scoreboard objectives add #{o.name} #{o.criteria}"
      end
      @codegen.constants.sort.each do |c|
        lines << "scoreboard players set #{names.const(c)} #{rt} #{c}"
      end
      lines << "scoreboard players set $build #{rt} #{hash}"
      @pack.add_function("__init", lines)
    end

    def generate_debug
      rt = names.rt
      ns = names.ns
      @pack.add_function("debug/on", [
        "scoreboard players set $debug #{rt} 1",
        %(tellraw @a {"text":"[#{ns}] debug mode on"})
      ])
      @pack.add_function("debug/off", [
        "scoreboard players set $debug #{rt} 0",
        %(tellraw @a {"text":"[#{ns}] debug mode off"})
      ])
      st = names.storage
      @pack.add_function("debug/last_error", [
        %(execute unless data storage #{st} last_error run return run tellraw @a {"text":"[#{ns}] no error recorded"}),
        %(tellraw @a {"text":"[#{ns}] last error: ","extra":[{"nbt":"last_error.class","storage":"#{st}"},) +
          %({"text":": "},{"nbt":"last_error.message","storage":"#{st}"}]})
      ])
    end

    def generate_tags
      load = [names.function("__init")]
      load << names.function(@codegen.function_path("on_load")) if @program.functions.key?("on_load")
      @pack.tag("minecraft", "load", load)
      return unless @program.functions.key?("on_tick")

      @pack.tag("minecraft", "tick", [names.function(@codegen.function_path("on_tick"))])
    end
  end
end
