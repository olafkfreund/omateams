{
  description = "omateams, Microsoft Teams for Omarchy";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixpkgs-qt.url = "github:NixOS/nixpkgs/614ba4ae06fe11e36b386321b8735d1a6bf441db";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      nixpkgs-qt,
      home-manager,
      ...
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAll = f: nixpkgs.lib.genAttrs systems (s: f s nixpkgs.legacyPackages.${s});
      pkgsQt = s: nixpkgs-qt.legacyPackages.${s};
    in
    {
      packages = forAll (
        s: _:
        let
          omateams = (pkgsQt s).callPackage ./nix/package.nix { };
        in
        {
          inherit omateams;
          default = omateams;
        }
      );

      apps = forAll (
        s: _: {
          default = {
            type = "app";
            program = nixpkgs.lib.getExe self.packages.${s}.omateams;
          };
        }
      );

      overlays.default = final: _: {
        omateams = (pkgsQt final.stdenv.hostPlatform.system).callPackage ./nix/package.nix {
          hyprland = final.hyprland;
        };
      };

      homeManagerModules.default = import ./nix/home.nix self;
      nixosModules.default = import ./nix/nixos.nix self;

      checks = forAll (
        s: _:
        import ./nix/checks.nix {
          inherit self nixpkgs home-manager;
          pkgs = nixpkgs.legacyPackages.${s};
          system = s;
        }
      );
    };
}
