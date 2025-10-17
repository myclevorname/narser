{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    zig2nix.url = "github:Cloudef/zig2nix";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      zig2nix,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        zig = zig2nix.packages.${system}.zig-master;
      in
      {
        formatter = pkgs.nixfmt-tree;
        packages = {
          default = pkgs.stdenv.mkDerivation (finalAttrs: {
            name = "narser";
            src = self;
            nativeBuildInputs = [ zig.hook ];
            zigBuildFlags = "-Dstrip";
            doCheck = true;
          });
          fast = pkgs.stdenv.mkDerivation (final: {
            name = "narser";
            src = self;
            nativeBuildInputs = [ zig.hook ];
            zigBuildFlags = "-Dstrip -Doptimize=ReleaseFast";
            doCheck = true;
          });
          small = pkgs.stdenv.mkDerivation (final: {
            name = "narser";
            src = self;
            nativeBuildInputs = [ zig.hook ];
            zigBuildFlags = "-Dstrip -Doptimize=ReleaseSmall";
            doCheck = true;
          });
        };
        devShells.default = pkgs.mkShell {
          nativeBuildInputs = [ zig ];
        };
      }
    );
}
