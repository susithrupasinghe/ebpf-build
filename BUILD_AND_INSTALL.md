# Building and Installing Cilium into a Kubernetes Cluster

This guide walks you through building Cilium from source and installing it into a Kubernetes cluster (using kind as an example).

## Prerequisites

### Required Tools

1. **Go** (version 1.21 or later)
   ```bash
   # Install Go (if not already installed)
   curl -L https://go.dev/dl/go1.21.5.linux-amd64.tar.gz -o /tmp/go.tar.gz
   mkdir -p ~/go-install
   tar -C ~/go-install -xzf /tmp/go.tar.gz
   export PATH=~/go-install/go/bin:$PATH
   ```

2. **Docker** - Required for building container images
   ```bash
   docker --version
   ```

3. **kind** - Kubernetes in Docker (for local testing)
   ```bash
   # Install kind if not present
   curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.20.0/kind-linux-amd64
   chmod +x ./kind
   sudo mv ./kind /usr/local/bin/kind
   ```

4. **kubectl** - Kubernetes command-line tool
   ```bash
   kubectl version --client
   ```

5. **cilium-cli** - Cilium command-line tool
   ```bash
   # Install cilium-cli if not present
   CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
   CLI_ARCH=amd64
   if [ "$(uname -m)" = "aarch64" ]; then CLI_ARCH=arm64; fi
   curl -L --fail --remote-name-all https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}
   sha256sum --check cilium-linux-${CLI_ARCH}.tar.gz.sha256sum
   sudo tar xzvfC cilium-linux-${CLI_ARCH}.tar.gz /usr/local/bin
   rm cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}
   ```

### System Requirements

- Linux-based system (Ubuntu/Debian recommended)
- At least 4GB RAM
- Docker daemon running
- Sufficient disk space for Docker images (~5GB)

## Quick Start: One-Shot Script

For the fastest way to build and install Cilium, use the provided automation script:

```bash
# Make script executable
chmod +x build-and-install.sh

# Build and install into default 'kind' cluster (creates cluster if needed)
./build-and-install.sh --create-cluster

# Or use an existing cluster
./build-and-install.sh --cluster-name my-cluster

# See all options
./build-and-install.sh --help
```

The script automates:
- ✅ Prerequisite checking
- ✅ Local registry setup
- ✅ Cluster creation (optional)
- ✅ Image building
- ✅ Image loading into cluster
- ✅ Cilium installation
- ✅ Installation verification

**Script Options:**
- `--cluster-name NAME` - Name of the kind cluster (default: `kind`)
- `--create-cluster` - Create a new kind cluster if it doesn't exist
- `--skip-build` - Skip building images (use existing ones)
- `--skip-install` - Skip installation (only build and load images)
- `--image-tag TAG` - Docker image tag (default: `local`)
- `--registry REGISTRY` - Docker registry (default: `localhost:5000`)
- `--context KUBECTL_CTX` - Kubernetes context to use (default: auto-detect)

**Examples:**
```bash
# Full automation: create cluster, build, and install
./build-and-install.sh --create-cluster

# Use existing cluster named 'my-cluster'
./build-and-install.sh --cluster-name my-cluster

# Only build images, don't install
./build-and-install.sh --skip-install

# Use existing images, skip build
./build-and-install.sh --skip-build --cluster-name my-cluster
```

For manual step-by-step instructions, continue reading below.

## Step 1: Clone Cilium Repository

```bash
git clone https://github.com/cilium/cilium.git
cd cilium
```

## Step 2: Set Up Local Docker Registry

Cilium's build process uses a local Docker registry at `localhost:5000`. Set it up:

```bash
# Start local registry (if not already running)
docker run -d --name kind-registry -p 5000:5000 --restart=always registry:2

# Verify registry is running
curl http://localhost:5000/v2/_catalog
```

If port 5000 is already in use, you can check what's using it:
```bash
docker ps | grep registry
```

## Step 3: Build Cilium Images

### Build Agent and Operator Images

The Makefile provides convenient targets for building and loading images into kind:

