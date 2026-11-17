self: { config, lib, pkgs, ... }:
let cfg = config.programs.omateams; in {
  options.programs.omateams = {
    enable = lib.mkEnableOption "omateams, Microsoft Teams for Omarchy";
    package = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.omateams.override {
        hyprland = config.programs.hyprland.package;
      };
      defaultText = lib.literalExpression "omateams.packages.\${pkgs.stdenv.hostPlatform.system}.omateams.override { hyprland = config.programs.hyprland.package; }";
      description = "The omateams package, built against the system Hyprland.";
    };
  };

  # The Omarchy plugin wiring is in the home-manager module.
  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ cfg.package ];
  };
}
