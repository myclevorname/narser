# Narser, a Nix ARchive parSER library and program

Narser is a replacement for `nix nar` that aims to be simple and fast.
Currently, `narser pack` is around twice as fast as Nix at packing the Linux kernel source code, at least when discarding the output or writing to a tmpfs. (see [benchmark](benchmark))

NOTE: Not to be confused with the [Narser](https://github.com/Nacorpio/Narser) parser generator, which is 9 years old.
See also [narz](https://github.com/water-sucks/narz), another Zig-based alternative.

## Building

Narser simultaneously targets the latest stable and nightly release of Zig.
If narser fails to build on either, that is a bug.

## TODO

1. Clean up code
2. Revamp the Zig interface
3. Add documentation
4. Add more tests

## Contributing

Please read CONTRIBUTING.md for some guidelines and view some of my other repos for contact information.

TL;DR: There is nothing to worry about if you [don't use AI](https://github.com/orgs/community/discussions/159749#discussioncomment-13464891) and you follow Github's ToS.
