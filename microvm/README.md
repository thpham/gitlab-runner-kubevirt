# KubeVirt Base Images

Pre-configured base images for running GitLab CI/CD jobs in KubeVirt VMs. Inspired by [GitHub Actions runner images](https://github.com/actions/runner-images) and designed to provide comprehensive build environments.

## Overview

This directory contains build definitions for KubeVirt-compatible VM images with pre-installed tooling for common CI/CD workflows. Similar to GitHub Actions hosted runners, these images come with:

- Multiple language runtimes (Go, Node.js, Python, Ruby, etc.)
- Build tools (make, cmake, gcc, clang, etc.)
- Container tools (Docker, Podman, Buildah, Skopeo)
- Kubernetes tools (kubectl, helm, kind, minikube)
- Cloud CLIs (AWS, Azure, GCP)
- Database clients and common utilities

## Available Images

### NixOS Images

Located in `microvm/nixos/`:

#### 1. **nixos-base** - Comprehensive Build Environment

A full-featured base image with tools comparable to GitHub Actions Ubuntu runners.

**Included Software:**

- **Languages**: Go 1.24-1.25, Node.js 20/22/24, Python 3.11-3.13, Ruby 3.4, Java 11/17/21
- **Build Tools**: gcc, clang, make, cmake, ninja, autotools, just
- **Configuration Management**: Ansible, Chef, Habitat, Nomad
- **Container Tools**: Docker, Podman, Buildah, Skopeo, Dive, Regclient
- **Kubernetes**: kubectl, oc cli, helm, kustomize, kind, k3d
- **Cloud CLIs**: AWS CLI v2, Google Cloud SDK, Azure CLI,
- **Infrastrucutre as Code**: Terraform, Tofu, Terragrunt
- **Database Clients**: PostgreSQL, MySQL, SQLite, Redis
- **Version Control**: Git, Git LFS, GitHub CLI, GitLab CLI
- **Utilities**: jq, yq, ripgrep, fd, curl, sed, awk, ...

#### 2. **nixos-runner** - GitLab Runner Integration

Extends `nixos-base` with automatic GitLab Runner configuration from mounted volume.

**Features:**

- Automatic runner registration from `/runner-info/runner.json`
- Automatic deregistration on shutdown
- Support for shell, docker, and custom executors
- VM auto-shutdown after job completion (configurable)

## Building Images

### Prerequisites

- Nix with flakes support
- Linux system (for NixOS image builds)

### Build Commands

```bash
# Build specific image variant
nix build .#nixos-base           # Base image QCOW2
nix build .#nixos-runner         # Runner image QCOW2

# Results are symlinked to ./result
ls -lh result
file result  # Verify QCOW2 format
```

### Image Sizes (Approximate)

- **nixos-base**: ~8-10 GB
- **nixos-runner**: ~8-10 GB

## Usage with KubeVirt

### 1. Using Pre-built Container Images

The easiest way is to use container images as containerDisks:

```yaml
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: gitlab-runner-nixos
spec:
  running: true
  template:
    spec:
      domain:
        devices:
          disks:
            - name: containerdisk
              disk:
                bus: virtio
      volumes:
        - name: containerdisk
          containerDisk:
            image: ghcr.io/thpham/gitlab-runner-kubevirt/nixos-runner:latest
```

### 2. Using QCOW2 Images with DataVolumes

For better performance, use DataVolumes with QCOW2 images:

```yaml
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataVolume
metadata:
  name: nixos-base-dv
spec:
  source:
    http:
      url: "https://github.com/thpham/gitlab-runner-kubevirt/releases/download/v1.0.0/nixos-base.qcow2"
  pvc:
    accessModes:
      - ReadWriteOnce
    resources:
      requests:
        storage: 20Gi
```

### 3. GitLab Runner Configuration

Mount runner configuration via ConfigMap:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: gitlab-runner-config
data:
  runner.json: |
    {
      "name": "kubevirt-nixos-runner-1",
      "url": "https://gitlab.com",
      "token": "glrt-xxxxxxxxxxxxxxxxxxxxx",
      "tags": ["nixos", "kubevirt", "docker"],
      "executor": "shell"
    }
---
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: gitlab-runner
spec:
  template:
    spec:
      domain:
        devices:
          disks:
            - name: runner-info
              disk:
                bus: virtio
      volumes:
        - name: runner-info
          configMap:
            name: gitlab-runner-config
```

## Runner Configuration Format

The `runner.json` file supports the following fields:

```json
{
  "name": "runner-name", // Runner name (default: kubevirt-runner)
  "url": "https://gitlab.com", // GitLab instance URL (required)
  "token": "glrt-xxxxx", // Runner registration token (required)
  "tags": ["tag1", "tag2"], // Runner tags (default: [])
  "executor": "shell" // Executor type (default: shell)
}
```

## Customization

### Creating Custom Images

1. Create a new configuration file:

```nix
# microvm/nixos/custom.nix
{ config, pkgs, lib, ... }:
{
  imports = [ ./base.nix ];

  environment.systemPackages = with pkgs; [
    # Add your custom packages
    myCustomTool
  ];
}
```

2. Add to `flake.nix`:

```nix
nixos-custom = (pkgs.nixos {
  imports = [ ./microvm/nixos/custom.nix ];
}).config.system.build.qcow2;
```

3. Build:

```bash
nix build .#nixos-custom
```

### Debugging VMs

Keep VMs running after jobs for debugging:

```bash
# Inside the VM
sudo touch /etc/keep-runner

# The VM won't auto-shutdown after runner exits
```

## Resource Requirements

### Recommended VM Specifications

| Image        | CPU       | Memory | Disk     |
| ------------ | --------- | ------ | -------- |
| nixos-base   | 2-4 cores | 4-8 GB | 20-40 GB |
| nixos-runner | 2-4 cores | 4-8 GB | 20-40 GB |

### Scaling Considerations

- Use persistent volumes for caching (npm, pip, go modules)
- Enable Nix binary caching for faster rebuilds
- Consider runner pools for concurrent jobs
- Monitor disk usage and implement cleanup policies

## CI/CD Integration

### GitHub Actions Workflow

See [`.github/workflows/build-images.yml`](../.github/workflows/build-images.yml) for automated MicroVM image building.

### GitLab CI Pipeline

```yaml
build-nixos-images:
  image: nixos/nix:latest
  script:
    - nix build .#nixos-base
    - nix build .#nixos-runner
  artifacts:
    paths:
      - result/
```

## Roadmap

Future image variants:

- [ ] **Ubuntu** - Traditional Ubuntu-based images
- [ ] **Windows** - Windows Server images
- [ ] **macOS** - macOS images (via OSX-KVM)

## Troubleshooting

### Build Issues

**Problem**: "error: refusing to build NixOS configuration on non-Linux system"
**Solution**: NixOS images can only be built on Linux. Use Docker or a Linux VM.

**Problem**: Out of disk space during build
**Solution**: Images are large. Ensure at least 50GB free space.

### Runtime Issues

**Problem**: VM doesn't start or crashes immediately
**Solution**: Check KubeVirt logs, ensure proper resources allocated.

**Problem**: Runner doesn't register
**Solution**: Verify `/runner-info/runner.json` is mounted and contains valid credentials.

## Contributing

Contributions welcome! Please:

1. Test changes thoroughly
2. Update documentation
3. Follow existing patterns
4. Submit PRs with clear descriptions

## References

- [GitHub Actions Runner Images](https://github.com/actions/runner-images)
- [KubeVirt Actions Runner](https://github.com/zhaofengli/kubevirt-actions-runner)
- [KubeVirt Documentation](https://kubevirt.io/user-guide/)
- [NixOS Manual](https://nixos.org/manual/nixos/stable/)

## License

MIT License - See [LICENSE](../LICENSE) for details.
