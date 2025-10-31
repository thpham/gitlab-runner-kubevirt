# gitlab-runner-kubevirt

GitLab Runner custom executor for running CI/CD jobs in VMs on Kubernetes using KubeVirt.

[![Build and Publish](https://github.com/thpham/gitlab-runner-kubevirt/actions/workflows/build-publish.yml/badge.svg)](https://github.com/thpham/gitlab-runner-kubevirt/actions/workflows/build-publish.yml)

## Features

- **QEMU MicroVM Support**: Fast-booting minimal VMs (~125ms vs ~500ms)
- **Multi-Architecture**: Run x86_64, aarch64, arm64, riscv64 VMs
- **Multi-Platform Container Images**: Native AMD64 and ARM64 container support
- **KubeVirt Native**: Leverages Kubernetes for VM orchestration
- **Custom Executor**: Integrates seamlessly with GitLab Runner
- **Security Hardened**: Regular dependency updates and CVE scanning
- **Secure Credential Management**: Kubernetes Secrets with RBAC protection

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
          "--ssh-user", "runner"
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
  CUSTOM_ENV_VM_TTL: "3h" # VM time-to-live for garbage collection

  # Resource Allocation (overrides runner defaults)
  CUSTOM_ENV_VM_CPU_REQUEST: "2" # CPU cores requested
  CUSTOM_ENV_VM_CPU_LIMIT: "4" # CPU cores limit
  CUSTOM_ENV_VM_MEMORY_REQUEST: "4Gi" # Memory requested
  CUSTOM_ENV_VM_MEMORY_LIMIT: "8Gi" # Memory limit
  CUSTOM_ENV_VM_STORAGE_REQUEST: "20Gi" # Ephemeral storage requested
  CUSTOM_ENV_VM_STORAGE_LIMIT: "50Gi" # Ephemeral storage limit
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

Orphaned VMs are automatically tagged with TTL labels for cleanup. The garbage collector automatically deletes both VMs and their associated credential Secrets (containing SSH credentials and cloud-init data):

```bash
# List VMs with their expiration info
kubectl get vmi -n gitlab-runner -l io.kubevirt.gitlab-runner/id --show-labels

# Manual cleanup of expired VMs (also deletes associated Secrets)
gitlab-runner-kubevirt gc --namespace gitlab-runner

# Dry-run mode (see what would be deleted)
gitlab-runner-kubevirt gc --dry-run

# Custom max age
gitlab-runner-kubevirt gc --max-age 1h
```

**Note:** Garbage collection cleans up both VirtualMachineInstances and their credential Secrets (containing SSH credentials and cloud-init userdata) to prevent Secret accumulation.

**Automated cleanup** with CronJob:

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: gitlab-runner-vm-gc
  namespace: gitlab-runner
spec:
  schedule: "*/15 * * * *" # Every 15 minutes
  jobTemplate:
    spec:
      template:
        spec:
          serviceAccountName: gitlab-runner
          containers:
            - name: gc
              image: ghcr.io/thpham/gitlab-runner-kubevirt:latest
              args: ["gc", "--max-age", "3h"]
              env:
                - name: KUBEVIRT_EXECUTOR
                  value: "true"
          restartPolicy: OnFailure
```

### Container Entrypoint Behavior

The container image includes both `gitlab-runner` (standard GitLab Runner) and `gitlab-runner-kubevirt` (KubeVirt executor) binaries. The entrypoint automatically routes to the appropriate binary based on the `KUBEVIRT_EXECUTOR` environment variable:

- **Default** (`KUBEVIRT_EXECUTOR` not set): Executes `gitlab-runner` for standard GitLab Runner operations (register, run daemon, etc.)
- **KubeVirt mode** (`KUBEVIRT_EXECUTOR=true`): Executes `gitlab-runner-kubevirt` for KubeVirt-specific operations (gc, cleanup, prepare, run, config)

**When to use `KUBEVIRT_EXECUTOR=true`:**

- Garbage collection CronJobs (as shown above)
- Manual execution of KubeVirt executor commands
- Standalone executor operations outside GitLab Runner daemon

**Note:** When using the GitLab Runner Helm chart with custom executor configuration, you don't need to set this variable as the executor directly calls `/bin/gitlab-runner-kubevirt`.

### Security

#### SSH Credential Management

GitLab Runner KubeVirt uses a secure credential management system to protect SSH access to VMs:

**Automatic Security Features:**

1. **Unique Random Passwords**: Each VM receives a cryptographically secure 32-character random password
2. **Kubernetes Secrets**: Credentials and cloud-init data stored in RBAC-protected Secrets (not plaintext in VM specs)
3. **Cloud-init Injection**: Cloud-init userdata stored as Secret, referenced by VM (passwords never visible in VM objects)
4. **Automatic Cleanup**: Secrets automatically deleted when VMs are cleaned up
5. **No Plaintext Storage**: Passwords never stored in VM annotations, logs, or VM specifications

**How it works:**

```
Prepare Phase:
  1. Generate random password (crypto/rand)
  2. Generate cloud-init with bcrypt-hashed password (Linux) or plaintext (Windows)
  3. Create Kubernetes Secret with:
     - SSH username and password (for Run phase)
     - Cloud-init userdata (for VM initialization)
  4. Create VM with Secret reference (not inline userdata)
  5. Store only Secret reference in VM annotation

Run Phase:
  1. Retrieve Secret reference from VM annotation
  2. Fetch SSH credentials from Kubernetes Secret
  3. Connect to VM via SSH

Cleanup Phase:
  1. Retrieve Secret reference from VM annotation
  2. Delete Kubernetes Secret (removes both SSH creds and cloud-init data)
  3. Delete VM
```

**RBAC Requirements:**

The GitLab Runner service account requires these permissions for Secret management:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: gitlab-runner-kubevirt
  namespace: gitlab-runner
rules:
  # VirtualMachineInstance permissions
  - apiGroups: ["kubevirt.io"]
    resources: ["virtualmachineinstances"]
    verbs: ["get", "list", "create", "delete", "watch"]

  # Secret permissions for SSH credentials
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["create", "get", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: gitlab-runner-kubevirt
  namespace: gitlab-runner
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: gitlab-runner-kubevirt
subjects:
  - kind: ServiceAccount
    name: gitlab-runner
    namespace: gitlab-runner
```

**Secret Structure:**

Each VM gets a single Kubernetes Secret containing:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: vm-creds-<job-id>
  labels:
    io.kubevirt.gitlab-runner/id: <job-id>
    io.kubevirt.gitlab-runner/type: vm-credentials
stringData:
  user: runner # SSH username
  password: <random-32> # SSH password
  userdata: | # Cloud-init YAML
    #cloud-config
    users:
      - name: runner
        passwd: <bcrypt-hash>  # Linux: hashed, Windows: plaintext
        ...
```

**Security Benefits:**

- **Single Secret Per VM**: One Secret contains all credentials (SSH + cloud-init)
- **RBAC Protected**: Secret access controlled via Kubernetes RBAC policies
- **No Plaintext in VM Specs**: Password never visible in `kubectl describe vmi`
- **Scoped to Jobs**: Each CI/CD job gets unique credentials
- **Automatic Cleanup**: Secret deleted when VM is cleaned up
- **Audit Trail**: All Secret access logged by Kubernetes audit logs

#### Windows VM Support

GitLab Runner KubeVirt supports both Linux and Windows VMs with automatic OS detection based on the shell parameter:

**OS Detection:**

- `--shell bash` → Linux VM (cloud-init with bcrypt-hashed passwords)
- `--shell pwsh` → Windows VM (Cloudbase-Init with plaintext passwords)

**Windows Requirements:**

Your Windows container disk images must include:

1. **Cloudbase-Init**: Windows port of cloud-init for VM initialization

   - Download: https://cloudbase-init.readthedocs.io/en/latest/
   - Minimum version: 1.1.0+
   - **Required Configuration**: Must enable `SetUserPasswordPlugin` in `cloudbase-init.conf`:

     ```ini
     [DEFAULT]
     username=Administrator
     inject_user_password=true

     plugins=cloudbaseinit.plugins.common.mtu.MTUPlugin,
             cloudbaseinit.plugins.common.sethostname.SetHostNamePlugin,
             cloudbaseinit.plugins.windows.createuser.CreateUserPlugin,
             cloudbaseinit.plugins.common.setuserpassword.SetUserPasswordPlugin
     ```

2. **OpenSSH Server**: For remote access via SSH

   - Built-in on Windows Server 2019+ and Windows 10 1809+
   - Must be installed and configured to start automatically
   - Port 22 must be accessible

3. **PowerShell**: For script execution
   - PowerShell 5.1+ or PowerShell Core 7+

**Windows Configuration Example:**

```yaml
runners:
  executor: custom
  config: |
    [[runners]]
      name = "kubevirt-windows"
      executor = "custom"

      [runners.custom]
        config_exec = "/bin/gitlab-runner-kubevirt"
        config_args = ["config"]
        prepare_exec = "/bin/gitlab-runner-kubevirt"
        prepare_args = [
          "prepare",
          "--shell", "pwsh",  # Windows indicator
          "--default-image", "registry.example.com/windows-server-2022:latest",
          "--ssh-user", "runner"
        ]
        run_exec = "/bin/gitlab-runner-kubevirt"
        run_args = ["run"]
        cleanup_exec = "/bin/gitlab-runner-kubevirt"
        cleanup_args = ["cleanup"]
```

**Security Notes for Windows:**

- Cloudbase-Init uses plaintext passwords (industry standard)
- Credentials still protected by Kubernetes Secret RBAC
- Random 32-character passwords meet Windows complexity requirements
- Administrator group membership required for CI/CD operations

**Supported Windows Versions:**

- Windows Server 2019, 2022
- Windows 10 version 1809+
- Windows 11

**Troubleshooting Windows VM Initialization:**

If password authentication fails on Windows VMs, verify Cloudbase-Init configuration:

```powershell
# Check Cloudbase-Init logs
Get-Content "C:\Program Files\Cloudbase Solutions\Cloudbase-Init\log\cloudbase-init.log"

# Verify SetUserPasswordPlugin is enabled
Get-Content "C:\Program Files\Cloudbase Solutions\Cloudbase-Init\conf\cloudbase-init.conf" | Select-String "SetUserPasswordPlugin"

# Check if inject_user_password is enabled
Get-Content "C:\Program Files\Cloudbase Solutions\Cloudbase-Init\conf\cloudbase-init.conf" | Select-String "inject_user_password"
```

Common issues:

- **Password not set**: `SetUserPasswordPlugin` not enabled in plugins list
- **Random password instead of cloud-config password**: `inject_user_password=false` or not set
- **User not created**: `CreateUserPlugin` not enabled in plugins list

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

## Base Images for KubeVirt VMs

Pre-configured VM images with comprehensive tooling for CI/CD workloads, similar to GitHub Actions hosted runners.

### Available Images

Located in [`microvm/`](microvm/) directory:

#### NixOS Images

- **nixos-base**: Full-featured build environment with multi-language support (Go, Node.js, Python, Ruby, Java), build tools (gcc, clang, make, cmake), container tools (Docker, Podman, Buildah), Kubernetes tools (kubectl, helm, k9s), and cloud CLIs (AWS, Azure, GCP)
- **nixos-runner**: Extends nixos-base with automatic GitLab Runner registration and lifecycle management

### Quick Start with Base Images

```bash
# Build NixOS runner image (Linux only)
nix build .#nixos-runner

# Deploy to KubeVirt
kubectl apply -f microvm/nixos/vm-template.yaml

# Check runner status
kubectl get vmi -n gitlab-runner
```

### Using Pre-built Base Images

```yaml
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: gitlab-runner-nixos
spec:
  template:
    spec:
      volumes:
        - name: containerdisk
          containerDisk:
            image: ghcr.io/thpham/gitlab-runner-kubevirt/nixos-runner:latest
```

**Complete documentation**: See [`microvm/README.md`](microvm/README.md)

### Building Custom Images

```nix
# microvm/nixos/custom.nix
{ config, pkgs, lib, ... }:
{
  imports = [ ./base.nix ];

  environment.systemPackages = with pkgs; [
    myCustomTool
  ];
}
```

```bash
# Add to flake.nix packages, then build
nix build .#nixos-custom
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
