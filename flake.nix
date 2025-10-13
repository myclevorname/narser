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
      ...
    }@inputs:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        zig = pkgs.zig_0_15;
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
