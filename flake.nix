{
  description = "GitLab Runner KubeVirt - Executor for running jobs in VMs on Kubernetes";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ self.overlays.default ];
        };

        # Version from git or default
        version =
          if (builtins.pathExists ./.git) then
            pkgs.lib.removeSuffix "\n" (
              builtins.readFile (
                pkgs.runCommand "get-version" { } ''
                  cd ${./.}
                  ${pkgs.git}/bin/git describe --tags --always --dirty 2>/dev/null > $out || echo "v0.0.0-dev" > $out
                ''
              )
            )
          else
            "v0.0.0-dev";

      in
      {
        # Package outputs
        packages = {
          default = self.packages.${system}.gitlab-runner-kubevirt;

          gitlab-runner-kubevirt = pkgs.buildGoModule {
            pname = "gitlab-runner-kubevirt";
            inherit version;

            src = pkgs.lib.cleanSource ./.;

            # Use proxyVendor for better compatibility with updated dependencies
            proxyVendor = true;
            vendorHash = "sha256-CEPWo9Ai9jWPASdh4MZpJkxA2/q+KBp6Xsloy9M/32A=";

            ldflags = [
              "-s"
              "-w"
              "-X main.version=${version}"
              "-extldflags=-static"
            ];

            # Build flags
            tags = [ "netgo" ];

            # Set CGO_ENABLED via env
            env = {
              CGO_ENABLED = "0";
            };

            # Tests may require Kubernetes cluster
            doCheck = false;

            meta = with pkgs.lib; {
              description = "GitLab Runner executor for running jobs in VMs on Kubernetes with KubeVirt";
              homepage = "https://github.com/thpham/gitlab-runner-kubevirt";
              license = licenses.mit;
              platforms = platforms.linux ++ platforms.darwin;
              mainProgram = "gitlab-runner-kubevirt";
            };
          };

          # Container image
          container = pkgs.dockerTools.buildLayeredImage {
            name = "ghcr.io/thpham/gitlab-runner-kubevirt";
            tag = version;

            contents = [
              pkgs.gitlab-runner
              self.packages.${system}.gitlab-runner-kubevirt
              pkgs.cacert
              pkgs.bash
              pkgs.coreutils
            ];

            config = {
              Cmd = [ "/bin/gitlab-runner-kubevirt" ];
              Env = [
                "PATH=/bin"
                "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
              ];
              Labels = {
                "org.opencontainers.image.source" = "https://github.com/thpham/gitlab-runner-kubevirt";
                "org.opencontainers.image.description" = "GitLab Runner executor for KubeVirt VMs";
                "org.opencontainers.image.version" = version;
              };
            };

            # Set the architecture for the image
            architecture = if system == "x86_64-linux" then "amd64"
                          else if system == "aarch64-linux" then "arm64"
                          else pkgs.stdenv.hostPlatform.linuxArch;

            extraCommands = ''
              mkdir -p bin
            '';
          };

          # Multi-architecture container images
          container-manifest = pkgs.writeShellScriptBin "build-multiarch" ''
            set -euo pipefail

            VERSION="${version}"
            IMAGE_NAME="''${IMAGE_NAME:-gitlab-runner-kubevirt}"

            echo "Building multi-architecture container images..."

            for arch in amd64 arm64; do
              echo "Building for $arch..."
              nix build ".#packages.$arch-linux.container"
              ${pkgs.skopeo}/bin/skopeo copy \
                docker-archive:result \
                "docker://$IMAGE_NAME:$VERSION-$arch"
            done

            echo "Creating manifest..."
            ${pkgs.buildah}/bin/buildah manifest create "$IMAGE_NAME:$VERSION"
            ${pkgs.buildah}/bin/buildah manifest add "$IMAGE_NAME:$VERSION" "docker://$IMAGE_NAME:$VERSION-amd64"
            ${pkgs.buildah}/bin/buildah manifest add "$IMAGE_NAME:$VERSION" "docker://$IMAGE_NAME:$VERSION-arm64"
            ${pkgs.buildah}/bin/buildah manifest push --all "$IMAGE_NAME:$VERSION" "docker://$IMAGE_NAME:$VERSION"

            echo "Multi-arch image published: $IMAGE_NAME:$VERSION"
          '';
        }
        # NixOS base images for KubeVirt VMs (Linux only)
        // pkgs.lib.optionalAttrs pkgs.stdenv.isLinux (
          let
            # Import the nixos image builder
            nixosImages = import ./microvm/nixos/default.nix {
              inherit pkgs system;
              nixpkgsPath = nixpkgs;
            };
          in
          {
            # Base NixOS image with comprehensive tooling
            nixos-base = nixosImages.base;

            # NixOS image with GitLab Runner integration
            nixos-runner = nixosImages.runner;
          }
        );

        # Development shell
        devShells.default = pkgs.mkShell {
          name = "gitlab-runner-kubevirt-dev";

          packages =
            with pkgs;
            [
              # Go toolchain
              go_1_24
              gopls
              gotools
              go-tools
              golangci-lint
              delve

              # Kubernetes tools
              kubectl
              kubernetes-helm
              k9s
              kind

              # Container tools
              docker
              podman
              skopeo
            ]
            # buildah is Linux-only, skip on macOS
            ++ pkgs.lib.optionals pkgs.stdenv.isLinux [
              buildah
            ]
            ++ [
              # Development tools
              git
              gnumake
              jq
              yq-go

              # Testing tools
              hey
              wrk

              # SSH tools for debugging
              openssh

              # Nix tools
              nixpkgs-fmt
              nil
            ];

          shellHook = ''
            # Set up Go environment first (before displaying versions)
            export GOPATH="''${GOPATH:-$HOME/go}"
            export PATH="$GOPATH/bin:$PATH"

            # Development environment variables
            export CUSTOM_ENV_CI_RUNNER_ID="dev-runner"
            export CUSTOM_ENV_CI_PROJECT_ID="1"
            export CUSTOM_ENV_CI_CONCURRENT_PROJECT_ID="1"
            export KUBEVIRT_NAMESPACE="gitlab-runner"

            # Enable Go modules
            export GO111MODULE=on

            echo "🚀 GitLab Runner KubeVirt Development Environment"
            echo "=================================================="
            echo ""
            echo "Go version: $(go version)"
            echo "kubectl version: $(kubectl version --client --short 2>/dev/null || echo 'not connected')"

            echo ""
            echo "Available commands:"
            echo "  go build          - Build the binary"
            echo "  go test ./...     - Run tests"
            echo "  go run .          - Run the application"
            echo "  nix build         - Build with Nix"
            echo "  nix build .#container - Build container image"
            echo ""
            echo "Kubernetes tools: kubectl, helm, k9s, kind, minikube"
            ${
              if pkgs.stdenv.isLinux then
                ''echo "Container tools: docker, podman, skopeo, buildah"''
              else
                ''echo "Container tools: docker, podman, skopeo (buildah: Linux-only)"''
            }
            echo ""

            # Helpful aliases
            alias build='go build -o gitlab-runner-kubevirt'
            alias test='go test -v ./...'
            alias lint='golangci-lint run'
            alias fmt='go fmt ./...'
          '';
        };

        # Apps - convenient runners
        apps = {
          default = {
            type = "app";
            program = "${self.packages.${system}.gitlab-runner-kubevirt}/bin/gitlab-runner-kubevirt";
          };
        };

        # Formatter
        formatter = pkgs.nixpkgs-fmt;
      }
    )
    // {
      # Overlay for custom packages
      overlays.default = final: prev: {
        gitlab-runner-kubevirt = self.packages.${final.system}.gitlab-runner-kubevirt;
      };
    };
}
