{
  description = "A Zig implementation of the Ethereum Virtual Machine (EVM).";
  inputs = {
    flake-compat.url = "https://flakehub.com/f/edolstra/flake-compat/*.tar.gz";
    flake-schemas.url = "https://flakehub.com/f/DeterminateSystems/flake-schemas/*.tar.gz";
    nixpkgs.url = "https://flakehub.com/f/NixOS/nixpkgs/*.tar.gz";
    zig.url = "github:mitchellh/zig-overlay";
  };

  outputs = { self, flake-compat, flake-schemas, nixpkgs, ... }@inputs:
    let
    overlays = [
      # Other overlays
      (final: prev: {
        zigpkgs = inputs.zig.packages.${prev.system};
      })
    ];
      supportedSystems = [ "x86_64-linux" "aarch64-darwin" "x86_64-darwin" "aarch64-linux" ];
      forEachSupportedSystem = f: nixpkgs.lib.genAttrs supportedSystems (system: f {
        pkgs = import nixpkgs { inherit overlays system; };
      });
    in {
      schemas = flake-schemas.schemas;

      devShells = forEachSupportedSystem ({ pkgs }: {
        default = pkgs.mkShell {
          packages = with pkgs; [
            zigpkgs."0.13.0"
          ];

          shellHook = ''
            $SHELL
          '';
        };
      });
    };
}
