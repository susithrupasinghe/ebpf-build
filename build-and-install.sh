#!/usr/bin/env bash

# Copyright Authors of Cilium
# SPDX-License-Identifier: Apache-2.0
#
# One-shot script to build Cilium, build images, and install into a Kubernetes cluster
#
# Usage:
#   ./build-and-install.sh [OPTIONS]
#
# Options:
#   --cluster-name NAME     Name of the kind cluster (default: kind)
#   --create-cluster        Create a new kind cluster if it doesn't exist
#   --skip-build            Skip building images (use existing ones)
#   --skip-install          Skip installation (only build and load images)
#   --image-tag TAG         Docker image tag (default: local)
#   --registry REGISTRY      Docker registry (default: localhost:5000)
#   --context KUBECTL_CTX    Kubernetes context to use (default: auto-detect)
#   --help                  Show this help message

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default values
CLUSTER_NAME="kind"
CREATE_CLUSTER=false
SKIP_BUILD=false
SKIP_INSTALL=false
IMAGE_TAG="local"
DOCKER_REGISTRY="localhost:5000"
KUBECTL_CONTEXT=""
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

show_help() {
    cat << EOF
One-shot script to build Cilium, build images, and install into a Kubernetes cluster

Usage: $0 [OPTIONS]

Options:
    --cluster-name NAME     Name of the kind cluster (default: kind)
    --create-cluster        Create a new kind cluster if it doesn't exist
    --skip-build            Skip building images (use existing ones)
    --skip-install          Skip installation (only build and load images)
    --image-tag TAG         Docker image tag (default: local)
    --registry REGISTRY     Docker registry (default: localhost:5000)
    --context KUBECTL_CTX   Kubernetes context to use (default: auto-detect)
    --help                  Show this help message

Examples:
    # Build and install into default 'kind' cluster
    $0

    # Build and install into custom cluster
    $0 --cluster-name my-cluster --create-cluster

    # Only build images, skip installation
    $0 --skip-install

    # Use existing images, skip build
    $0 --skip-build

EOF
}

