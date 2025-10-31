# NixOS Base Images for KubeVirt

NixOS-based VM images for GitLab CI/CD on KubeVirt, featuring declarative configuration and reproducible builds.

## Why NixOS?

- **Reproducible Builds**: Bit-for-bit reproducible system configurations
- **Declarative Configuration**: Entire system defined in code
- **Atomic Upgrades**: Safe system updates with automatic rollback
- **Multiple Versions**: Run multiple versions of the same package simultaneously
- **Minimal Overhead**: Only install exactly what you need

## Image Variants

### base.nix - Comprehensive Build Environment

Full-featured base image with tools matching GitHub Actions runners.

**Build:**

```bash
nix build .#nixos-base
```

**Use Cases:**

- General-purpose CI/CD jobs
- Multi-language projects
- Container building workflows
- Cloud deployments

### runner.nix - GitLab Runner Integration

Automatic runner configuration with lifecycle management.

**Build:**

```bash
nix build .#nixos-runner
```

**Features:**

- Reads configuration from `/runner-info/runner.json`
- Auto-registration on boot
- Auto-deregistration on shutdown
- Auto-poweroff after job completion

**Configuration Example:**

```json
{
  "name": "nixos-runner-001",
  "url": "https://gitlab.example.com",
  "token": "glrt-xxxxxxxxxxxxxxxxxxxxx",
  "tags": ["nixos", "docker", "nix"],
  "executor": "shell"
}
```

### default.nix - Build Entry Point

Provides both image variants:

- `base` - Full environment
- `runner` - With GitLab integration

## Quick Start

### 1. Build Image Locally

```bash
# From repository root
nix build .#nixos-runner

# Result is a QCOW2 image
ls -lh result
file result  # should show "QCOW2 image"
```

### 2. Deploy to KubeVirt

```bash
# Apply the VM template
kubectl apply -f vm-template.yaml

# Check VM status
kubectl get vmi

# Access VM console
virtctl console gitlab-runner-nixos
```

### 3. Monitor Runner

```bash
# Watch runner logs
kubectl logs -f virt-launcher-gitlab-runner-nixos...

# Inside VM, check runner status
journalctl -u gitlab-runner-vm -f
```

## Configuration Files

### base.nix

Core system configuration with comprehensive package set.

**Key Sections:**

- System packages (languages, tools, CLIs)
- Network configuration
- User management (runner user with sudo)
- Docker and Podman virtualization
- SSH access for debugging
- Boot configuration for KubeVirt

### runner.nix

GitLab Runner-specific configuration.

**Key Components:**

- `gitlab-runner-vm.service` - Main runner service
- `/runner-info` mount - Configuration source
- Auto-shutdown logic - Post-job cleanup
- Environment variables - CI context

### vm-template.yaml

Kubernetes manifest for deploying VMs.

**Key Resources:**

- VirtualMachine definition
- ConfigMap with runner config
- CloudInit setup
- Network configuration

## Customization Guide

### Adding Packages

Edit `base.nix` and add to `environment.systemPackages`:

```nix
environment.systemPackages = with pkgs; [
  # ... existing packages ...
  myCustomPackage
  anotherTool
];
```

### Adding Services

Enable systemd services in `base.nix`:

```nix
services.postgresql = {
  enable = true;
  package = pkgs.postgresql_16;
  enableTCPIP = true;
};
```

### Custom Runner Executor

Modify `runner.nix` to use different executors:

```nix
script = ''
  # ... registration ...
  --executor "docker" \
  --docker-image "alpine:latest" \
  --docker-privileged \
  # ...
'';
```

## Advanced Usage

### Nix Binary Cache

Speed up builds with binary caching:

```nix
nix.settings = {
  substituters = [
    "https://cache.nixos.org"
    "https://your-cache.example.com"
  ];
  trusted-public-keys = [
    "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
    "your-cache:xxxxxxxxxxxxx"
  ];
};
```

### Flakes in CI Jobs

```bash
# Inside CI job
nix develop .#
nix build .#myPackage
```

### Cross-Compilation

Build for different architectures:

```bash
# Build ARM64 image on x86_64
nix build .#packages.aarch64-linux.nixos-base --system aarch64-linux
```

### Persistent Data

Mount volumes for caching:

```yaml
volumes:
  - name: nix-store-cache
    persistentVolumeClaim:
      claimName: nix-store-pvc
```

## Debugging

### Check System Configuration

```bash
# Inside VM
nixos-version
nix-env --version

# List installed packages
nix-env -qa
```

### Service Logs

```bash
# Runner service logs
journalctl -u gitlab-runner-vm -n 100 -f

# System logs
journalctl -b
```

### Network Issues

```bash
# Check network connectivity
ip addr
ping -c 3 gitlab.com

# DNS resolution
nslookup gitlab.com
```

### Keep VM Alive for Debugging

```bash
# Prevent auto-shutdown
sudo touch /etc/keep-runner

# Now the VM stays running after jobs
```

## Performance Optimization

### Disk Performance

Use virtio-scsi for better performance:

```yaml
devices:
  disks:
    - name: rootdisk
      disk:
        bus: virtio
```

### Memory Management

Tune for CI workloads:

```nix
boot.kernel.sysctl = {
  "vm.swappiness" = 10;
  "vm.dirty_ratio" = 15;
  "vm.dirty_background_ratio" = 5;
};
```

### Parallel Jobs

Enable concurrent job execution:

```toml
# In runner config
concurrent = 4
```

## Troubleshooting

### VM Boot Issues

**Symptom**: VM doesn't start
**Check**:

```bash
kubectl describe vmi gitlab-runner-nixos
kubectl logs virt-launcher-xxx
```

### Runner Registration Fails

**Symptom**: Runner doesn't appear in GitLab
**Check**:

```bash
# Verify ConfigMap
kubectl get configmap gitlab-runner-config -o yaml

# Check mount inside VM
ls -la /runner-info/
cat /runner-info/runner.json
```

### Out of Disk Space

**Symptom**: Builds fail with disk errors
**Solution**:

```bash
# Garbage collection
nix-collect-garbage -d

# Or increase PVC size
kubectl edit pvc gitlab-runner-pvc
```

## Best Practices

1. **Version Control**: Keep NixOS configs in git
2. **Binary Caching**: Use Cachix or your own cache
3. **Resource Limits**: Set appropriate CPU/memory limits
4. **Security**: Don't commit tokens, use Secrets
5. **Monitoring**: Track resource usage and job metrics
6. **Updates**: Regularly update nixpkgs input

## Contributing

When modifying NixOS configurations:

1. Test locally first: `nix build .#nixos-base`
2. Verify in KubeVirt: Deploy and run test jobs
3. Document changes in this README
4. Update `vm-template.yaml` if needed
5. Submit PR with clear description

## Resources

- [NixOS Manual](https://nixos.org/manual/nixos/stable/)
- [NixOS Wiki](https://nixos.wiki/)
- [Nix Pills](https://nixos.org/guides/nix-pills/)
- [KubeVirt User Guide](https://kubevirt.io/user-guide/)
- [GitLab Runner Docs](https://docs.gitlab.com/runner/)

## License

MIT - See [LICENSE](../../LICENSE)
