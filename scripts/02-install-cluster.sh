#!/bin/bash
set -euo pipefail
trap 'echo "❌ Error en línea $LINENO durante instalación del clúster. Revisa los logs." && exit 1' ERR

# Cargar variables y funciones
[ -f .env ] && source .env || { echo "❌ Falta archivo .env"; exit 1; }
[ -f scripts/node-helpers.sh ] && source scripts/node-helpers.sh || { echo "❌ Falta archivo scripts/node-helpers.sh"; exit 1; }

LOG="logs/02-install-cluster-$(date +%F-%H%M).log"
mkdir -p logs && exec > >(tee -a "$LOG") 2>&1

echo "🚀 Iniciando instalación del clúster RKE2..."

# 1. VALIDACIONES INICIALES
# =========================
validate_nodes_config

# Validar configuración de subdominios
validate_subdomain_config

# Verificar si el clúster ya existe
if kubectl get nodes &>/dev/null; then
  echo "⚠️  El clúster RKE2 ya parece estar configurado."
  echo "📋 Nodos actuales:"
  kubectl get nodes -o wide
  echo ""
  echo "🔄 ¿Deseas continuar de todas formas? Esto puede causar problemas. (y/N)"
  read -r -n 1 response
  echo
  if [[ ! "$response" =~ ^[Yy]$ ]]; then
    echo "❌ Instalación cancelada por el usuario"
    exit 0
  fi
fi

# Mostrar configuración de nodos
show_nodes_summary

# 2. PREPARAR DIRECTORIOS RKE2
# ============================
echo "📁 Preparando directorios RKE2..."
mkdir -p /etc/rancher/rke2
mkdir -p /var/lib/rancher/rke2

# 3. INSTALAR RKE2 EN MASTER PRINCIPAL
# ====================================
PRIMARY_MASTER=$(get_primary_master)
CURRENT_HOSTNAME=$(hostname)

echo "🔧 Instalando RKE2 en el nodo master principal: $PRIMARY_MASTER"

if [ "$CURRENT_HOSTNAME" != "$PRIMARY_MASTER" ]; then
  echo "❌ Este script debe ejecutarse desde el nodo master principal ($PRIMARY_MASTER)"
  echo "📍 Hostname actual: $CURRENT_HOSTNAME"
  exit 1
fi

# Obtener IP del master principal
PRIMARY_MASTER_IP=$(get_node_ip "$PRIMARY_MASTER")

# Crear configuración para master principal
echo "📝 Creando configuración RKE2 para master principal..."
cat <<EOF > /etc/rancher/rke2/config.yaml
# Configuración Master Principal - $PRIMARY_MASTER
token: $CLUSTER_TOKEN
node-taint:
  - "CriticalAddonsOnly=true:NoExecute"
cni: calico
disable:
  - rke2-ingress-nginx
etcd-expose-metrics: true
etcd-snapshot-schedule-cron: "0 */12 * * *"
etcd-snapshot-retention: 5
node-label:
  - "rke2-master=true"
  - "node-role.kubernetes.io/master=true"
write-kubeconfig-mode: "0644"
# TLS SANs para todos los subdominios
tls-san:
$(get_complete_tls_sans "$PRIMARY_MASTER_IP")
EOF

# Instalar RKE2
echo "⬇️  Descargando e instalando RKE2 $RKE2_VERSION..."
curl -sfL https://get.rke2.io | INSTALL_RKE2_VERSION=$RKE2_VERSION sh -

# Iniciar servicio
echo "🔄 Iniciando servicio RKE2..."
systemctl enable rke2-server
systemctl start rke2-server

# Configurar kubectl
export PATH=$PATH:/var/lib/rancher/rke2/bin
export KUBECONFIG=/etc/rancher/rke2/rke2.yaml

# Crear enlaces simbólicos para kubectl
if [ ! -f /usr/local/bin/kubectl ]; then
  ln -s /var/lib/rancher/rke2/bin/kubectl /usr/local/bin/kubectl
fi

