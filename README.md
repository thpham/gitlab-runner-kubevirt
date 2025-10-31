# gitlab-runner-kubevirt

GitLab Runner custom executor for running CI/CD jobs in VMs on Kubernetes using KubeVirt.

## Features

- **QEMU MicroVM Support**: Fast-booting minimal VMs (~125ms vs ~500ms)
- **Multi-Architecture**: Run x86_64, aarch64, arm64, riscv64 VMs
- **Multi-Platform Container Images**: Native AMD64 and ARM64 container support
- **KubeVirt Native**: Leverages Kubernetes for VM orchestration
- **Custom Executor**: Integrates seamlessly with GitLab Runner
- **Security Hardened**: Regular dependency updates and CVE scanning

## Prerequisites

- Kubernetes cluster with KubeVirt installed
- GitLab Runner (deployed via Helm chart)

## Installation

### Using GitLab Runner Helm Chart

Add to your `values.yaml`:

```yaml
image: ghcr.io/thpham/gitlab-runner-kubevirt:latest

runners:
  executor: custom
  config: |
    [[runners]]
      name = "kubevirt"
      executor = "custom"

      [runners.custom]
        config_exec = "/bin/gitlab-runner-kubevirt"
        config_args = ["config"]
        prepare_exec = "/bin/gitlab-runner-kubevirt"
        prepare_args = [
          "prepare",
          "--shell", "bash",
          "--default-image", "registry.example.com/runner:latest",
          "--default-machine-type", "microvm",
          "--default-architecture", "x86_64",
          "--ssh-user", "runner",
          "--ssh-password", "runner"
        ]
        run_exec = "/bin/gitlab-runner-kubevirt"
        run_args = ["run"]
        cleanup_exec = "/bin/gitlab-runner-kubevirt"
        cleanup_args = ["cleanup"]
```

Deploy:

```bash
helm repo add gitlab https://charts.gitlab.io
helm install gitlab-runner gitlab/gitlab-runner -f values.yaml
```

## Configuration

### Machine Types

- `q35`: Standard PC (default)
- `microvm`: Minimal, fast-booting VM
- `virt`: ARM/RISC-V machines

### Architecture Options

- `x86_64` / `amd64`: x86 64-bit
- `aarch64` / `arm64`: ARM 64-bit
- `riscv64`: RISC-V 64-bit

### Environment Variables

Configure via GitLab CI variables to customize VMs per-job:

```yaml
variables:
  # VM Configuration
  CUSTOM_ENV_VM_MACHINE_TYPE: "microvm"
  CUSTOM_ENV_VM_ARCHITECTURE: "aarch64"
  CUSTOM_ENV_CI_JOB_IMAGE: "registry.example.com/runner-arm64:latest"
  CUSTOM_ENV_VM_TTL: "3h"  # VM time-to-live for garbage collection

  # Resource Allocation (overrides runner defaults)
  CUSTOM_ENV_VM_CPU_REQUEST: "2"       # CPU cores requested
  CUSTOM_ENV_VM_CPU_LIMIT: "4"         # CPU cores limit
  CUSTOM_ENV_VM_MEMORY_REQUEST: "4Gi"  # Memory requested
  CUSTOM_ENV_VM_MEMORY_LIMIT: "8Gi"    # Memory limit
  CUSTOM_ENV_VM_STORAGE_REQUEST: "20Gi" # Ephemeral storage requested
  CUSTOM_ENV_VM_STORAGE_LIMIT: "50Gi"   # Ephemeral storage limit
```

**Resource Configuration Hierarchy:**
1. GitLab CI job variables (highest priority) - per-job customization
2. Runner default values (fallback) - set in Helm chart `prepare_args`

**Example: Different resources for different job types**

```yaml
# .gitlab-ci.yml
unit-tests:
  variables:
    CUSTOM_ENV_VM_CPU_REQUEST: "1"
    CUSTOM_ENV_VM_MEMORY_REQUEST: "2Gi"
  script:
    - make test

build-heavy:
  variables:
    CUSTOM_ENV_VM_CPU_REQUEST: "8"
    CUSTOM_ENV_VM_CPU_LIMIT: "16"
    CUSTOM_ENV_VM_MEMORY_REQUEST: "16Gi"
    CUSTOM_ENV_VM_MEMORY_LIMIT: "32Gi"
    CUSTOM_ENV_VM_STORAGE_REQUEST: "100Gi"
  script:
    - make build-all
```

### Garbage Collection

Orphaned VMs are automatically tagged with TTL labels for cleanup:

```bash
# List VMs with their expiration info
kubectl get vmi -n gitlab-runner -l io.kubevirt.gitlab-runner/id --show-labels

# Manual cleanup of expired VMs
gitlab-runner-kubevirt gc --namespace gitlab-runner

# Dry-run mode (see what would be deleted)
gitlab-runner-kubevirt gc --dry-run

# Custom max age
gitlab-runner-kubevirt gc --max-age 1h
```

**Automated cleanup** with CronJob:

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: gitlab-runner-vm-gc
  namespace: gitlab-runner
spec:
  schedule: "*/15 * * * *"  # Every 15 minutes
  jobTemplate:
    spec:
      template:
        spec:
          serviceAccountName: gitlab-runner
          containers:
          - name: gc
            image: ghcr.io/thpham/gitlab-runner-kubevirt:latest
            args: ["gc", "--max-age", "3h"]
          restartPolicy: OnFailure
```

## Development

### Quick Start

```bash
# Enter development environment
nix develop

# Build binary
make build

# Run tests
make test

# Build container image
nix build .#container
```

### Common Commands

```bash
make build          # Build binary
make test           # Run tests
make nix-build      # Reproducible Nix build
make nix-container  # Build container image
make help           # Show all commands
```

### Development Environment

The Nix flake provides:
- Go 1.24 toolchain
- Kubernetes tools (kubectl, helm, k9s, kind)
- Container tools (docker, podman, skopeo)
- All development dependencies

### Building

```bash
# Build binary for current platform
go build -o gitlab-runner-kubevirt .

# Build with Nix (reproducible)
nix build

# Build container image
nix build .#container
docker load < result

# Multi-architecture (requires Linux or remote builders)
# On macOS, use GitHub Actions or Linux VM
make release-multiarch
```

### Multi-Architecture Container Images

The project automatically builds **multi-arch container images** for AMD64 and ARM64 via GitHub Actions.

**Available images:**
```bash
# Multi-arch manifest (automatically selects the right architecture)
ghcr.io/thpham/gitlab-runner-kubevirt:latest
ghcr.io/thpham/gitlab-runner-kubevirt:v1.0.0
```

When you pull the image, Docker/Podman/containerd automatically selects the correct architecture for your platform - **no need for architecture-specific tags!**

**Verify multi-arch support:**
```bash
docker manifest inspect ghcr.io/thpham/gitlab-runner-kubevirt:latest
```

**Build locally for specific architecture:**
```bash
# AMD64
nix build .#packages.x86_64-linux.container
docker load < result

# ARM64
nix build .#packages.aarch64-linux.container
docker load < result
```

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Run tests: `make test`
5. Build: `make build`
6. Submit a pull request

## License

MIT
