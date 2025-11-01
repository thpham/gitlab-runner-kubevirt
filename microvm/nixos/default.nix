# Default entry point for NixOS base images
{
  pkgs ? import <nixpkgs> { },
  nixpkgsPath ? <nixpkgs>,
  system ? builtins.currentSystem,
}:

let
  # Helper to build NixOS QCOW2 images
  buildQCOW2 = modules:
    let
      # Evaluate the NixOS configuration
      nixosConfig = (import "${nixpkgsPath}/nixos/lib/eval-config.nix") {
        inherit system;
        inherit pkgs;
        modules = modules;
      };
    in
    # Build the QCOW2 image
    import "${nixpkgsPath}/nixos/lib/make-disk-image.nix" {
      inherit pkgs;
      inherit (pkgs) lib;
      config = nixosConfig.config;
      diskSize = "auto";
      format = "qcow2";
    };

in
{
  # Base image with comprehensive tooling
  base = buildQCOW2 [ ./base.nix ];

  # Runner image with GitLab Runner integration
  runner = buildQCOW2 [ ./runner.nix ];
}
