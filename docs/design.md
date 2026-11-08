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
- `if` / `unless` / `case`–`when`, loops and waits (see §6).
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
  `<ns>.globals`. They survive `/reload` and world restarts. An unassigned
  global reads as `nil`.
- **Declared scoreboards** (§9.1) can target fake players as well, for state
  shared with other data packs or command blocks.
- Per-entity state uses declared scoreboards with `target: "@s"`.

### 4.5 Naming of generated functions

- Each Ruby method `foo` whose name is a valid resource path segment
  (`[a-z0-9_]`, not starting with `__`) is emitted as `<ns>:foo` (stable,
  callable from command blocks and other packs without arguments).
- Methods whose names are valid Ruby but not valid resource paths (`ready?`,
  `activate!`, `value=`, names with uppercase letters) are emitted under
  `<ns>:__m/<index>`, numbered by the compiler. They are callable from Ruby
  but have no stable exported name.
- Compiler-internal functions live under `<ns>:__*`.
- **Reserved names**: defining a method named `main`, any `__*` name, or any
  Kernel control method (§9.0) is a compile error, so user methods can never
  collide with generated functions or silently shadow built-in control
  constructs. `on_load` / `on_tick` may only be defined without parameters.

## 5. Variables and calls

- **All compiler-owned state is scoped to the pack namespace**: objectives
  are named `<ns>.<purpose>` (`<ns>.vars`, `<ns>.globals`, `<ns>.rt`,
  `<ns>.pc.<fn>`, …) and storage lives in `<ns>:__runtime`. Two Cuprite
  packs in one world therefore never share task slots, and one pack's
  build-hash reset (§6.6) only discards its own tasks.
- Local variables are fake players in objective `<ns>.vars`
  (e.g. `$fib.n`).
- Call graph SCCs are computed. Only functions in a **recursive SCC** save and
  restore their locals around calls, using a stack in data storage. Initially
  all locals are saved; liveness-based minimisation is a later optimisation.
- Non-recursive functions have no call overhead beyond the call itself.

## 6. Loops, recursion and tasks

### 6.1 Loops are immediate; waits are explicit

| Construct | Execution |
|---|---|
| `while`, `until`, `loop`, `times`, `upto`, `downto`, `Range#each` | **Immediate**: all iterations within the current tick |
| Recursive method calls | **Immediate** |
| `wait(ticks)`, `sleep(seconds)`, `next_tick`, `wait_until { cond }` | **Suspend**: execution continues in a later tick |

- This matches Ruby semantics: a loop finishes before the next statement runs.
  Crossing ticks is always visible in the source as an explicit wait.
- `wait(n)` waits `n` ticks; `sleep(n)` waits `n` seconds (`20 * n` ticks),
  like `Kernel#sleep`; `next_tick` is `wait(1)`; `wait_until { cond }`
  re-evaluates `cond` once per tick and continues when it is truthy.
- A loop whose body contains a wait is suspendable like any other code
  (e.g. `19.times { particle; next_tick }` runs one iteration per tick).
- Loops with a literal count may be unrolled by the optimiser.
- There are **no iteration or recursion-depth limits**. Exceeding the game's
  command chain limit truncates execution; that is the user's
  responsibility, but it is detected (§6.7).
- In CRuby (differential tests), `wait`, `next_tick` and `wait_until` are
  provided by a shim; tests compare output, not wall-clock time.

### 6.2 Suspendable functions

- A function containing a wait, or calling (transitively) such a function,
  is **suspendable**.
- When suspended, its resume point and live locals are stored as scores:
  - on the **executing entity** (`@s`), in per-function objectives such as
    `<ns>.pc.<fn>` and `<ns>.l.<fn>.<var>`;
  - on a **fake player** when there is no executing entity.
- Each tick, suspended tasks are resumed with
  `execute as <entities with an active task> at @s run function <ns>:__resume/...`.
  A single shared "has active task" score is scanned once, then dispatched
  per function.
- **Execution context on resume**: the resume call re-applies, outermost
  first, the subcommands of every context block (§9.3) that statically
  encloses the suspension point, after the innermost `as` (whose entity holds
  the task state). For example, a task suspended inside
  `as("@a") { positioned("~ ~5 ~") { rotated("0 0") { ... } } }` resumes via
  `execute as <entity> at @s positioned ~ ~5 ~ rotated 0 0 run function ...`.
  Absolute coordinates are restored exactly; relative ones (`~`, `^`) and
  selectors are re-evaluated against the state at resume time, consistent with
  re-evaluating `at @s` each tick. No extra state is stored.
- **Context inherited through calls**: a suspended callee's callers are
  suspended too (waiting for it), so resumption starts at the **outermost
  suspended function**. Each level re-applies the context blocks that enclose
  its own suspension point (the call), then calls the next level's resume
  function. For example, a wait inside `skill` called from
  `positioned("100 64 100") { skill }` resumes at `100 64 100`. This costs one
  function call per level on each resume, with no extra state and no code
  duplication.
- Entity selectors never match fake score holders, so tasks without an
  executing entity have a separate dispatch path, run as the server:
  `execute if score $server <ns>.pc.<fn> matches 1.. run function <ns>:__resume/<fn>`
  (the fake player `$server` holds the state in the same per-function objectives)
  for each suspendable function that can run without an entity.
- Within a tick, `on_tick` runs first, then suspended tasks are resumed.
- There is **no limit** on the number of concurrent tasks.
- `on_tick` and `on_load` **cannot suspend**: reaching a wait from them is a
  compile error, except inside `as(..., wait: false)` (§9.3). This guarantees
  `on_tick` starts and finishes within every tick. Long-running processes are
  started from them with `as(selector, wait: false) { ... }`.

