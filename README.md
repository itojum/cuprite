# Cuprite

Cuprite is an ahead-of-time compiler from a subset of Ruby to a Minecraft
Java Edition 26.3 data pack. The design is described in
[docs/design.md](docs/design.md).

## Usage

```yaml
# cuprite.yml
namespace: demo
entry: src/main.rb
output: build
debug: false
# world: ~/.minecraft/saves/MyWorld
```

```sh
cuprite build            # writes build/demo/ (and copies it into <world>/datapacks/)
```

In game, run the top-level program with `/function demo:main`.

## Status

Implemented: integers / booleans / nil, locals and globals, arithmetic with
32-bit wrapping, conditionals, `case`, loops, methods and recursion,
`puts` / `p`, exceptions, `Cuprite.command`, `Cuprite::Scoreboard`, and
context blocks (`as`, `at`, `positioned`, `rotated`, `execute`).

Not yet implemented: suspension and tasks (`wait`, `sleep`, `next_tick`,
`wait_until`, waiting context blocks, `as(..., wait: false)`; design
§6.2–§6.6 and the waiting parts of §9.3).

## Development

```sh
bundle install
bundle exec rake test
```

Tests compile Ruby programs, run them under CRuby and in
`test/support/simulator.rb` (a model of the commands Cuprite emits), and
compare the output. The simulator stands in for the real-server harness of
design §3 until the dedicated server can be downloaded in CI.
