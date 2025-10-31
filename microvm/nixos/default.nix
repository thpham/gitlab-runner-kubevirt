# Default entry point for NixOS base images
{
  pkgs ? import <nixpkgs> { },
  nixpkgsPath ? <nixpkgs>,
  system ? builtins.currentSystem,
}:

let
  # Helper to build NixOS QCOW2 images
  # diskSize: size in MB (default: 30GB for comprehensive tooling)
  buildQCOW2 = modules: diskSize:
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
      inherit diskSize;
      format = "qcow2";
    };

in
{
  # Base image with comprehensive tooling (30GB disk)
  # Includes: Go, Node.js, Python, Ruby, Java, Rust, Docker, Kubernetes tools, cloud CLIs, etc.
  base = buildQCOW2 [ ./base.nix ] 30720;

  # Runner image with GitLab Runner integration (35GB disk)
  # Includes all base packages plus GitLab Runner
  runner = buildQCOW2 [ ./runner.nix ] 35840;
}
