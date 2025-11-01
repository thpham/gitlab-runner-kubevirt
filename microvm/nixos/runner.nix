# GitLab Runner VM configuration for KubeVirt
# Extends base.nix with GitLab Runner-specific setup
{
  pkgs,
  ...
}:

{
  imports = [
    ./base.nix
  ];

  # GitLab Runner user configuration
  users.users.gitlab-runner = {
    isSystemUser = true;
    group = "gitlab-runner";
    description = "GitLab Runner Service";
    extraGroups = [
      "wheel"
      "docker"
      "podman"
    ];
    uid = 999;
  };

  users.groups.gitlab-runner = {
    gid = 999;
  };

  # Mount runner info from virtiofs
  fileSystems."/runner-info" = {
    device = "runner-info";
    fsType = "virtiofs";
    options = [ "nofail" ];
  };

  # GitLab Runner systemd service
  systemd.services.gitlab-runner-vm = {
    description = "GitLab Runner VM Service";
    after = [
      "network-online.target"
      "runner-info.mount"
    ];
    wants = [ "network-online.target" ];
    requires = [ "runner-info.mount" ];
    wantedBy = [ "multi-user.target" ];

    path = with pkgs; [
      bashInteractive
      coreutils
      git
      gnutar
      gzip
      nix
      docker
      podman
    ];

    serviceConfig = {
      Type = "oneshot";
      User = "gitlab-runner";
      WorkingDirectory = "/var/lib/gitlab-runner";
      StateDirectory = "gitlab-runner";
      RemainAfterExit = true;
    };

    # Configure runner from mounted JSON
    script = ''
      set -euo pipefail

      # Check if runner info exists
      if [ ! -f /runner-info/runner.json ]; then
        echo "ERROR: Runner info not found at /runner-info/runner.json"
        exit 1
      fi

      echo "Reading runner configuration..."
      RUNNER_NAME=$(jq -r '.name // "kubevirt-runner"' /runner-info/runner.json)
      RUNNER_URL=$(jq -r '.url // ""' /runner-info/runner.json)
      RUNNER_TOKEN=$(jq -r '.token // ""' /runner-info/runner.json)
      RUNNER_TAGS=$(jq -r '.tags // [] | join(",")' /runner-info/runner.json)
      RUNNER_EXECUTOR=$(jq -r '.executor // "shell"' /runner-info/runner.json)

      if [ -z "$RUNNER_URL" ] || [ -z "$RUNNER_TOKEN" ]; then
        echo "ERROR: Missing required runner configuration (url or token)"
        exit 1
      fi

      echo "Configuring GitLab Runner: $RUNNER_NAME"
      echo "URL: $RUNNER_URL"
      echo "Tags: $RUNNER_TAGS"
      echo "Executor: $RUNNER_EXECUTOR"

      # Register runner if not already registered
      if [ ! -f /var/lib/gitlab-runner/config.toml ]; then
        ${pkgs.gitlab-runner}/bin/gitlab-runner register \
          --non-interactive \
          --url "$RUNNER_URL" \
          --token "$RUNNER_TOKEN" \
          --name "$RUNNER_NAME" \
          --executor "$RUNNER_EXECUTOR" \
          --tag-list "$RUNNER_TAGS" \
          --run-untagged=false \
          --locked=false \
          --access-level=not_protected \
          --config /var/lib/gitlab-runner/config.toml

        echo "✓ Runner registered successfully"
      else
        echo "✓ Runner already configured"
      fi

      # Start runner in service mode
      echo "Starting GitLab Runner..."
      exec ${pkgs.gitlab-runner}/bin/gitlab-runner run \
        --config /var/lib/gitlab-runner/config.toml \
        --working-directory /var/lib/gitlab-runner
    '';

    # Deregister on stop
    preStop = ''
      if [ -f /var/lib/gitlab-runner/config.toml ]; then
        echo "Deregistering runner..."
        ${pkgs.gitlab-runner}/bin/gitlab-runner unregister \
          --config /var/lib/gitlab-runner/config.toml \
          --all-runners || true
      fi
    '';

    # Power off VM after service stops
    postStop = ''
      # Allow keeping VM alive for debugging
      if [ ! -f /etc/keep-runner ]; then
        echo "Shutting down VM..."
        sleep 5
        ${pkgs.systemd}/bin/systemctl poweroff
      else
        echo "Keeping VM alive (debug mode)"
      fi
    '';
  };

  # Ensure runner directory permissions
  systemd.tmpfiles.rules = [
    "d /var/lib/gitlab-runner 0755 gitlab-runner gitlab-runner -"
    "d /runner-info 0755 root root -"
  ];

  # Environment for CI/CD jobs
  environment.variables = {
    CI = "true";
    GITLAB_CI = "true";
    RUNNER_TEMP = "/tmp";
  };

  # Increase temp space for CI jobs
  boot.tmp = {
    useTmpfs = true;
    tmpfsSize = "50%";
  };

  # Optimize for CI workloads
  boot.kernel.sysctl = {
    "fs.inotify.max_user_watches" = 524288;
    "fs.file-max" = 2097152;
    "vm.swappiness" = 10;
  };
}