echo "⏳ Esperando a que el clúster inicialice..."
sleep 30

# Verificar que el master principal esté listo
echo "🔍 Verificando estado del master principal..."
for i in {1..12}; do
  if kubectl get nodes 2>/dev/null | grep -q "Ready"; then
    echo "✅ Master principal está listo"
    break
  fi
  echo "⏳ Esperando que el master esté listo... (intento $i/12)"
  sleep 10
done

kubectl get nodes -o wide

# 4. OBTENER TOKEN PARA NODOS SECUNDARIOS
# =======================================
echo "🔐 Obteniendo token del nodo master principal..."
sleep 5
MASTER_TOKEN=$(cat /var/lib/rancher/rke2/server/node-token)

if [ -z "$MASTER_TOKEN" ]; then
  echo "❌ No se pudo obtener el token del master"
  exit 1
fi

echo "✅ Token obtenido: ${MASTER_TOKEN:0:20}..."

# 5. INSTALAR RKE2 EN MASTERS SECUNDARIOS
# =======================================
echo "🔧 Instalando RKE2 en masters secundarios..."

SECONDARY_MASTERS=$(get_secondary_masters)
if [ -z "$SECONDARY_MASTERS" ]; then
  echo "ℹ️  No hay masters secundarios configurados"
else
  echo "$SECONDARY_MASTERS" | while read -r hostname; do
    if [ -n "$hostname" ]; then
      echo ""
      echo "🚀 Configurando $hostname como master secundario..."
      
      # Obtener IP del master secundario
      MASTER_IP=$(get_node_ip "$hostname")
      
      ssh -p "$SSH_PORT" "$SSH_USER@$hostname" bash -s <<EOF
set -euo pipefail
echo "📁 Preparando directorios en $hostname..."
mkdir -p /etc/rancher/rke2
mkdir -p /var/lib/rancher/rke2

echo "📝 Creando configuración RKE2..."
cat <<EOC > /etc/rancher/rke2/config.yaml
# Configuración Master Secundario - $hostname
token: $MASTER_TOKEN
server: https://$K8S_API_DOMAIN:443
node-taint:
  - "CriticalAddonsOnly=true:NoExecute"
cni: calico
disable:
  - rke2-ingress-nginx
etcd-expose-metrics: true
etcd-snapshot-schedule-cron: "0 */12 * * *"
etcd-snapshot-retention: 5
node-label:
  - "rke2-master=true"
  - "node-role.kubernetes.io/master=true"
write-kubeconfig-mode: "0644"
# TLS SANs para todos los subdominios
tls-san:
  - $K8S_API_DOMAIN
  - $K8S_REG_DOMAIN
  - $RANCHER_DOMAIN
  - $LB_IP
  - $MASTER_IP
  - localhost
  - 127.0.0.1
EOC

echo "⬇️  Instalando RKE2 $RKE2_VERSION en $hostname..."
curl -sfL https://get.rke2.io | INSTALL_RKE2_VERSION=$RKE2_VERSION sh -

echo "🔄 Iniciando servicio RKE2 en $hostname..."
systemctl enable rke2-server
systemctl start rke2-server

# Crear enlace simbólico para kubectl
if [ ! -f /usr/local/bin/kubectl ]; then
  ln -s /var/lib/rancher/rke2/bin/kubectl /usr/local/bin/kubectl
fi

echo "✅ RKE2 instalado en $hostname"
EOF

      echo "✅ Master secundario $hostname configurado"
    fi
  done
fi

# 6. INSTALAR RKE2 EN NODOS WORKER
# ================================
echo ""
echo "⚙️ Instalando RKE2 como agente en nodos worker..."

WORKER_NODES=$(get_nodes_by_type "worker")
if [ -z "$WORKER_NODES" ]; then
  echo "ℹ️  No hay nodos worker configurados"
else
  echo "$WORKER_NODES" | while read -r hostname; do
    if [ -n "$hostname" ]; then
      echo ""
      echo "🔧 Configurando $hostname como worker..."
      
      ssh -p "$SSH_PORT" "$SSH_USER@$hostname" bash -s <<EOF
