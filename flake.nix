{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    zig-src = {
      url = "git+https://codeberg.org/ziglang/zig";
      flake = false;
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      zig-src,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        zig = (pkgs.callPackage (nixpkgs + "/pkgs/development/compilers/zig/generic.nix") {
          version = "0.16.0";
          hash = "";
          llvmPackages = pkgs.llvmPackages_21;
        }).overrideAttrs {
          version = "0.16.0-unstable";
          src = zig-src;
        };
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
