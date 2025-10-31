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
    useNetworkd = true;  # Use systemd-networkd with cloud-init
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

  # Enable cloud-init for VM initialization
  services.cloud-init = {
    enable = true;
    network.enable = true;

    # Configure for KubeVirt/NoCloud datasource
    config = ''
      datasource_list: [ NoCloud, None ]
      datasource:
        NoCloud:
          fs_label: cidata

      # Disable cloud-init on subsequent boots after first run
      manual_cache_clean: true

      # Enable required modules
      cloud_init_modules:
        - migrator
        - seed_random
        - bootcmd
        - write-files
        - growpart
        - resizefs
        - disk_setup
        - mounts
        - set_hostname
        - update_hostname
        - update_etc_hosts
        - ca-certs
        - rsyslog
        - users-groups
        - ssh

      cloud_config_modules:
        - ssh-import-id
        - keyboard
        - locale
        - set-passwords
        - ntp
        - timezone
        - disable-ec2-metadata
        - runcmd

      cloud_final_modules:
        - package-update-upgrade-install
        - scripts-vendor
        - scripts-per-once
        - scripts-per-boot
        - scripts-per-instance
        - scripts-user
        - ssh-authkey-fingerprints
        - keys-to-console
        - final-message
    '';
  };

  # Enable SSH for debugging and cloud-init access
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "no";
      PasswordAuthentication = true; # Allow password auth for cloud-init configured passwords
    };
  };

  # Enable rsyslog for cloud-init logging
  services.rsyslogd.enable = true;

  # Enable chrony for NTP time synchronization
  services.chrony.enable = true;

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
    # Cloud-init and required dependencies
    cloud-init
    cloud-utils # growpart, cloud-localds
    e2fsprogs # resize2fs for ext4 filesystems
    xfsprogs # xfs_growfs for XFS filesystems
    parted # disk partitioning for disk_setup
    gptfdisk # GPT disk partitioning (provides gdisk)
    util-linux # mount, hostname, and other utilities
    cacert # CA certificates bundle
    rsyslog # System logging daemon
    shadow # useradd, usermod, groupadd for user management
    chrony # NTP time synchronization

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
    nano

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
    loader.grub = {
      enable = lib.mkDefault true;
      device = lib.mkDefault "/dev/vda";
    };
    loader.systemd-boot.enable = lib.mkDefault false;
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
