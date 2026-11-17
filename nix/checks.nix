{
  self,
  nixpkgs,
  home-manager,
  pkgs,
  system,
}:
let
  lib = pkgs.lib;
  package = self.packages.${system}.omateams;
  qtVersion = import ./qt-version.nix lib;
  hm =
    extraModules:
    home-manager.lib.homeManagerConfiguration {
      inherit pkgs;
      modules = [
        self.homeManagerModules.default
        {
          home.stateVersion = "25.11";
          home.username = "test";
          home.homeDirectory = "/home/test";
          programs.omateams.enable = true;
        }
      ]
      ++ extraModules;
    };
  nixos =
    extraModules:
    nixpkgs.lib.nixosSystem {
      inherit system;
      modules = [
        self.nixosModules.default
        {
          boot.isContainer = true;
          system.stateVersion = "25.11";
          programs.omateams.enable = true;
        }
      ]
      ++ extraModules;
    };
  nixarchyStub = { lib, ... }: {
    options.programs.nixarchy.plugins = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options.src = lib.mkOption { type = lib.types.str; };
        }
      );
      default = { };
    };
  };
  plain = hm [ ];
  plainOverride = hm [ { programs.omateams.package = pkgs.hello; } ];
  nixarchy = hm [ nixarchyStub ];
  nixarchyOverride = hm [
    nixarchyStub
    { programs.omateams.package = pkgs.hello; }
  ];
  os = nixos [ ];
  osOverride = nixos [ { programs.omateams.package = pkgs.hello; } ];
in
{
  inherit package;

  qt-version =
    assert
      !qtVersion "6.139.0"
      && !qtVersion "6.140.0-rc"
      && qtVersion "6.140.0"
      && qtVersion "6.140.1"
      && qtVersion "6.141.0-rc";
    pkgs.runCommand "qt-version" { } "touch $out";

  hm-plain =
    assert builtins.elem package plain.config.home.packages;
    pkgs.runCommand "hm-plain" { } "touch $out";

  hm-override =
    assert builtins.elem pkgs.hello plainOverride.config.home.packages;
    pkgs.runCommand "hm-override" { } "touch $out";

  hm-nixarchy =
    assert lib.hasSuffix "/share/omateams/plugin"
      nixarchy.config.programs.nixarchy.plugins.omateams.src;
    pkgs.runCommand "hm-nixarchy" { } "touch $out";

  hm-nixarchy-override =
    assert
      builtins.elem pkgs.hello nixarchyOverride.config.home.packages
      &&
        nixarchyOverride.config.programs.nixarchy.plugins.omateams.src
        == "${pkgs.hello}/share/omateams/plugin";
    pkgs.runCommand "hm-nixarchy-override" { } "touch $out";

  nixos =
    assert builtins.elem os.config.programs.omateams.package os.config.environment.systemPackages;
    pkgs.runCommand "nixos" { } "touch $out";

  nixos-override =
    assert builtins.elem pkgs.hello osOverride.config.environment.systemPackages;
    pkgs.runCommand "nixos-override" { } "touch $out";
}
