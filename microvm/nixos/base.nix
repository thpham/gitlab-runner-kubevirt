# NixOS base image for GitLab Runner KubeVirt
# Provides a comprehensive build environment similar to GitHub Actions runners

{
  pkgs,
  lib,
  ...
}:

{
  # System configuration
  system.stateVersion = "25.05";

  # Enable Nix flakes and nix-command
  nix = {
    package = pkgs.nix;
    extraOptions = ''
      experimental-features = nix-command flakes
    '';
    settings = {
      auto-optimise-store = true;
      trusted-users = [
        "root"
        "@wheel"
      ];
    };
  };

  # Network configuration
  networking = {
    hostName = "gitlab-runner-vm";
    useDHCP = lib.mkDefault true;
    firewall.enable = false;
  };

  # Time and locale
  time.timeZone = "UTC";
  i18n.defaultLocale = "en_US.UTF-8";

  # Users configuration
  users.users.runner = {
    isNormalUser = true;
    description = "GitLab Runner";
    extraGroups = [
      "wheel"
      "docker"
      "podman"
    ];
    uid = 1000;
  };

  # Allow passwordless sudo for runner user
  security.sudo = {
    enable = true;
    wheelNeedsPassword = false;
  };

  # Enable SSH for debugging
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "no";
      PasswordAuthentication = false;
    };
  };

  # Enable Docker
  virtualisation.docker = {
    enable = true;
    enableOnBoot = true;
    autoPrune = {
      enable = true;
      dates = "weekly";
    };
  };

  # Enable Podman as Docker alternative
  virtualisation.podman = {
    enable = true;
    dockerCompat = false;
    defaultNetwork.settings.dns_enabled = true;
  };

  # System packages - comprehensive toolset similar to GitHub Actions runners
  environment.systemPackages = with pkgs; [
    # Core utilities
    coreutils
    findutils
    gnugrep
    gnused
    gawk
    which
    curl
    wget
    aria2
    rsync
    jq
    yq-go
    ripgrep
    fd
    tree

    # Shell
    bashInteractive
    zsh
    nix

    # Version control
    git
    git-lfs
    gh # GitHub CLI
    glab

    # Compression
    gzip
    bzip2
    xz
    zstd
    unzip
    zip
    gnutar

    # Build tools
    just
    gnumake
    cmake
    ninja
    autoconf
    automake
    libtool
    pkg-config
    binutils

    # Compilers & toolchains
    gcc
    clang
    llvm
    rustc
    cargo

    # Language runtimes - Go
    go_1_24
    go_1_25

    # Language runtimes - Node.js
    nodejs_20
    nodejs_22
    nodejs_24
    nodePackages.npm
    nodePackages.yarn
    nodePackages.pnpm

    # Language runtimes - Python
    python311
    python312
    python313
    python3Packages.pip
    python3Packages.virtualenv
    python3Packages.setuptools

    # Language runtimes - Ruby
    ruby_3_4

    # Other languages
    perl
    php
    jdk21
    jdk17
    jdk11
    maven
    gradle
    sbt

    # Container tools
    docker
    docker-compose
    podman
    buildah
    skopeo
    dive
    regclient

    # Kubernetes tools
    openshift
    kubectl
    kubernetes-helm
    k3d
    kind
    kustomize

    # VMs tools
    qemu

    # Cloud CLIs
    awscli2
    google-cloud-sdk
    azure-cli
    terraform
    opentofu
    terragrunt

    # Config Management
    nomad
    ansible_2_19
    chef-cli
    habitat

    # Database clients
    pgcli
    mariadb-client
    sqlite
    redis
    mongodb-cli

    # Development tools
    vim
    nano
    less
    bat

    # SSL/TLS
    openssl
    cacert
    cfssl

    # Networking tools
    inetutils
    dnsutils
    nettools
    iputils

    # Monitoring & debugging
    strace
    lsof
    tcpdump
    procps

    # File systems
    e2fsprogs
    dosfstools
    ntfs3g
  ];

  # Environment variables
  environment.variables = {
    EDITOR = "nano";
    VISUAL = "nano";
    LANG = "en_US.UTF-8";
    LC_ALL = "en_US.UTF-8";
  };

  # System-wide shell initialization
  environment.shellInit = ''
    # Add common paths
    export PATH="$HOME/.local/bin:$PATH"

    # Enable color output
    export CLICOLOR=1
    export LS_COLORS='di=1;34:ln=1;36:so=1;35:pi=1;33:ex=1;32:bd=1;34:cd=1;34:su=1;31:sg=1;31:tw=1;34:ow=1;34'
  '';

  # Enable automatic garbage collection
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 30d";
  };

  # Boot configuration for VM
  boot = {
    loader.grub.enable = lib.mkDefault false;
    loader.systemd-boot.enable = lib.mkDefault true;
    kernelPackages = pkgs.linuxPackages_latest;

    # Enable virtio drivers for KubeVirt
    kernelModules = [
      "virtio_blk"
      "virtio_net"
      "virtio_pci"
      "virtio_scsi"
    ];
    initrd.availableKernelModules = [
      "virtio_blk"
      "virtio_net"
      "virtio_pci"
      "virtio_scsi"
      "9p"
      "9pnet_virtio"
    ];
  };

  # Enable guest agent for KubeVirt
  services.qemuGuest.enable = true;

  # Root filesystem (required for disk images)
  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
    autoResize = true;
  };

  # Systemd services optimization
  systemd.services.NetworkManager-wait-online.enable = false;
  systemd.settings.Manager = {
    DefaultTimeoutStartSec = "30s";
    DefaultTimeoutStopSec = "30s";
  };
}