```bash
# Set environment variables
export PATH=~/go-install/go/bin:$PATH  # Adjust if Go is installed elsewhere
export LOCAL_IMAGE_TAG=local
export DOCKER_REGISTRY=localhost:5000

# Build and load images into kind (if cluster exists)
make kind-image
```

This command will:
- Build `cilium-dev:local` image
- Build `operator-generic:local` image
- Load both images into all kind nodes

### Alternative: Build Images Separately

If you want more control, you can build images separately:

```bash
# Build agent image
make kind-build-image-agent DOCKER_IMAGE_TAG=local

# Build operator image
make kind-build-image-operator DOCKER_IMAGE_TAG=local

# Load images into kind cluster
export LOCAL_AGENT_IMAGE=localhost:5000/cilium/cilium-dev:local
export LOCAL_OPERATOR_IMAGE=localhost:5000/cilium/operator-generic:local
kind load docker-image $LOCAL_AGENT_IMAGE --name <cluster-name>
kind load docker-image $LOCAL_OPERATOR_IMAGE --name <cluster-name>
```

## Step 4: Create a Kind Cluster

### Create a Basic Kind Cluster

```bash
# Create a new kind cluster
make kind

# Or create manually
kind create cluster --name cilium-test
```

The `make kind` command creates a cluster with:
- 1 control plane node
- 1 worker node
- CNI disabled (ready for Cilium)
- Proper network configuration

### Verify Cluster is Ready

```bash
kubectl cluster-info --context kind-kind
kubectl get nodes
```

## Step 5: Install Cilium

### Install Using Make Target (Recommended)

```bash
# Ensure kubectl context is set
kubectl config use-context kind-kind

# Install Cilium with local images
make kind-install-cilium
```

This command:
- Uses the local images loaded into kind
- Installs Cilium using Helm charts from `install/kubernetes/cilium`
- Applies kind-specific configuration from `contrib/testing/kind-common.yaml` and `contrib/testing/kind-values.yaml`

### Manual Installation

If you prefer manual control:

```bash
export LOCAL_AGENT_IMAGE=localhost:5000/cilium/cilium-dev:local
export LOCAL_OPERATOR_IMAGE=localhost:5000/cilium/operator-generic:local

cilium install \
  --context kind-kind \
  --chart-directory=./install/kubernetes/cilium \
  --set image.override=$LOCAL_AGENT_IMAGE \
  --set operator.image.override=$LOCAL_OPERATOR_IMAGE \
  --version=
```

## Step 6: Verify Installation

### Check Cilium Status

```bash
# Check overall status
cilium status --context kind-kind --wait

# Check pods
kubectl get pods -n kube-system | grep cilium

# Expected output should show:
# - cilium pods (DaemonSet) running on each node
# - cilium-operator pod running
# - cilium-envoy pods (if enabled)
```

### Run Connectivity Tests

```bash
# Run comprehensive connectivity tests
cilium connectivity test --context kind-kind

# This will:
# - Deploy test pods
# - Test various network policies
# - Verify connectivity between pods
# - Test DNS resolution
# - Verify service mesh functionality (if enabled)
```

### Quick Smoke Test

```bash
# Deploy a simple test application
kubectl create deployment nginx --image=nginx
kubectl expose deployment nginx --port=80

# Check if pods can communicate
kubectl run test-pod --image=busybox --rm -it --restart=Never -- wget -O- nginx
```

## Step 7: Clean Up (Optional)

### Remove Cilium Installation

```bash
cilium uninstall --context kind-kind
```

### Delete Kind Cluster

```bash
# Delete specific cluster
kind delete cluster --name kind

# Or use make target
make kind-down
```

### Remove Local Registry

```bash
docker stop kind-registry
docker rm kind-registry
```

## Troubleshooting

### Images Not Found

If pods fail with `ImagePullBackOff`:

1. Verify images are loaded into kind:
   ```bash
   docker exec kind-control-plane crictl images | grep cilium
   ```

2. Reload images if needed:
   ```bash
   make kind-image
   ```

### Build Failures

