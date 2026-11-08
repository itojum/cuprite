# frozen_string_literal: true

module Cuprite
  # Call graph of user methods and its strongly connected components
  # (design §5). Only calls inside a recursive SCC save and restore locals.
  class CallGraph
    def initialize(program)
      @program = program
      @edges = Hash.new { |h, k| h[k] = Set.new }
      program.functions.each_value do |fn|
        @edges[fn.name]
        IR.each_instr(fn.body) { |ins| @edges[fn.name] << ins.fn if ins.is_a?(IR::Call) }
      end
      compute_sccs
    end

    def callees(name) = @edges.fetch(name, Set.new)

    def scc_of(name) = @scc.fetch(name)

    # Whether `name` is part of a cycle (including calling itself).
    def recursive?(name)
      comp = @components[scc_of(name)]
      comp.size > 1 || @edges[name].include?(name)
    end

    # Whether a call from caller to callee can re-enter caller's frame.
    def recursive_call?(caller, callee)
      scc_of(caller) == scc_of(callee) && recursive?(caller)
    end

    # Functions reachable from `name`, including itself.
    def reachable(name)
      seen = Set[name]
      stack = [name]
      until stack.empty?
        @edges[stack.pop].each { |n| stack << n if seen.add?(n) }
      end
      seen
    end

    private

    # Tarjan's algorithm.
    def compute_sccs
      index = 0
      indices = {}
      low = {}
      on_stack = Set.new
      stack = []
      @scc = {}
      @components = []
      strong = lambda do |v|
        indices[v] = low[v] = index
        index += 1
        stack << v
        on_stack << v
        @edges[v].each do |w|
          if !indices.key?(w)
            strong.call(w)
            low[v] = [low[v], low[w]].min
          elsif on_stack.include?(w)
            low[v] = [low[v], indices[w]].min
          end
        end
        if low[v] == indices[v]
          comp = []
          loop do
            w = stack.pop
            on_stack.delete(w)
            @scc[w] = @components.size
            comp << w
            break if w == v
          end
          @components << comp
        end
      end
      @edges.keys.each { |v| strong.call(v) unless indices.key?(v) }
    end
  end
end
