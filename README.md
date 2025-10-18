# Narser, a Nix ARchive parSER library and program

Narser is a replacement for `nix nar` that aims to be simple and fast.
Currently, `narser pack` is around twice as fast as Nix at packing the Linux kernel source code, at least when discarding the output or writing to a tmpfs. (see [benchmark](benchmark))
However, the `hash` subcommand is somewhat slower than `nix hash path`.

NOTE: Not to be confused with the [Narser](https://github.com/Nacorpio/Narser) parser generator, which is 9 years old.

WARNING: DO NOT run on a filesystem with case-insensitive file names as that allows an attacker to write to arbitrary files with the same permissions as the invoking user.
Narser does not and will not support Nix's case-hacking on MacOS.

## Building

Narser targets 0.15.1 as there is a huge performance regression in `narser hash` in 0.15.2.

For release builds, Nix is used.
The `fast` and `small` packages have little to no benefit and are only included for completeness.

## TODO

1. Clean up code
2. Revamp the Zig interface
3. Add documentation
4. Add more tests

## Contributing

Please read CONTRIBUTING.md for some guidelines and view some of my other repos for contact information.

TL;DR: There is nothing to worry about if you [don't use AI](https://github.com/orgs/community/discussions/159749#discussioncomment-13464891) and you follow Github's ToS.
