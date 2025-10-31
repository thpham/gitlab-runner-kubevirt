# Default entry point for NixOS base images
{
  nixpkgs ? <nixpkgs>,
  system ? builtins.currentSystem,
}:

let
  pkgs = import nixpkgs { inherit system; };

  # Build a QCOW2 image for KubeVirt
  buildQCOW2 = config: (pkgs.nixos config).config.system.build.qcow2;

in
{
  # Base image with comprehensive tooling
  base = buildQCOW2 {
    imports = [ ./base.nix ];
  };

  # Runner image with GitLab Runner integration
  runner = buildQCOW2 {
    imports = [ ./runner.nix ];
  };
}