check_prerequisites() {
    log_info "Checking prerequisites..."
    
    local missing_tools=()
    
    # Check Go
    if ! command -v go &> /dev/null; then
        missing_tools+=("go")
        log_warn "Go not found. You may need to set PATH to include Go binary."
    else
        local go_version=$(go version | awk '{print $3}')
        log_success "Go found: $go_version"
    fi
    
    # Check Docker
    if ! command -v docker &> /dev/null; then
        missing_tools+=("docker")
    else
        if ! docker ps &> /dev/null; then
            log_error "Docker daemon is not running"
            exit 1
        fi
        log_success "Docker found and running"
    fi
    
    # Check kind
    if ! command -v kind &> /dev/null; then
        missing_tools+=("kind")
    else
        log_success "kind found: $(kind --version)"
    fi
    
    # Check kubectl
    if ! command -v kubectl &> /dev/null; then
        missing_tools+=("kubectl")
    else
        log_success "kubectl found: $(kubectl version --client --short 2>/dev/null || echo 'installed')"
    fi
    
    # Check cilium-cli
    if ! command -v cilium &> /dev/null; then
        missing_tools+=("cilium-cli")
        log_warn "cilium-cli not found. Installation will fail if not available."
    else
        log_success "cilium-cli found: $(cilium version --client 2>/dev/null || echo 'installed')"
    fi
    
    if [ ${#missing_tools[@]} -gt 0 ]; then
        log_warn "Missing tools: ${missing_tools[*]}"
        log_warn "Please install missing tools before proceeding"
    fi
}

setup_local_registry() {
    log_info "Setting up local Docker registry..."
    
    if docker ps -a --format '{{.Names}}' | grep -q "^kind-registry$"; then
        if docker ps --format '{{.Names}}' | grep -q "^kind-registry$"; then
            log_success "Local registry already running"
            return
        else
            log_info "Starting existing registry container..."
            docker start kind-registry
            sleep 2
        fi
    else
        log_info "Creating local registry container..."
        docker run -d --name kind-registry -p 5000:5000 --restart=always registry:2 || {
            log_error "Failed to create registry. Port 5000 may be in use."
            exit 1
        }
        sleep 2
    fi
    
    # Verify registry is accessible
    if curl -s http://localhost:5000/v2/_catalog &> /dev/null; then
        log_success "Local registry is accessible"
    else
        log_warn "Registry may not be fully ready, but continuing..."
    fi
}

check_or_create_cluster() {
    log_info "Checking for kind cluster: $CLUSTER_NAME"
    
    if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
        log_success "Cluster '$CLUSTER_NAME' already exists"
        kubectl cluster-info --context "kind-${CLUSTER_NAME}" &> /dev/null || {
            log_error "Cluster exists but kubectl context is not accessible"
            exit 1
        }
    else
        if [ "$CREATE_CLUSTER" = true ]; then
            log_info "Creating new kind cluster: $CLUSTER_NAME"
            cd "$SCRIPT_DIR"
            make kind CLUSTER_NAME="$CLUSTER_NAME" || {
                log_error "Failed to create cluster"
                exit 1
            }
            log_success "Cluster '$CLUSTER_NAME' created"
        else
            log_error "Cluster '$CLUSTER_NAME' does not exist. Use --create-cluster to create it."
            exit 1
        fi
    fi
    
    # Set kubectl context
    if [ -z "$KUBECTL_CONTEXT" ]; then
        KUBECTL_CONTEXT="kind-${CLUSTER_NAME}"
    fi
    
    log_info "Using kubectl context: $KUBECTL_CONTEXT"
    kubectl config use-context "$KUBECTL_CONTEXT" || {
        log_error "Failed to set kubectl context"
        exit 1
    }
}

build_images() {
    if [ "$SKIP_BUILD" = true ]; then
        log_info "Skipping image build (--skip-build specified)"
        return
    fi
    
    log_info "Building Cilium images..."
    log_info "Image tag: $IMAGE_TAG"
    log_info "Registry: $DOCKER_REGISTRY"
    
    cd "$SCRIPT_DIR"
    
    # Set environment variables
    export LOCAL_IMAGE_TAG="$IMAGE_TAG"
    export DOCKER_REGISTRY="$DOCKER_REGISTRY"
    export DOCKER_DEV_ACCOUNT="cilium"
    
    # Ensure Go is in PATH if installed locally
    if [ -d "$HOME/go-install/go/bin" ]; then
        export PATH="$HOME/go-install/go/bin:$PATH"
    fi
    
    log_info "Building agent image..."
    make kind-build-image-agent DOCKER_IMAGE_TAG="$IMAGE_TAG" || {
        log_error "Failed to build agent image"
        exit 1
    }
    
    log_info "Building operator image..."
    make kind-build-image-operator DOCKER_IMAGE_TAG="$IMAGE_TAG" || {
        log_error "Failed to build operator image"
        exit 1
    }
    
    log_success "Images built successfully"
}

load_images() {
    log_info "Loading images into cluster: $CLUSTER_NAME"
    
    local agent_image="${DOCKER_REGISTRY}/cilium/cilium-dev:${IMAGE_TAG}"
    local operator_image="${DOCKER_REGISTRY}/cilium/operator-generic:${IMAGE_TAG}"
    
    log_info "Loading agent image: $agent_image"
    kind load docker-image "$agent_image" --name "$CLUSTER_NAME" || {
        log_error "Failed to load agent image"
        exit 1
    }
    
    log_info "Loading operator image: $operator_image"
    kind load docker-image "$operator_image" --name "$CLUSTER_NAME" || {
        log_error "Failed to load operator image"
        exit 1
    }
    
    log_success "Images loaded into cluster"
}

install_cilium() {
    if [ "$SKIP_INSTALL" = true ]; then
        log_info "Skipping Cilium installation (--skip-install specified)"
        return
    fi
    
    log_info "Installing Cilium into cluster..."
    
    cd "$SCRIPT_DIR"
    
    # Set environment variables
    export LOCAL_IMAGE_TAG="$IMAGE_TAG"
    export DOCKER_REGISTRY="$DOCKER_REGISTRY"
    export LOCAL_AGENT_IMAGE="${DOCKER_REGISTRY}/cilium/cilium-dev:${IMAGE_TAG}"
    export LOCAL_OPERATOR_IMAGE="${DOCKER_REGISTRY}/cilium/operator-generic:${IMAGE_TAG}"
    
    # Ensure kubectl context is set
    kubectl config use-context "$KUBECTL_CONTEXT"
    
    # Uninstall existing Cilium if present (ignore errors)
    log_info "Checking for existing Cilium installation..."
    cilium uninstall --context "$KUBECTL_CONTEXT" &> /dev/null || true
    
    # Wait a moment for cleanup
    sleep 3
    
    # Install Cilium
    log_info "Installing Cilium with local images..."
    make kind-install-cilium KIND_CLUSTER_NAME="$CLUSTER_NAME" || {
        log_error "Failed to install Cilium"
        exit 1
    }
    
    log_success "Cilium installation initiated"
}

fix_operator_node_selector() {
    log_info "Checking and fixing operator node selector if needed..."
    
    # Get the actual worker node name
    local worker_node=$(kubectl get nodes --context "$KUBECTL_CONTEXT" -o jsonpath='{.items[?(@.metadata.labels.node-role\.kubernetes\.io/control-plane != "true")].metadata.name}' | awk '{print $1}')
    
    if [ -z "$worker_node" ]; then
        log_warn "Could not detect worker node name, skipping node selector fix"
        return
    fi
    
    # Check current node selector
    local current_selector=$(kubectl get deployment cilium-operator -n kube-system --context "$KUBECTL_CONTEXT" -o jsonpath='{.spec.template.spec.nodeSelector.kubernetes\.io/hostname}' 2>/dev/null || echo "")
    
    if [ "$current_selector" != "$worker_node" ] && [ -n "$current_selector" ]; then
        log_info "Fixing operator node selector: $current_selector -> $worker_node"
        kubectl patch deployment cilium-operator -n kube-system --context "$KUBECTL_CONTEXT" \
            --type='json' \
            -p="[{\"op\": \"replace\", \"path\": \"/spec/template/spec/nodeSelector/kubernetes.io~1hostname\", \"value\": \"$worker_node\"}]" 2>/dev/null || {
            log_warn "Failed to patch node selector, but continuing..."
        }
        
        # Also ensure toleration for not-ready nodes exists
        kubectl patch deployment cilium-operator -n kube-system --context "$KUBECTL_CONTEXT" \
            --type='json' \
            -p='[{"op": "add", "path": "/spec/template/spec/tolerations/-", "value": {"key": "node.kubernetes.io/not-ready", "operator": "Exists", "effect": "NoSchedule"}}]' 2>/dev/null || true
        
        log_success "Node selector fixed"
    else
        log_info "Node selector is correct or will be set by Helm"
    fi
}

verify_installation() {
    log_info "Verifying Cilium installation..."
    
    # Fix node selector if needed (for custom cluster names)
    fix_operator_node_selector
    
    # Wait for pods to be ready
    log_info "Waiting for Cilium pods to be ready..."
    kubectl wait --for=condition=ready pod -l k8s-app=cilium -n kube-system --context "$KUBECTL_CONTEXT" --timeout=300s || {
        log_warn "Some Cilium pods may not be ready yet"
    }
    
    # Wait a bit for operator to start if it was just patched
    sleep 5
    
    # Check status
    log_info "Checking Cilium status..."
    if command -v cilium &> /dev/null; then
        cilium status --context "$KUBECTL_CONTEXT" --wait --wait-duration 60s || {
            log_warn "Cilium status check had warnings, but continuing..."
        }
    else
        log_warn "cilium-cli not available, skipping status check"
    fi
    
    # Show pod status
    log_info "Cilium pods status:"
    kubectl get pods -n kube-system --context "$KUBECTL_CONTEXT" | grep -E "(cilium|NAME)" || true
    
    log_success "Installation verification complete"
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --cluster-name)
            CLUSTER_NAME="$2"
            shift 2
            ;;
        --create-cluster)
            CREATE_CLUSTER=true
            shift
            ;;
        --skip-build)
            SKIP_BUILD=true
            shift
            ;;
        --skip-install)
            SKIP_INSTALL=true
            shift
            ;;
        --image-tag)
            IMAGE_TAG="$2"
            shift 2
            ;;
        --registry)
            DOCKER_REGISTRY="$2"
            shift 2
            ;;
        --context)
            KUBECTL_CONTEXT="$2"
            shift 2
            ;;
        --help)
            show_help
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

# Main execution
main() {
    log_info "=========================================="
    log_info "Cilium Build and Install Script"
    log_info "=========================================="
    log_info "Cluster: $CLUSTER_NAME"
    log_info "Image Tag: $IMAGE_TAG"
    log_info "Registry: $DOCKER_REGISTRY"
    log_info "=========================================="
    echo
    
    check_prerequisites
    echo
    
    setup_local_registry
    echo
    
    check_or_create_cluster
    echo
    
    build_images
    echo
    
    load_images
    echo
    
    install_cilium
    echo
    
    verify_installation
    echo
    
    log_success "=========================================="
    log_success "Cilium build and installation complete!"
    log_success "=========================================="
    log_info "Cluster: $CLUSTER_NAME"
    log_info "Context: $KUBECTL_CONTEXT"
    log_info ""
    log_info "Next steps:"
    log_info "  - Check status: cilium status --context $KUBECTL_CONTEXT"
    log_info "  - Run tests: cilium connectivity test --context $KUBECTL_CONTEXT"
    log_info "  - View pods: kubectl get pods -n kube-system | grep cilium"
}

# Run main function
main