### 6.3 Recursion and waits

> Reaching a wait from a **recursive method** is a **compile error**
> (recursive frames live in a storage stack that is not kept across ticks).

### 6.4 Re-entry

- If a suspendable function is called on an entity that already has a running
  task for **the same function**, `Cuprite::AlreadyRunningError` is raised.
  The same applies to the `$server` state holder (e.g. running
  `/function <ns>:main` again while it is suspended). The existing task is
  left intact.
- Different functions may run concurrently on the same entity.
- **Forking without changing the executor**: `at` and `execute` can fork
  execution while keeping `@s`, so forks would share one task slot. Reaching
  a wait inside an `at` / `execute` block is therefore a compile error unless
  its selector is single-target (`@s`, `@p`, `@r`, or `limit=1`); a raw
  `execute("...")` string counts as single-target only if it contains no
  forking subcommand. The fix is `as(selector) { at("@s") { ... } }`, which
  gives each entity its own task. `positioned` / `rotated` never fork.

### 6.5 Disappearing entities

- If the executing entity is removed (e.g. a mob dies), its task silently
  disappears with it. `ensure` is **not** run.
- A player's tasks pause while the player is offline and resume on rejoin.
  If the block waiting on such a task (§9.3) has already completed, an
  exception the task raises after rejoining is treated as uncaught and
  recorded as the last error.

### 6.6 Code changes and `/reload`

- A build hash is embedded in the pack. On load, `__init` compares it with the
  previous hash; if it differs, **all suspended tasks are discarded** (task
  objectives are removed and recreated, which also clears offline players).
- `ensure` is not run for discarded tasks. The discard is reported in debug
  mode and recorded as the last error.
- A plain `/reload` or world restart with an unchanged build keeps tasks
  running.

### 6.7 Truncation detection

- Each entry point sets a `$running` marker on entry and clears it on normal
  completion (or suspension). If an entry point or `__init` finds the marker
  still set, the previous run was truncated by the command chain limit.
- On detection, runtime state (halt flag, recursion stack, temporaries) is
  reset and the truncation is recorded as the last error. User state
  (scores, globals, effects of commands) is not rolled back.

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

### 9.0 Where the API lives

| `Kernel` (control constructs) | `Cuprite` (Minecraft operations) |
|---|---|
| `wait`, `sleep`, `next_tick`, `wait_until` | `Cuprite.command` |
| `as`, `at`, `positioned`, `rotated`, `execute` | `Cuprite::Scoreboard` |

Kernel names are reserved (§4.5).

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
as("@a[scores={hoge=20}]") do
  at("@s") do
    skill
  end
end

execute("facing entity @p eyes") do
  ...
end
```

- Dedicated methods: `as`, `at`, `positioned`, `rotated`. Any other
  subcommand goes through the generic `execute("<subcommands>") { ... }`.
  Blocks nest.
- The block is compiled to a separate function invoked via `execute ... run function`.
- **The block waits** until every entity's task has finished. While waiting,
  the caller recounts, each tick, the entities that still exist and still have
  an active task for that block **owned by this invocation**, and proceeds
  when the count reaches zero. Removed entities and offline players therefore
  never block progress.
- **Ownership**: each waiting block invocation takes a fresh invocation ID
  from a global counter (`$next_id <ns>.rt`). Every child task it starts
  stores that ID in `<ns>.owner.<block>`, and the join counts only entities
  whose owner score equals the caller's ID (`execute as @e[...] if score @s
  <ns>.owner.<block> = <caller> <ns>.inv.<block> run scoreboard players add
  ...`). Concurrent callers therefore never wait for each other's children.
- **Exceptions**: other entities keep running. A child that ends with an
  uncaught exception writes its kind to storage keyed by the owner's
  invocation ID (`<ns>:__runtime pending."<id>"`, via a macro; only on this
  failure path) and then releases its task slot immediately, so a later
  invocation reusing the slot can never overwrite an uncollected failure.
  After all children have finished, the caller reads and deletes its own
  `pending."<id>"` entry and re-raises the first exception recorded there.
  Entries orphaned by a caller that disappeared are cleared by the
  build-hash reset (§6.6).
- Blocks may read **and assign** outer local variables. Concurrent tasks
  assigning the same variable share one fake player.
- **Detached blocks**: `as(selector, wait: false) { ... }` starts a task on
  each entity and returns immediately without waiting. An exception raised
  inside a detached block that is not rescued within the block is not
  propagated to the caller; it is recorded as the last error.
- **Re-launch is skipped**: a detached block is not started on an entity
  where that same block's task is still active; that entity is silently
  skipped (no `AlreadyRunningError`). This is the usual "cannot re-trigger
  while active" behaviour, so a skill needs no extra code:

  ```ruby
  def on_tick
    as("@a[scores={hoge=20}]", wait: false) do
      skill
    end
  end
  ```

## Open facts to verify

- Java version required by the 26.3 dedicated server (expected: 25).
- Scoreboard `/=` and `%=` use floor division / floor modulo (matching Ruby).
- How selectors treat dead players (choice of `@e` vs `@a` for resuming tasks).
- Current game rule names (possible renames in 26.x).
- `nbt` text components display string tags without quotes (used to print
  `true` / `false` / `nil` and nilable integers).
- Network access to Mojang hosts (`piston-meta.mojang.com`,
  `piston-data.mojang.com`) from the development environment.
