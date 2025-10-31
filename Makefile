.PHONY: help build test clean install nix-build nix-shell fmt lint dev

# Version from git
VERSION := $(shell git describe --tags --always --dirty 2>/dev/null || echo "v0.0.0-dev")
COMMIT := $(shell git rev-parse --short HEAD 2>/dev/null || echo "unknown")
DATE := $(shell date -u +"%Y-%m-%dT%H:%M:%SZ")

# Build variables
BINARY_NAME := gitlab-runner-kubevirt
LDFLAGS := -s -w -X main.version=$(VERSION)
GOFLAGS := -trimpath

# Container registry
REGISTRY ?= ghcr.io
IMAGE_NAME ?= $(REGISTRY)/$(shell git config --get remote.origin.url | sed 's/.*://;s/\.git//' | tr '[:upper:]' '[:lower:]')
IMAGE_TAG ?= $(VERSION)

help: ## Show this help
	@echo "GitLab Runner KubeVirt - Build Commands"
	@echo "========================================"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "Version: $(VERSION)"
	@echo "Commit:  $(COMMIT)"

build: ## Build the binary with Go
	@echo "Building $(BINARY_NAME) $(VERSION)..."
	go build $(GOFLAGS) -ldflags="$(LDFLAGS)" -o $(BINARY_NAME) .
	@echo "✓ Binary built: ./$(BINARY_NAME)"

build-static: ## Build static binary (Linux only)
	@echo "Building static $(BINARY_NAME) $(VERSION)..."
	CGO_ENABLED=0 GOOS=linux go build $(GOFLAGS) -ldflags="$(LDFLAGS) -extldflags=-static" -o $(BINARY_NAME) .
	@echo "✓ Static binary built: ./$(BINARY_NAME)"

test: ## Run tests
	@echo "Running tests..."
	go test -v -race -coverprofile=coverage.out ./...
	@echo "✓ Tests passed"

coverage: test ## Generate coverage report
	go tool cover -html=coverage.out -o coverage.html
	@echo "✓ Coverage report: coverage.html"

clean: ## Clean build artifacts
	@echo "Cleaning..."
	rm -f $(BINARY_NAME) coverage.out coverage.html
	rm -rf dist/
	@echo "✓ Cleaned"

install: build ## Install binary to $GOPATH/bin
	@echo "Installing $(BINARY_NAME) to $(GOPATH)/bin..."
	install -d $(GOPATH)/bin
	install -m 755 $(BINARY_NAME) $(GOPATH)/bin/
	@echo "✓ Installed to $(GOPATH)/bin/$(BINARY_NAME)"

fmt: ## Format Go code
	@echo "Formatting code..."
	go fmt ./...
	@echo "✓ Code formatted"

lint: ## Run linters
	@echo "Running linters..."
	@command -v golangci-lint >/dev/null 2>&1 || { echo "golangci-lint not found. Install it or use 'nix develop'"; exit 1; }
	golangci-lint run
	@echo "✓ Linting passed"

vet: ## Run go vet
	@echo "Running go vet..."
	go vet ./...
	@echo "✓ Vet passed"

mod-tidy: ## Tidy and verify go.mod
	@echo "Tidying modules..."
	go mod tidy
	go mod verify
	@echo "✓ Modules tidied"

# Nix commands
nix-build: ## Build with Nix
	@echo "Building with Nix..."
	nix build .#gitlab-runner-kubevirt
	@echo "✓ Nix build complete: ./result/bin/$(BINARY_NAME)"

nix-container: ## Build container image with Nix
	@echo "Building container with Nix..."
	nix build .#container
	@echo "✓ Container image built: ./result"
	@echo "Load with: docker load < result"

nix-shell: ## Enter Nix development shell
	nix develop

nix-update-vendor: ## Update Nix vendorHash
	@echo "Building to get correct vendorHash..."
	@nix-build -A packages.x86_64-linux.gitlab-runner-kubevirt 2>&1 | grep "got:" | tail -1 || true
	@echo ""
	@echo "Update vendorHash in flake.nix with the value above"

# Development
dev: ## Start development environment
	@echo "Starting development environment..."
	@command -v direnv >/dev/null 2>&1 && direnv allow || echo "direnv not found, using nix develop"
	@command -v direnv >/dev/null 2>&1 || nix develop

run-config: build ## Run config command
	./$(BINARY_NAME) config

run-help: build ## Show help
	./$(BINARY_NAME) --help

# Release
release: clean test build-static ## Prepare release build
	@echo "Creating release $(VERSION)..."
	mkdir -p dist
	cp $(BINARY_NAME) dist/$(BINARY_NAME)-$(VERSION)-linux-amd64
	cd dist && sha256sum $(BINARY_NAME)-$(VERSION)-linux-amd64 > $(BINARY_NAME)-$(VERSION)-checksums.txt
	@echo "✓ Release artifacts in dist/"

# Multi-architecture builds (requires Nix + Linux or remote builders)
release-multiarch: ## Build for multiple architectures with Nix
	@echo "Building for multiple architectures..."
	@if [ "$$(uname)" = "Darwin" ]; then \
		echo "⚠️  Warning: Building Linux binaries on macOS requires remote builders"; \
		echo "   Configure with: https://nixos.org/manual/nix/stable/advanced-topics/distributed-builds.html"; \
		echo "   Or use GitHub Actions for multi-arch builds"; \
	fi
	@for arch in x86_64-linux aarch64-linux; do \
		echo "Building for $$arch..."; \
		nix build .#packages.$$arch.gitlab-runner-kubevirt --out-link result-$$arch || true; \
	done
	@echo "✓ Multi-arch builds complete (check for errors above)"
