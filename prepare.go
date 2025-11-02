package main

import (
	"context"
	"fmt"
	"os"
	"time"

	"k8s.io/apimachinery/pkg/watch"
	kubevirtapi "kubevirt.io/api/core/v1"
	kubevirt "kubevirt.io/client-go/kubecli"
)

type PrepareCmd struct {
	DefaultImage                   string        `name:"default-image"`
	DefaultImagePullPolicy         string        `name:"default-image-pull-policy"`
	DefaultImagePullSecret         string        `name:"default-image-pull-secret"`
	DefaultMachineType             string        `name:"default-machine-type" help:"QEMU machine type (e.g., 'q35', 'microvm', 'virt')"`
	DefaultArchitecture            string        `name:"default-architecture" help:"VM architecture (e.g., 'x86_64', 'aarch64', 'arm64')"`
	DefaultCPURequest              string        `name:"default-cpu-request" default:"1"`
	DefaultCPULimit                string        `name:"default-cpu-limit" default:"1"`
	DefaultMemoryRequest           string        `name:"default-memory-request" default:"1Gi"`
	DefaultMemoryLimit             string        `name:"default-memory-limit" default:"1Gi"`
	DefaultEphemeralStorageRequest string        `name:"default-ephemeral-storage-request"`
	DefaultEphemeralStorageLimit   string        `name:"default-ephemeral-storage-limit"`
	DefaultTimezone                string        `name:"default-timezone" default:"Etc/UTC" env:"CUSTOM_ENV_VM_TIMEZONE"`
	Timeout                        time.Duration `name:"timeout" default:"1h"`
	DialTimeout                    time.Duration `default:"10s"`

	RunConfig `embed`
}

func (cmd *PrepareCmd) Run(ctx context.Context, client kubevirt.KubevirtClient, jctx *JobContext) error {
	if jctx.CPURequest == "" {
		jctx.CPURequest = cmd.DefaultCPURequest
	}
	if jctx.CPULimit == "" {
		jctx.CPULimit = cmd.DefaultCPULimit
	}
	if jctx.MemoryRequest == "" {
		jctx.MemoryRequest = cmd.DefaultMemoryRequest
	}
	if jctx.MemoryLimit == "" {
		jctx.MemoryLimit = cmd.DefaultMemoryLimit
	}
	if jctx.EphemeralStorageRequest == "" {
		jctx.EphemeralStorageRequest = cmd.DefaultEphemeralStorageRequest
	}
	if jctx.EphemeralStorageLimit == "" {
		jctx.EphemeralStorageLimit = cmd.DefaultEphemeralStorageLimit
	}
	if jctx.ImagePullPolicy == "" {
		jctx.ImagePullPolicy = cmd.DefaultImagePullPolicy
	}
	if jctx.ImagePullSecret == "" {
		jctx.ImagePullSecret = cmd.DefaultImagePullSecret
	}
	if jctx.Image == "" {
		jctx.Image = cmd.DefaultImage
	}
	if jctx.Timezone == "" {
		jctx.Timezone = cmd.DefaultTimezone
	}
	if jctx.MachineType == "" {
		jctx.MachineType = cmd.DefaultMachineType
	}
	if jctx.Architecture == "" {
		jctx.Architecture = cmd.DefaultArchitecture
	}

	// Generate random password for this VM
	randomPassword, err := GenerateSecurePassword(32)
	if err != nil {
		return fmt.Errorf("failed to generate password: %w", err)
	}

	// Generate cloud-init user-data with random password (OS-specific based on shell)
	cloudInitUserData, err := GenerateCloudInitUserData(cmd.Shell, cmd.SSH.User, randomPassword)
	if err != nil {
		return fmt.Errorf("failed to generate cloud-init: %w", err)
	}

	// Get K8s config for Secret operations
	cfg, err := KubeConfig()
	if err != nil {
		return fmt.Errorf("failed to get kubernetes config: %w", err)
	}

	// Create Secret with SSH credentials and cloud-init userdata
	secret, err := CreateVMSecret(ctx, cfg, jctx.Namespace, jctx, cmd.SSH.User, randomPassword, cloudInitUserData)
	if err != nil {
		return fmt.Errorf("failed to create VM secret: %w", err)
	}

	fmt.Fprintf(os.Stderr, "Created VM credentials secret: %s\n", secret.Name)

	// Update RunConfig to reference secret (not store password)
	rc := cmd.RunConfig
	rc.SSH.Password = ""           // Clear password from config
	rc.SSH.SecretRef = secret.Name // Store secret reference

	fmt.Fprintf(os.Stderr, "Creating Virtual Machine instance\n")

	// Create VM with secret reference (KubeVirt will read userdata from Secret)
	vm, err := CreateJobVM(ctx, client, jctx, &rc, secret.Name)
	if err != nil {
		// Cleanup secret if VM creation fails
		_ = DeleteSSHSecret(ctx, cfg, jctx.Namespace, secret.Name)
		return err
	}

	fmt.Fprintf(os.Stderr, "Waiting for Virtual Machine instance %s to be ready...\n", vm.ObjectMeta.Name)

	// Wait for new VM to get an IP

	timeout, stop := context.WithTimeout(ctx, cmd.Timeout)
	defer stop()

	err = WatchJobVM(timeout, client, jctx, vm, func(et watch.EventType, val *kubevirtapi.VirtualMachineInstance) error {
		if et == watch.Error {
			// Retry on watch failure
			return nil
		}
		vm = val
		if len(vm.Status.Interfaces) == 0 || vm.Status.Interfaces[0].IP == "" {
			return nil
		}
		for _, cond := range vm.Status.Conditions {
			if cond.Type == "Ready" && cond.Status == "True" {
				return ErrWatchDone
			}
		}
		return nil
	})
	if err != nil {
		return err
	}

	fmt.Fprintln(os.Stderr, "Virtual Machine instance is ready.")
	fmt.Fprintln(os.Stderr, "Name:", vm.ObjectMeta.Name)
	fmt.Fprintln(os.Stderr, "Image:", jctx.Image)
	if jctx.MachineType != "" {
		fmt.Fprintln(os.Stderr, "Machine Type:", jctx.MachineType)
	}
	if jctx.Architecture != "" {
		fmt.Fprintln(os.Stderr, "Architecture:", jctx.Architecture)
	}
	fmt.Fprintln(os.Stderr, "Node:", vm.Status.NodeName)
	fmt.Fprintln(os.Stderr, "IP:", vm.Status.Interfaces[0].IP)

	fmt.Fprintln(os.Stderr, "Waiting for virtual machine to become reachable via ssh...")

	ssh, err := DialSSH(timeout, vm.Status.Interfaces[0].IP, rc.SSH, cmd.DialTimeout)
	if err != nil {
		return err
	}
	_ = ssh.Close()
	return nil
}
