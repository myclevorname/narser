# Narser, a Nix ARchive parSER library and program

Narser is a replacement for `nix nar` that aims to be simple and fast.
Currently, `narser pack` is 18.5% faster than Nix at packing the Linux kernel source code. (see [benchmark](benchmark))

NOTE: Not to be confused with the [Narser](https://github.com/Nacorpio/Narser) parser generator, which is 9 years old.

See also [narz](https://github.com/water-sucks/narz), a more featureful alternative to narser.

## Building

Narser simultaneously targets the 0.15.0 nightly and 0.14.1.

## TODO

1. Clean up code
2. ~~Make a C interface if possible~~ I'm not so sure about doing this one.
3. Revamp CLI
