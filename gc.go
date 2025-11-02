package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"time"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	kubevirt "kubevirt.io/client-go/kubecli"
)

type GCCmd struct {
	DryRun bool          `name:"dry-run" help:"Show what would be deleted without actually deleting"`
	MaxAge time.Duration `name:"max-age" default:"3h" help:"Maximum age for VMs (overrides VM TTL labels)"`
}

func (cmd *GCCmd) Run(ctx context.Context, jctx *JobContext) error {
	// Use namespace from global context
	namespace := jctx.Namespace
	if namespace == "" {
		namespace = "gitlab-runner"
	}
	config, err := KubeConfig()
	if err != nil {
		return fmt.Errorf("failed to get kubeconfig: %w", err)
	}

	client, err := kubevirt.GetKubevirtClientFromRESTConfig(config)
	if err != nil {
		return fmt.Errorf("failed to get kubevirt client: %w", err)
	}

	// List all VMs with our label prefix
	listOptions := metav1.ListOptions{
		LabelSelector: labelPrefix + "/id",
	}

	vms, err := client.VirtualMachineInstance(namespace).List(ctx, listOptions)
	if err != nil {
		return fmt.Errorf("failed to list VMs: %w", err)
	}

	now := time.Now()
	deletedCount := 0
	skippedCount := 0

	fmt.Fprintf(os.Stderr, "Scanning %d VMs for garbage collection...\n", len(vms.Items))

	for _, vm := range vms.Items {
		createdAtStr := vm.Labels[labelPrefix+"/created-at"]
		ttlStr := vm.Labels[labelPrefix+"/ttl"]

		if createdAtStr == "" {
			fmt.Fprintf(os.Stderr, "⚠️  VM %s missing created-at label, skipping\n", vm.Name)
			skippedCount++
			continue
		}

		createdAt, err := time.Parse(time.RFC3339, createdAtStr)
		if err != nil {
			fmt.Fprintf(os.Stderr, "⚠️  VM %s has invalid created-at timestamp: %v, skipping\n", vm.Name, err)
			skippedCount++
			continue
		}

		// Determine TTL (use label if present, otherwise use max-age)
		var ttl time.Duration
		if ttlStr != "" {
			ttl, err = time.ParseDuration(ttlStr)
			if err != nil {
				fmt.Fprintf(os.Stderr, "⚠️  VM %s has invalid TTL: %v, using max-age\n", vm.Name, err)
				ttl = cmd.MaxAge
			}
		} else {
			ttl = cmd.MaxAge
		}

		age := now.Sub(createdAt)
		expired := age > ttl

		if expired {
			if cmd.DryRun {
				fmt.Fprintf(os.Stderr, "🗑️  [DRY-RUN] Would delete VM %s (age: %s, ttl: %s)\n", vm.Name, age.Round(time.Second), ttl)
			} else {
				fmt.Fprintf(os.Stderr, "🗑️  Deleting expired VM %s (age: %s, ttl: %s)\n", vm.Name, age.Round(time.Second), ttl)

				// Delete SSH credentials Secret before deleting the VM
				var rc RunConfig
				if err := json.Unmarshal([]byte(vm.Annotations[RunConfigKey]), &rc); err == nil {
					if rc.SSH.SecretRef != "" {
						if err := DeleteSSHSecret(ctx, config, namespace, rc.SSH.SecretRef); err != nil {
							fmt.Fprintf(os.Stderr, "⚠️  Warning: failed to delete SSH secret %s: %v\n", rc.SSH.SecretRef, err)
						} else {
							fmt.Fprintf(os.Stderr, "   Deleted SSH credentials secret: %s\n", rc.SSH.SecretRef)
						}
					}
				} else if vm.Annotations[RunConfigKey] != "" {
					fmt.Fprintf(os.Stderr, "⚠️  Warning: failed to unmarshal RunConfig for secret cleanup: %v\n", err)
				}

				err := client.VirtualMachineInstance(namespace).Delete(ctx, vm.Name, metav1.DeleteOptions{})
				if err != nil {
					fmt.Fprintf(os.Stderr, "❌ Failed to delete VM %s: %v\n", vm.Name, err)
					continue
				}
			}
			deletedCount++
		} else {
			remaining := ttl - age
			fmt.Fprintf(os.Stderr, "✅ VM %s still valid (age: %s, expires in: %s)\n", vm.Name, age.Round(time.Second), remaining.Round(time.Second))
		}
	}

	if cmd.DryRun {
		fmt.Fprintf(os.Stderr, "\n✓ Garbage collection dry-run complete: %d VMs would be deleted, %d skipped\n", deletedCount, skippedCount)
	} else {
		fmt.Fprintf(os.Stderr, "\n✓ Garbage collection complete: %d VMs deleted, %d skipped\n", deletedCount, skippedCount)
	}

	return nil
}
