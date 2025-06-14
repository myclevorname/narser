{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
      in
      {
        formatter = pkgs.nixfmt-tree;
        packages = rec {
          default = pkgs.stdenv.mkDerivation (final: {
            name = "narser";
            src = self;
            nativeBuildInputs = with pkgs; [ zig.hook ];
            zigBuildFlags = "-Dstrip";
          });
          fast = pkgs.stdenv.mkDerivation (final: {
            name = "narser";
            src = self;
            nativeBuildInputs = with pkgs; [ zig.hook ];
            zigBuildFlags = "-Dstrip -Doptimize=ReleaseFast";
          });
        };
        devShells.default = pkgs.mkShell {
          nativeBuildInputs = with pkgs; [ zig ];
        };
      }
    );
}
