self: { config, lib, pkgs, options, ... }:
let cfg = config.programs.omateams; in {
  options.programs.omateams = {
    enable = lib.mkEnableOption "omateams, Microsoft Teams for Omarchy";
    package = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.omateams;
      defaultText = lib.literalExpression "omateams.packages.\${pkgs.stdenv.hostPlatform.system}.omateams";
      description = "The omateams package. On NixOS, override it with the system Hyprland: `.override { hyprland = osConfig.programs.hyprland.package; }`.";
    };
  };
  config = lib.mkIf cfg.enable (lib.mkMerge [
    { home.packages = [ cfg.package ]; }
    # nixarchy's plugin option is only there when nixarchy is imported;
    # the declared options are checked, never config, so this cannot recurse.
    (lib.optionalAttrs (lib.hasAttrByPath [ "programs" "nixarchy" "plugins" ] options) {
      programs.nixarchy.plugins.omateams.src = "${cfg.package}/share/omateams/plugin";
    })
  ]);
}
