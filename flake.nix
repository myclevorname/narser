{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    zig = {
      url = "github:ziglang/zig";
      flake = false;
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      ...
    }@inputs:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        zig =
          (pkgs.callPackage (nixpkgs + "/pkgs/development/compilers/zig/generic.nix") {
            llvmPackages = pkgs.llvmPackages_20;
            hash = "";
            version = "0.15.0-unstable";
          }).overrideAttrs
            (
              final: old: {
                src = inputs.zig;
              }
            );
      in
      {
        formatter = pkgs.nixfmt-tree;
        packages = rec {
          default = pkgs.stdenv.mkDerivation (final: {
            name = "narser";
            src = self;
            nativeBuildInputs = [ zig.hook ];
            zigBuildFlags = "-Dstrip";
          });
          fast = pkgs.stdenv.mkDerivation (final: {
            name = "narser";
            src = self;
            nativeBuildInputs = [ zig.hook ];
            zigBuildFlags = "-Dstrip -Doptimize=ReleaseFast";
          });
          small = pkgs.stdenv.mkDerivation (final: {
            name = "narser";
            src = self;
            nativeBuildInputs = [ zig.hook ];
            zigBuildFlags = "-Dstrip -Doptimize=ReleaseSmall";
          });
        };
        devShells.default = pkgs.mkShell {
          nativeBuildInputs = [ zig ];
        };
      }
    );
}