set -euo pipefail
echo "📁 Preparando directorios en $hostname..."
mkdir -p /etc/rancher/rke2

echo "📝 Creando configuración RKE2..."
cat <<EOW > /etc/rancher/rke2/config.yaml
# Configuración Worker - $hostname
token: $MASTER_TOKEN
server: https://$K8S_REG_DOMAIN:443
node-label:
  - "rke2-worker=true"
  - "rke2-rancher=true"
  - "node-role.kubernetes.io/worker=true"
node-taint:
  - "node-role.kubernetes.io/worker=true:NoSchedule"
EOW

echo "⬇️  Instalando RKE2 Agent $RKE2_VERSION en $hostname..."
curl -sfL https://get.rke2.io | INSTALL_RKE2_VERSION=$RKE2_VERSION INSTALL_RKE2_TYPE="agent" sh -

echo "🔄 Iniciando servicio RKE2 Agent en $hostname..."
systemctl enable rke2-agent
systemctl start rke2-agent

echo "✅ RKE2 Agent instalado en $hostname"
EOF

      echo "✅ Worker $hostname configurado"
    fi
  done
fi

# 7. INSTALAR RKE2 EN NODOS STORAGE
# =================================
echo ""
echo "💾 Instalando RKE2 como agente en nodos de almacenamiento..."

STORAGE_NODES=$(get_nodes_by_type "storage")
if [ -z "$STORAGE_NODES" ]; then
  echo "ℹ️  No hay nodos storage configurados"
else
  echo "$STORAGE_NODES" | while read -r hostname; do
    if [ -n "$hostname" ]; then
      echo ""
      echo "🔧 Configurando $hostname como storage..."
      
      ssh -p "$SSH_PORT" "$SSH_USER@$hostname" bash -s <<EOF
set -euo pipefail
echo "📁 Preparando directorios en $hostname..."
mkdir -p /etc/rancher/rke2

echo "📝 Creando configuración RKE2..."
cat <<EOS > /etc/rancher/rke2/config.yaml
# Configuración Storage - $hostname
token: $MASTER_TOKEN
server: https://$K8S_REG_DOMAIN:443
node-label:
  - "rke2-storage=true"
  - "ceph-node=true"
  - "node-role.kubernetes.io/storage=true"
node-taint:
  - "node-role.kubernetes.io/storage=true:NoSchedule"
EOS

echo "⬇️  Instalando RKE2 Agent $RKE2_VERSION en $hostname..."
curl -sfL https://get.rke2.io | INSTALL_RKE2_VERSION=$RKE2_VERSION INSTALL_RKE2_TYPE="agent" sh -

echo "🔄 Iniciando servicio RKE2 Agent en $hostname..."
systemctl enable rke2-agent
systemctl start rke2-agent

echo "✅ RKE2 Agent instalado en $hostname"
EOF

      echo "✅ Storage $hostname configurado"
    fi
  done
fi

# 8. VALIDACIÓN FINAL DEL CLÚSTER
# ===============================
echo ""
echo "⏳ Esperando propagación de todos los nodos..."
sleep 45

echo "🔍 Verificando estado final del clúster..."

# Contar nodos esperados
EXPECTED_MASTERS=$(echo "$NODES_CONFIG" | jq -r '[to_entries[] | select(.value.type == "master")] | length')
EXPECTED_WORKERS=$(echo "$NODES_CONFIG" | jq -r '[to_entries[] | select(.value.type == "worker")] | length')
EXPECTED_STORAGE=$(echo "$NODES_CONFIG" | jq -r '[to_entries[] | select(.value.type == "storage")] | length')
EXPECTED_TOTAL=$((EXPECTED_MASTERS + EXPECTED_WORKERS + EXPECTED_STORAGE))

echo "📊 Nodos esperados:"
echo "   • Masters: $EXPECTED_MASTERS"
echo "   • Workers: $EXPECTED_WORKERS"
echo "   • Storage: $EXPECTED_STORAGE"
echo "   • Total: $EXPECTED_TOTAL"

