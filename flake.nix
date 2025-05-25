{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let pkgs = nixpkgs.legacyPackages.${system}; in {
        packages.default = pkgs.stdenv.mkDerivation (final: {
          name = "narser";
          src = self;
          nativeBuildInputs = with pkgs; [ zig.hook ];
        });
        devShells.default = pkgs.mkShell {
          nativeBuildInputs = with pkgs; [ zig ];
        };
      }
    );
}