1. **Go version issues**: Ensure Go 1.21+ is installed
   ```bash
   go version
   ```

2. **Docker build issues**: Check Docker daemon is running
   ```bash
   docker ps
   ```

3. **Insufficient resources**: Ensure adequate memory/disk space
   ```bash
   free -h
   df -h
   ```

### Installation Failures

1. **Namespace termination**: Wait for namespaces to fully terminate
   ```bash
   kubectl get namespace cilium-secrets
   ```

2. **Resource conflicts**: Clean up existing resources
   ```bash
   kubectl delete crd --all --ignore-not-found=true
   kubectl delete clusterrole,clusterrolebinding -l app.kubernetes.io/name=cilium
   ```

3. **Operator pod pending (node selector mismatch)**: If using a custom cluster name (not `kind`), the operator may have a node selector mismatch. The script automatically fixes this, but if you encounter it manually:
   ```bash
   # Get your worker node name
   WORKER_NODE=$(kubectl get nodes -o jsonpath='{.items[?(@.metadata.labels.node-role\.kubernetes\.io/control-plane != "true")].metadata.name}' | awk '{print $1}')
   
   # Fix node selector
   kubectl patch deployment cilium-operator -n kube-system \
     --type='json' \
     -p="[{\"op\": \"replace\", \"path\": \"/spec/template/spec/nodeSelector/kubernetes.io~1hostname\", \"value\": \"$WORKER_NODE\"}]"
   
   # Add toleration for not-ready nodes
   kubectl patch deployment cilium-operator -n kube-system \
     --type='json' \
     -p='[{"op": "add", "path": "/spec/template/spec/tolerations/-", "value": {"key": "node.kubernetes.io/not-ready", "operator": "Exists", "effect": "NoSchedule"}}]'
   ```

4. **Check logs**:
   ```bash
   kubectl logs -n kube-system -l k8s-app=cilium
   kubectl logs -n kube-system -l name=cilium-operator
   ```

## Advanced Options

### Build Debug Images

For debugging purposes, build images with debug symbols:

```bash
make kind-image-agent-debug
make kind-image-operator-debug
```

### Fast Development Cycle

For faster iteration during development, use volume-mounted binaries:

```bash
# Build binaries
make build-cli build-cni build-agent build-operator

# Use fast installation method
make kind-install-cilium-fast
```

This mounts binaries directly into pods, avoiding image rebuilds.

### Custom Configuration

Create custom Helm values file:

```yaml
# custom-values.yaml
image:
  override: localhost:5000/cilium/cilium-dev:local
operator:
  image:
    override: localhost:5000/cilium/operator-generic:local
# Add your custom configurations here
```

Install with custom values:

```bash
cilium install \
  --context kind-kind \
  --chart-directory=./install/kubernetes/cilium \
  --helm-values=custom-values.yaml \
  --version=
```

## Production Considerations

⚠️ **Note**: The images built with `local` tag are development builds and **NOT suitable for production**.

For production:
1. Build release images: `make docker-cilium-image docker-operator-image`
2. Push to a container registry
3. Use proper version tags
4. Follow Cilium's production installation guide

## Additional Resources

- [Cilium Documentation](https://docs.cilium.io/)
- [Cilium GitHub Repository](https://github.com/cilium/cilium)
- [Kind Documentation](https://kind.sigs.k8s.io/)
- [Contributing Guide](https://docs.cilium.io/en/stable/contributing/development/)

## Summary

### Quick Start (Automated)

Use the one-shot script for the fastest setup:

```bash
./build-and-install.sh --create-cluster
```

### Manual Steps (Quick Reference)

For manual step-by-step execution:

```bash
# 1. Set up environment
export PATH=~/go-install/go/bin:$PATH
export LOCAL_IMAGE_TAG=local

# 2. Create cluster
make kind

# 3. Build and load images
make kind-image

# 4. Install Cilium
make kind-install-cilium

# 5. Verify
cilium status --context kind-kind --wait
cilium connectivity test --context kind-kind
```

---

**Last Updated**: Based on Cilium v1.19.0-dev

