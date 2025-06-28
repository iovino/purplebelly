#!/bin/bash
set -e

echo "Updating system..."
sudo apt update && sudo apt upgrade -y

echo "Installing dependencies..."
sudo apt install -y curl wget git gnupg lsb-release

# K3s
if ! command -v k3s >/dev/null 2>&1; then
  echo "Installing k3s..."
  curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--no-deploy traefik" sh -s -
else
  echo "k3s is already installed, skipping..."
fi

# Setup nginx ingress controller
kubectl create namespace ingress-nginx
kubectl create ingressclass ingress-nginx --controller=k8s.io/ingress-nginx
cat >/var/lib/rancher/k3s/server/manifests/ingress-nginx.yaml <<EOF
apiVersion: helm.cattle.io/v1
kind: HelmChart
metadata:
  name: ingress-nginx
  namespace: kube-system
spec:
  chart: ingress-nginx
  repo: https://kubernetes.github.io/ingress-nginx
  targetNamespace: ingress-nginx
  version: v4.11.1
  valuesContent: |-
    createNamespace: true
    fullnameOverride: ingress-nginx
    controller:
      kind: DaemonSet
      hostNetwork: true
      hostPort:
        enabled: true
        ports:
          http: 80
          https: 443
      service:
        enabled: false
      publishService:
        enabled: false
      metrics:
        enabled: true
        serviceMonitor:
          enabled: false
      config:
        use-forwarded-headers: "true"
      extraArgs:
        tcp-services-configmap: "ingress-nginx/ingress-nginx-tcp"
        udp-services-configmap: "ingress-nginx/ingress-nginx-udp"
        report-node-internal-ip-address: "true"
EOF

# create mounts
mkdir -p /mnt/disks/vol1
sudo mount -t tmpfs vol1 /mnt/disks/vol1

mkdir -p /mnt/disks/vol2
sudo mount -t tmpfs vol2 /mnt/disks/vol2

# Kubeconfig
if [ ! -f "$HOME/.kube/config" ]; then
  echo "Setting up kubeconfig for user..."
  mkdir -p $HOME/.kube
  sudo cp /etc/rancher/k3s/k3s.yaml $HOME/.kube/config
  sudo chown $(id -u):$(id -g) $HOME/.kube/config
else
  echo "kubeconfig already set up, skipping..."
fi

# Export KUBECONFIG if not in .bashrc
if ! grep -q "export KUBECONFIG" ~/.bashrc; then
  echo 'export KUBECONFIG=$HOME/.kube/config' >> ~/.bashrc
  export KUBECONFIG=$HOME/.kube/config
else
  echo "KUBECONFIG already in .bashrc"
fi

# Helm
if ! command -v helm >/dev/null 2>&1; then
  echo "Installing Helm..."
  curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
else
  echo "Helm is already installed, skipping..."
fi

# Cluster Verification
echo "Verifying cluster..."
kubectl get nodes

# ArgoCD install
if ! kubectl get ns argocd >/dev/null 2>&1; then
  echo "Installing ArgoCD..."
  kubectl create namespace argocd
  kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

  echo "Patching argocd-server to add --insecure flag..."
  kubectl -n argocd patch deployment argocd-server --type='json' -p='[{"op": "add", "path": "/spec/template/spec/containers/0/args/-", "value": "--insecure"}]'

  echo "Waiting for ArgoCD to be ready..."
  kubectl -n argocd rollout status deploy/argocd-server

  echo "Getting ArgoCD admin password..."
  kubectl -n argocd get secret argocd-initial-admin-secret \
    -o jsonpath="{.data.password}" | base64 -d && echo
else
  echo "ArgoCD already installed, skipping..."
fi

echo "Setup complete."
