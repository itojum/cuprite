# Cuprite Design

Cuprite is an ahead-of-time compiler from a subset of Ruby to a Minecraft
Java Edition data pack (`.mcfunction`).

This document records the design decisions agreed before implementation.
"MUST"-level rules are stated plainly; anything listed under
[Open facts](#open-facts-to-verify) is still to be verified on a real server.

---

## 1. Target

- **Minecraft Java Edition 26.3** data pack.
- Data pack format **121.0**. `pack.mcmeta` uses `min_format` / `max_format`
  (the scheme introduced in 25w31a) rather than a single `pack_format`.
- Generated code may rely on function macros (`$(...)`), `return run`,
  `function ... with storage`, `execute store`, scoreboards and data storage.

## 2. Toolchain

- The compiler is written in **Ruby** and parses source with **Prism**
  (bundled with Ruby 3.3+).
- Pipeline: Prism AST → Cuprite IR (three-address style) → type inference /
  analyses → optimisation → code generation.
- Distributed as a gem providing the command `cuprite build`.

### 2.1 Configuration: `cuprite.yml`

```yaml
namespace: demo              # data pack namespace (required)
entry: src/main.rb           # entry Ruby file
output: build                # output directory; the pack is written to build/<namespace>/
debug: false                 # initial debug-mode state (default: false)
world: ~/.minecraft/saves/MyWorld   # optional; if set, the pack is also copied into <world>/datapacks/
```

### 2.2 Output

- A data pack directory at `<output>/<namespace>/`.
- If `world` is set, the directory is also copied into that world's
  `datapacks/` folder.

## 3. Verification

- Tests compile Ruby programs, run them under **CRuby** and on a real
  **Minecraft 26.3 dedicated server** (driven over RCON), and compare outputs.
- CRuby is only a valid oracle for programs whose arithmetic never leaves the
  32-bit range: wrapping (§4.1) changes intermediate results, not just the
  final output (`(2147483647 + 1) / 2` is `1073741824` in CRuby but
  `-1073741824` in Cuprite). Differential tests are therefore restricted to
  non-overflowing programs; wrapping behaviour is covered by separate tests
  with hand-written expected outputs.
- Tests run both in the development (cloud) environment and in **GitHub
  Actions**.
- The server jar is downloaded from Mojang at test time. It is never committed
  or redistributed.
- Because `tellraw` output cannot be read over RCON, the test harness also
  mirrors program output into data storage and reads it back with `data get`.

## 4. Language subset (milestone 1)

### 4.1 Values

- `Integer`, `true`, `false`, `nil`.
- Integers are **32-bit and wrap on overflow** (scoreboard semantics). This is
  specified behaviour, not an error.
- An integer literal outside the 32-bit range is a **compile error**.
- Division and modulo by a non-constant divisor get a runtime zero check that
  raises `ZeroDivisionError`.
- Representation: booleans are `0`/`1`; `nil` is an **unset score**.
  Type combinations that inference cannot represent (e.g. `Integer | true`)
  are compile errors.
- The type-inference pass is designed so that `String`, `Array` and `Hash`
  (backed by data storage) can be added later.

### 4.2 Supported constructs

- Local variables, arithmetic, comparison, logical operators.
- `if` / `unless` / `case`–`when`, loops (see §6).
- Top-level `def` with arguments and `return`; recursion (see §6.3).
- `puts` / `p` (see §8) with string literals and interpolation.
- Global variables (see §4.4).
- Exceptions (see §7).

### 4.3 Entry points

| Ruby | Generated |
|---|---|
| top-level code | `<ns>:main`, run manually with `/function <ns>:main` |
| `def on_load` | registered in `#minecraft:load` (runs after `__init`) |
| `def on_tick` | registered in `#minecraft:tick` |
| (always) | `<ns>:__init`, registered in `#minecraft:load` |

`__init` creates the compiler's objectives, initialises constants, sets the
debug flag only if it is unset, and performs the build-hash check (§6.6).

### 4.4 Persistent state

- **Global variables** (`$count`) live on fake player `$count` in objective
  `cuprite.globals`. They survive `/reload` and world restarts. An unassigned
  global reads as `nil`.
- **Declared scoreboards** (§9.1) can target fake players as well, for state
  shared with other data packs or command blocks.
- Per-entity state uses declared scoreboards with `target: "@s"`.

### 4.5 Naming of generated functions

- Each Ruby method `foo` is emitted as `<ns>:foo` (stable, callable from
  command blocks and other packs without arguments).
- Compiler-internal functions live under `<ns>:__*`.

## 5. Variables and calls

- Local variables are fake players in objective `cuprite.vars`
  (e.g. `$fib.n`).
- Call graph SCCs are computed. Only functions in a **recursive SCC** save and
  restore their locals around calls, using a stack in data storage. Initially
  all locals are saved; liveness-based minimisation is a later optimisation.
- Non-recursive functions have no call overhead beyond the call itself.

## 6. Loops, recursion and tasks

### 6.1 Two kinds of iteration

| Construct | Execution |
|---|---|
| `while`, `until`, `loop`, `times`, `upto`, `downto`, `Range#each` | **Tick-split**: one iteration per tick |
| `fast_times`, `fast_upto`, `fast_downto`, `Range#fast_each` | **Immediate**: all iterations within the current tick |
| Recursive method calls | **Immediate**: executed within the current tick |

- Tick-split loops have **no iteration limit**. An infinite tick-split loop is
  simply a process that never ends; it does not exhaust the command budget.
- Tick-split loops are **not unrolled** (unrolling would add per-tick dispatch
  cost and gain nothing).
- `fast_*` with a literal count/range is **unrolled** up to an internal
  threshold; otherwise it is compiled to a self-calling function with a
  counter.
- Recursion has **no depth limit**. Exceeding the game's command chain limit
  is the user's responsibility.

### 6.2 Suspendable functions

- A function containing a tick-split loop, or calling (transitively) such a
  function, is **suspendable**.
- When suspended, its resume point and live locals are stored as scores:
  - on the **executing entity** (`@s`), in per-function objectives such as
    `cuprite.pc.<fn>` and `cuprite.l.<fn>.<var>`;
  - on a **fake player** when there is no executing entity.
- Each tick, suspended tasks are resumed with
  `execute as <entities with an active task> at @s run function <ns>:__resume/...`.
  A single shared "has active task" score is scanned once, then dispatched
  per function.
- Entity selectors never match fake score holders, so tasks without an
  executing entity have a separate dispatch path, run as the server:
  `execute if score $server cuprite.pc.<fn> matches 1.. run function <ns>:__resume/<fn>`
  (the fake player `$server` holds the state in the same per-function objectives)
  for each suspendable function that can run without an entity.
- Within a tick, `on_tick` runs first, then suspended tasks are resumed.
- Entry points always start every tick; there is **no limit** on the number of
  concurrent tasks.

### 6.3 Immediate contexts

> Reaching a tick-split loop from an **immediate context** (a recursive
> method, or the body of a `fast_*` loop) is a **compile error**.

This is a single uniform rule regardless of whether a particular case could
technically be supported.

### 6.4 Re-entry

- If a suspendable function is called on an entity that already has a running
  task for **the same function**, `Cuprite::AlreadyRunningError` is raised.
- Different functions may run concurrently on the same entity.

### 6.5 Disappearing entities

- If the executing entity is removed (e.g. a mob dies), its task silently
  disappears with it. `ensure` is **not** run.
- A player's tasks pause while the player is offline and resume on rejoin.

### 6.6 Code changes and `/reload`

- A build hash is embedded in the pack. On load, `__init` compares it with the
  previous hash; if it differs, **all suspended tasks are discarded** (task
  objectives are removed and recreated, which also clears offline players).
- `ensure` is not run for discarded tasks. The discard is reported in debug
  mode and recorded as the last error.
- A plain `/reload` or world restart with an unchanged build keeps tasks
  running.

## 7. Exceptions

- Supported: `raise "message"` (string literal), `raise SomeError`,
  `begin` / `rescue` / `else` / `ensure`, `rescue SomeError`,
  and `def ... rescue ... end`.
- Not supported in milestone 1: `rescue => e`, `retry`, `throw` / `catch`.
- Exception kinds are integer IDs with a small built-in hierarchy
  (`StandardError` > `ZeroDivisionError`, `Cuprite::AlreadyRunningError`, …).
- Mechanism: a halt flag. On raise, the flag is set and the current function
  returns. Every call site and loop iteration checks the flag and unwinds.
  `rescue` checks the kind and clears the flag.
- No static exception analysis: users avoid unhandled errors with `rescue`.
- An uncaught exception stops the task. It is printed only in debug mode, and
  is always recorded in storage, viewable with `/function <ns>:debug/last_error`.

## 8. Output and debug mode

- `puts` / `p` compile to `tellraw @a`, guarded by the debug flag; they print
  only while debug mode is on.
- Built-in functions:
  - `<ns>:debug/on`, `<ns>:debug/off`
  - `<ns>:debug/last_error`
- The initial state comes from `debug:` in `cuprite.yml` (default off). The
  state is stored in a score and persists across reloads.

## 9. Minecraft interop

### 9.1 Scoreboards

```ruby
class Scores < Cuprite::Scoreboard
  objective :kills
  objective :deaths, criteria: :deathCount
end

k = Scores.kills.get(target: "@p")
Scores.kills.set(0, target: "@p")
Scores.kills.add(1, target: "@s")
```

- Declarations are resolved at compile time; no runtime objects exist.
- Objectives with `criteria:` are created in `__init`.
- Reads, writes and score-specific operations (`get`, `set`, `add`, `remove`,
  `reset`, …) are methods; there is no `[]` form.

### 9.2 Raw commands

```ruby
Cuprite.command "give @p diamond #{n}"
```

- Without interpolation, the command is emitted verbatim.
- Interpolated integer expressions are passed through a function macro.
- Returns the command result as an integer (`execute store result`).

### 9.3 Execution context

```ruby
Cuprite.as("@a[scores={hoge=20}]") do
  Cuprite.at("@s") do
    skill
  end
end

Cuprite.execute("facing entity @p eyes") do
  ...
end
```

- Dedicated methods: `Cuprite.as`, `Cuprite.at`, `Cuprite.positioned`,
  `Cuprite.rotated`. Any other subcommand goes through the generic
  `Cuprite.execute("<subcommands>") { ... }`. Blocks nest.
- The block is compiled to a separate function invoked via `execute ... run function`.
- **The block waits** until every entity's task has finished. While waiting,
  the caller recounts, each tick, the entities that still exist and still have
  an active task for that block, and proceeds when the count reaches zero.
  Removed entities and offline players therefore never block progress.
- **Exceptions**: other entities keep running. After all have finished, the
  first exception raised is re-raised in the caller.
- Blocks may read **and assign** outer local variables. Concurrent tasks
  assigning the same variable share one fake player.

## Open facts to verify

- Java version required by the 26.3 dedicated server (expected: 25).
- Scoreboard `/=` and `%=` use floor division / floor modulo (matching Ruby).
- How selectors treat dead players (choice of `@e` vs `@a` for resuming tasks).
- Current game rule names (possible renames in 26.x).
- Network access to Mojang hosts (`piston-meta.mojang.com`,
  `piston-data.mojang.com`) from the development environment.
