# Loz

This is a Zig implementation of [Crafting Interpreters](https://craftinginterpreters.com/).

The current implementation is using data-oriented design. I was curious to
implement it after learning that the Zig compiler relies on DoD. With this
implementation, I reduced memory allocations and
made memory ownership clearer (for me).

You can find the original version in the `archive/` directory.

Note: I did not do every challenge. I will try to complete it
or move advance to the next chapter.

## Dependencies

- Zig compiler v0.16.0

## Building

```bash
zig build --release=fast/safe/small
```

## Usage

### Running the REPL

```bash
zig build run
# or
./zig-out/bin/loz
```

This starts an interactive prompt:

```
><> 10 + 20 * 15;
310
><> "Hello, " + "World!";
Hello, World!
><>
```

### Running a File

```bash
zig build run -- file.loz
# or
./zig-out/bin/loz file.loz
```

## Resources

- [Crafting Interpreters Book](https://craftinginterpreters.com/)
