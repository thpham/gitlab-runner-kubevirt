package main

import (
	"context"
	"crypto/sha1"
	"encoding/binary"
	"fmt"
	"hash"
	"io"
	"os"
	"strconv"
	"time"

	"github.com/alecthomas/kong"
)

type JobContext struct {
	ID              string
	BaseName        string
	Image           string
	ImagePullPolicy string
	ImagePullSecret string
	Namespace       string
	MachineType     string
	Architecture    string

	CPURequest              string
	CPULimit                string
	MemoryRequest           string
	MemoryLimit             string
	EphemeralStorageRequest string
	EphemeralStorageLimit   string
	Timezone                string

	ProjectID    string
	JobID        string
	JobName      string
	JobRef       string
	JobSha       string
	JobBeforeSha string
	JobURL       string

	// Garbage collection metadata
	CreatedAt string // RFC3339 timestamp
	TTL       string // Duration string (e.g., "1h", "24h")
}

var cli struct {
	RunnerID     string `name:"runner-id" env:"CUSTOM_ENV_CI_RUNNER_ID"`
	ProjectID    string `name:"project-id" env:"CUSTOM_ENV_CI_PROJECT_ID"`
	ConcurrentID string `name:"concurrent-id" env:"CUSTOM_ENV_CI_CONCURRENT_PROJECT_ID"`
	JobID        string `name:"job-id" env:"CUSTOM_ENV_CI_JOB_ID"`
	JobName      string `name:"job-name" env:"CUSTOM_ENV_CI_COMMIT_BEFORE_SHA"`
	JobRef       string `name:"job-ref" env:"CUSTOM_ENV_CI_COMMIT_REF_NAME"`
	JobSha       string `name:"job-sha" env:"CUSTOM_ENV_CI_COMMIT_SHA"`
	JobBeforeSha string `name:"job-before-sha" env:"CUSTOM_ENV_CI_COMMIT_BEFORE_SHA"`
	JobURL       string `name:"job-url" env:"CUSTOM_ENV_CI_JOB_URL"`
	JobImage     string `name:"image" env:"CUSTOM_ENV_CI_JOB_IMAGE"`
	MachineType  string `name:"machine-type" env:"CUSTOM_ENV_VM_MACHINE_TYPE"`
	Architecture string `name:"architecture" env:"CUSTOM_ENV_VM_ARCHITECTURE"`
	Namespace    string `name:"namespace" env:"KUBEVIRT_NAMESPACE" default:"gitlab-runner"`
	VMTTL        string `name:"vm-ttl" env:"CUSTOM_ENV_VM_TTL" help:"VM time-to-live for garbage collection (e.g., '3h', '24h')"`

	// Resource configuration (per-job override via GitLab CI variables)
	CPURequest              string `name:"cpu-request" env:"CUSTOM_ENV_VM_CPU_REQUEST" help:"CPU request (e.g., '1', '2', '500m')"`
	CPULimit                string `name:"cpu-limit" env:"CUSTOM_ENV_VM_CPU_LIMIT" help:"CPU limit (e.g., '2', '4')"`
	MemoryRequest           string `name:"memory-request" env:"CUSTOM_ENV_VM_MEMORY_REQUEST" help:"Memory request (e.g., '1Gi', '2Gi', '512Mi')"`
	MemoryLimit             string `name:"memory-limit" env:"CUSTOM_ENV_VM_MEMORY_LIMIT" help:"Memory limit (e.g., '2Gi', '4Gi')"`
	EphemeralStorageRequest string `name:"ephemeral-storage-request" env:"CUSTOM_ENV_VM_STORAGE_REQUEST" help:"Ephemeral storage request (e.g., '10Gi', '20Gi')"`
	EphemeralStorageLimit   string `name:"ephemeral-storage-limit" env:"CUSTOM_ENV_VM_STORAGE_LIMIT" help:"Ephemeral storage limit (e.g., '20Gi', '50Gi')"`

	Debug bool

	Config  ConfigCmd  `cmd`
	Prepare PrepareCmd `cmd`
	Run     RunCmd     `cmd`
	Cleanup CleanupCmd `cmd`
	GC      GCCmd      `cmd:"gc" help:"Garbage collect expired VMs"`
}

var Debug io.Writer = io.Discard

func main() {

	ctx := kong.Parse(&cli)

	if cli.Debug {
		Debug = os.Stderr
	}

	jctx := contextFromEnv()

	ctx.Bind(jctx)
	ctx.BindToProvider(KubeClient)
	ctx.BindToProvider(func() (context.Context, error) {
		return context.Background(), nil
	})

	if err := ctx.Run(jctx); err != nil {
		fmt.Fprintf(os.Stderr, "%s: %v\n", os.Args[0], err)
		systemFailureExit()
	}
}

func contextFromEnv() *JobContext {
	var jctx JobContext

	// Generate timestamp for uniqueness guarantee
	now := time.Now()
	jctx.CreatedAt = now.Format(time.RFC3339)

	jctx.BaseName = fmt.Sprintf(`runner-%s-project-%s-concurrent-%s`, cli.RunnerID, cli.ProjectID, cli.ConcurrentID)

	// Include timestamp in ID to guarantee uniqueness (improvement #4)
	jctx.ID = digest(sha1.New, cli.RunnerID, cli.ProjectID, cli.ConcurrentID, cli.JobID, now.UnixNano())

	jctx.Image = cli.JobImage
	jctx.Namespace = cli.Namespace
	jctx.MachineType = cli.MachineType
	jctx.Architecture = cli.Architecture

	// Resource configuration (per-job override via GitLab CI variables)
	jctx.CPURequest = cli.CPURequest
	jctx.CPULimit = cli.CPULimit
	jctx.MemoryRequest = cli.MemoryRequest
	jctx.MemoryLimit = cli.MemoryLimit
	jctx.EphemeralStorageRequest = cli.EphemeralStorageRequest
	jctx.EphemeralStorageLimit = cli.EphemeralStorageLimit

	jctx.ProjectID = cli.ProjectID
	jctx.JobID = cli.JobID
	jctx.JobName = cli.JobName
	jctx.JobRef = cli.JobRef
	jctx.JobSha = cli.JobSha
	jctx.JobBeforeSha = cli.JobBeforeSha
	jctx.JobURL = cli.JobURL

	// TTL for garbage collection (improvement #2)
	jctx.TTL = cli.VMTTL
	if jctx.TTL == "" {
		jctx.TTL = "3h" // Default 3 hours
	}

	return &jctx
}

func digest(hashfunc func() hash.Hash, v ...interface{}) string {
	digest := hashfunc()
	binary.Write(digest, binary.BigEndian, len(v))
	for _, e := range v {
		switch e := e.(type) {
		case string:
			binary.Write(digest, binary.BigEndian, len(e))
			io.WriteString(digest, e)
		case []byte:
			binary.Write(digest, binary.BigEndian, len(e))
			digest.Write(e)
		default:
			binary.Write(digest, binary.BigEndian, e)
		}
	}
	return fmt.Sprintf("%x", digest.Sum(nil))
}

func envExit(status int, env string) {
	if code := os.Getenv(env); code != "" {
		val, err := strconv.Atoi(code)
		if err != nil {
			fmt.Fprintf(os.Stderr, "%s=%s is not a valid exit code: %v\n", env, code, err)
		} else {
			status = val
		}
	}
	os.Exit(status)
}

func systemFailureExit() {
	envExit(2, "SYSTEM_FAILURE_EXIT_CODE")
}

func buildFailureExit() {
	envExit(1, "BUILD_FAILURE_EXIT_CODE")
}
