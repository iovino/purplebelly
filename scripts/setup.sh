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

cat >/var/lib/rancher/k3s/server/manifests/ingress-nginx.yaml <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ingress-nginx
---
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
          dns-udp: 53
          dns-tcp: 53
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
    tcp:
      53: "pi-hole/pi-hole-tcp:53"
    udp:
      53: "pi-hole/pi-hole-udp:53"
EOF


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


#TRAEFIK_CONFIG_PATH="/var/lib/rancher/k3s/server/manifests/traefik-config.yaml"
#if [ ! -f "$TRAEFIK_CONFIG_PATH" ]; then
#  echo "Configuring Traefik to expose UDP port 53 for DNS..."
#  sudo tee "$TRAEFIK_CONFIG_PATH" > /dev/null <<'EOF'
#apiVersion: helm.cattle.io/v1
#kind: HelmChartConfig
#metadata:
#  name: traefik
#  namespace: kube-system
#spec:
#  valuesContent: |-
#    logs:
#      general:
#        level: DEBUG
#    ports:
#      dns-udp:
#        port: 53
#        protocol: UDP
#EOF
#  echo "Traefik config created. It may take a minute for k3s to apply the changes."
#else
#    echo "Traefik DNS config already exists, skipping..."
#fi

# ArgoCD install
if ! kubectl get ns argocd >/dev/null 2>&1; then
  echo "Installing ArgoCD..."
  kubectl create namespace argocd
  kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

  echo "Waiting for ArgoCD to be ready..."
  kubectl -n argocd rollout status deploy/argocd-server

  echo "Getting ArgoCD admin password..."
  kubectl -n argocd get secret argocd-initial-admin-secret \
    -o jsonpath="{.data.password}" | base64 -d && echo
else
  echo "ArgoCD already installed, skipping..."
fi

echo "Setup complete."