# Verificar nodos actuales
for i in {1..24}; do
  CURRENT_NODES=$(kubectl get nodes --no-headers 2>/dev/null | wc -l || echo "0")
  READY_NODES=$(kubectl get nodes --no-headers 2>/dev/null | grep -c " Ready " || echo "0")
  
  echo "📈 Estado actual: $READY_NODES/$CURRENT_NODES nodos listos de $EXPECTED_TOTAL esperados"
  
  if [ "$READY_NODES" -eq "$EXPECTED_TOTAL" ]; then
    echo "✅ Todos los nodos están listos"
    break
  fi
  
  if [ $i -eq 24 ]; then
    echo "⚠️  No todos los nodos están listos después de 12 minutos"
    echo "📋 Estado actual de los nodos:"
    kubectl get nodes -o wide
    echo ""
    echo "🔄 ¿Continuar de todas formas? (y/N)"
    read -r -n 1 response
    echo
    if [[ ! "$response" =~ ^[Yy]$ ]]; then
      echo "❌ Instalación cancelada por el usuario"
      exit 1
    fi
    break
  fi
  
  echo "⏳ Esperando nodos restantes... (verificación $i/24)"
  sleep 30
done

# Mostrar estado final
echo ""
echo "📋 Estado final del clúster:"
kubectl get nodes -o wide

echo ""
echo "🏷️  Etiquetas de los nodos:"
kubectl get nodes --show-labels

echo ""
echo "🧮 Información de etcd:"
kubectl get endpoints etcd -n kube-system -o yaml | grep -A 10 "addresses:"

# 9. ACTUALIZAR KUBECONFIG CON SUBDOMINIOS
# ========================================
echo ""
echo "🔧 Actualizando kubeconfig para usar subdominios..."

# Actualizar kubeconfig local para usar el subdominio API
sed -i "s|server: https://.*:6443|server: https://$K8S_API_DOMAIN:443|g" /etc/rancher/rke2/rke2.yaml

# Crear kubeconfig para el proyecto
PROJECT_KUBECONFIG="kubeconfig"
cp /etc/rancher/rke2/rke2.yaml "$PROJECT_KUBECONFIG"
chmod 644 "$PROJECT_KUBECONFIG"

echo "✅ Kubeconfig actualizado:"
echo "   • Local: /etc/rancher/rke2/rke2.yaml"
echo "   • Proyecto: $PROJECT_KUBECONFIG"
echo "   • Server URL: https://$K8S_API_DOMAIN:443"

# Verificar conectividad con el nuevo endpoint
echo ""
echo "🔍 Verificando conectividad con subdominios..."
export KUBECONFIG="$PROJECT_KUBECONFIG"

if kubectl cluster-info &>/dev/null; then
  echo "✅ Conectividad verificada con $K8S_API_DOMAIN"
else
  echo "⚠️  Warning: No se puede conectar via $K8S_API_DOMAIN"
  echo "💡 Verifica la configuración de NGINX Plus LoadBalancer"
fi

echo ""
echo "🎉 Instalación del clúster RKE2 completada exitosamente"
echo "📊 Resumen final:"
echo "   • Clúster RKE2 versión: $RKE2_VERSION"
echo "   • Master principal: $PRIMARY_MASTER"
echo "   • Total de nodos: $CURRENT_NODES"
echo "   • Nodos listos: $READY_NODES"
echo "   • API Endpoint: https://$K8S_API_DOMAIN:443"
echo "   • Registration Endpoint: https://$K8S_REG_DOMAIN:443"
echo "   • Configuración kubeconfig: $PROJECT_KUBECONFIG"
echo ""
echo "🌐 Endpoints configurados:"
echo "   • Kubernetes API: https://$K8S_API_DOMAIN:443"
echo "   • Registration: https://$K8S_REG_DOMAIN:443"
echo "   • Rancher (próximo): https://$RANCHER_DOMAIN"
echo ""
echo "👉 Continúa con: scripts/03-install-ceph.sh"
