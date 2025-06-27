#!/bin/bash
set -euo pipefail
trap 'echo "❌ Error en línea $LINENO durante instalación de Ceph. Revisa el log." && exit 1' ERR

# Cargar variables y funciones
[ -f .env ] && source .env || { echo "❌ Falta archivo .env"; exit 1; }
[ -f scripts/node-helpers.sh ] && source scripts/node-helpers.sh || { echo "❌ Falta archivo scripts/node-helpers.sh"; exit 1; }

LOG="logs/03-install-ceph-$(date +%F-%H%M).log"
mkdir -p logs && exec > >(tee -a "$LOG") 2>&1

echo "💾 Iniciando instalación de Rook-Ceph..."

# 1. VALIDACIONES INICIALES
# =========================
validate_nodes_config

export PATH=$PATH:/var/lib/rancher/rke2/bin
export KUBECONFIG=${KUBECONFIG:-/etc/rancher/rke2/rke2.yaml}

# Verificar que kubeconfig use el endpoint correcto
if ! grep -q "$K8S_API_DOMAIN" "$KUBECONFIG" 2>/dev/null; then
  echo "⚠️  Warning: kubeconfig no apunta a $K8S_API_DOMAIN"
  echo "💡 Ejecuta primero: scripts/02-install-cluster.sh"
fi

# Verificar comandos requeridos
for cmd in kubectl curl; do
  command -v $cmd &>/dev/null || { 
    echo "❌ Falta instalar: $cmd"
    echo "💡 Asegúrate de que RKE2 esté instalado correctamente"
    exit 1
  }
done

# Verificar que el clúster esté funcionando
if ! kubectl get nodes &>/dev/null; then
  echo "❌ El clúster Kubernetes no está accesible"
  echo "💡 Ejecuta primero: scripts/02-install-cluster.sh"
  exit 1
fi

# 2. VERIFICAR NODOS DE STORAGE
# =============================
echo "🔍 Verificando nodos de almacenamiento..."

STORAGE_NODES=$(get_nodes_by_type "storage")
if [ -z "$STORAGE_NODES" ]; then
  echo "❌ No hay nodos de storage configurados en NODES_CONFIG"
  echo "💡 Configura al menos un nodo con type: 'storage' en .env"
  exit 1
fi

STORAGE_COUNT=$(echo "$STORAGE_NODES" | wc -l)
echo "📊 Nodos de storage detectados: $STORAGE_COUNT"

# Verificar que los nodos storage estén en el clúster
echo "$STORAGE_NODES" | while read -r hostname; do
  if [ -n "$hostname" ]; then
    echo -n "➡️  Verificando $hostname en clúster: "
    if kubectl get node "$hostname" &>/dev/null; then
      NODE_STATUS=$(kubectl get node "$hostname" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')
      if [ "$NODE_STATUS" = "True" ]; then
        echo "✅ Nodo listo"
      else
        echo "❌ Nodo no está listo"
        exit 1
      fi
    else
      echo "❌ Nodo no encontrado en el clúster"
      exit 1
    fi
  fi
done

# 3. VERIFICAR DISCOS EN NODOS STORAGE
# ====================================
echo "💽 Verificando discos /dev/sdb en nodos de storage..."

echo "$STORAGE_NODES" | while read -r hostname; do
  if [ -n "$hostname" ]; then
    echo -n "➡️  Verificando disco en $hostname: "
    if ssh -p "$SSH_PORT" "$SSH_USER@$hostname" "lsblk /dev/sdb && ! mount | grep -q /dev/sdb" &>/dev/null; then
      DISK_SIZE=$(ssh -p "$SSH_PORT" "$SSH_USER@$hostname" "lsblk /dev/sdb -b -n -o SIZE" | head -1)
      DISK_SIZE_GB=$((DISK_SIZE / 1024 / 1024 / 1024))
      echo "✅ /dev/sdb disponible (${DISK_SIZE_GB}GB, no montado)"
    else
      echo "❌ /dev/sdb no disponible o está montado"
      echo "💡 Asegúrate de que /dev/sdb existe y no esté en uso"
      exit 1
    fi
  fi
done

# 4. LIMPIAR INSTALACIÓN PREVIA (SI EXISTE)
# =========================================
echo "🧹 Verificando instalación previa de Ceph..."

if kubectl get namespace rook-ceph &>/dev/null; then
  echo "⚠️  Namespace rook-ceph ya existe"
  echo "🔄 ¿Deseas eliminar la instalación previa y reinstalar? (y/N)"
  read -r -n 1 response
  echo
  if [[ "$response" =~ ^[Yy]$ ]]; then
    echo "🗑️  Eliminando instalación previa..."
    
    # Eliminar recursos en orden
    kubectl delete -f ceph-storageclass.yaml --ignore-not-found --timeout=60s || true
    kubectl delete -f ceph-cluster.yaml --ignore-not-found --timeout=120s || true
    
    # Esperar a que se eliminen los pods
    echo "⏳ Esperando eliminación de pods Ceph..."
    kubectl -n rook-ceph delete --all pods --force --grace-period=0 || true
    sleep 30
    
    # Eliminar namespace
    kubectl delete namespace rook-ceph --timeout=180s || true
    
    # Limpiar datos de Ceph en nodos storage
    echo "🧹 Limpiando datos previos en nodos storage..."
    echo "$STORAGE_NODES" | while read -r hostname; do
      if [ -n "$hostname" ]; then
        echo "  🗑️  Limpiando $hostname..."
        ssh -p "$SSH_PORT" "$SSH_USER@$hostname" "
          rm -rf /var/lib/rook/*
          wipefs -a /dev/sdb || true
          sgdisk --zap-all /dev/sdb || true
        " || true
      fi
    done
    
    echo "✅ Limpieza completada"
  else
    echo "❌ No se puede continuar con Ceph ya instalado"
    exit 1
  fi
fi

# 5. CREAR NAMESPACE Y APLICAR MANIFIESTOS BASE
# =============================================
echo "📦 Creando namespace y aplicando manifiestos de Rook..."

kubectl create namespace rook-ceph || true

# Descargar manifiestos oficiales
echo "📥 Descargando manifiestos de Rook-Ceph v1.12.0..."
ROOK_VERSION="v1.12.0"
ROOK_BASE_URL="https://raw.githubusercontent.com/rook/rook/$ROOK_VERSION/deploy/examples"

curl -sL "$ROOK_BASE_URL/crds.yaml" -o rook-crds.yaml
curl -sL "$ROOK_BASE_URL/common.yaml" -o rook-common.yaml
curl -sL "$ROOK_BASE_URL/operator.yaml" -o rook-operator.yaml

# Aplicar manifiestos
echo "🔧 Aplicando CRDs de Rook..."
kubectl apply -f rook-crds.yaml

echo "🔧 Aplicando recursos comunes..."
kubectl apply -f rook-common.yaml

echo "🔧 Aplicando operador Rook..."
kubectl apply -f rook-operator.yaml

# 6. ESPERAR A QUE EL OPERADOR ESTÉ LISTO
# =======================================
echo "⏳ Esperando que el operador Rook esté listo..."

for i in {1..20}; do
  if kubectl -n rook-ceph get deployment rook-ceph-operator &>/dev/null; then
    if kubectl -n rook-ceph rollout status deployment/rook-ceph-operator --timeout=30s &>/dev/null; then
      echo "✅ Operador Rook está listo"
      break
    fi
  fi
  
  if [ $i -eq 20 ]; then
    echo "❌ Timeout esperando el operador Rook"
    echo "📋 Estado actual:"
    kubectl -n rook-ceph get pods
    exit 1
  fi
  
  echo "⏳ Esperando operador Rook... (intento $i/20)"
  sleep 15
done

# 7. CREAR CEPHCLUSTER DINÁMICAMENTE
# ==================================
echo "📦 Creando configuración CephCluster..."

# Generar lista de nodos storage dinámicamente
STORAGE_NODES_YAML=""
echo "$STORAGE_NODES" | while read -r hostname; do
  if [ -n "$hostname" ]; then
    STORAGE_NODES_YAML="$STORAGE_NODES_YAML
    - name: $hostname
      devices:
      - name: \"/dev/sdb\""
  fi
done

cat > ceph-cluster.yaml <<EOF
apiVersion: ceph.rook.io/v1
kind: CephCluster
metadata:
  name: rook-ceph
  namespace: rook-ceph
spec:
  cephVersion:
    image: quay.io/ceph/ceph:v17.2.6
    allowUnsupported: false
  dataDirHostPath: /var/lib/rook
  skipUpgradeChecks: false
  continueUpgradeAfterChecksEvenIfNotHealthy: false
  waitTimeoutForHealthyOSDInMinutes: 10
  mon:
    count: $([ $STORAGE_COUNT -ge 3 ] && echo 3 || echo $STORAGE_COUNT)
    allowMultiplePerNode: false
  mgr:
    count: 2
    allowMultiplePerNode: false
  dashboard:
    enabled: true
    ssl: true
  monitoring:
    enabled: false
  network:
    connections:
      encryption:
        enabled: false
      compression:
        enabled: false
  crashCollector:
    disable: false
  logCollector:
    enabled: true
    periodicity: daily
    maxLogSize: 500M
  cleanupPolicy:
    confirmation: ""
    sanitizeDisks:
      method: quick
      dataSource: zero
      iteration: 1
  placement:
    all:
      nodeAffinity:
        requiredDuringSchedulingIgnoredDuringExecution:
          nodeSelectorTerms:
          - matchExpressions:
            - key: ceph-node
              operator: In
              values:
              - "true"
      tolerations:
      - key: node-role.kubernetes.io/storage
        operator: Equal
        value: "true"
        effect: NoSchedule
  storage:
    useAllNodes: false
    useAllDevices: false
    nodes:$(echo "$STORAGE_NODES" | while read -r hostname; do
      if [ -n "$hostname" ]; then
        echo "
    - name: $hostname
      devices:
      - name: \"/dev/sdb\""
      fi
    done)
  resources:
    mgr:
      limits:
        cpu: "1000m"
        memory: "1Gi"
      requests:
        cpu: "500m"
        memory: "512Mi"
    mon:
      limits:
        cpu: "2000m"
        memory: "2Gi"
      requests:
        cpu: "1000m"
        memory: "1Gi"
    osd:
      limits:
        cpu: "2000m"
        memory: "4Gi"
      requests:
        cpu: "1000m"
        memory: "2Gi"
EOF

echo "🚀 Aplicando CephCluster..."
kubectl apply -f ceph-cluster.yaml

# 8. MONITOREAR DESPLIEGUE DE CEPH
# ================================
echo "⏳ Monitoreando despliegue de Ceph..."

for i in {1..40}; do
  echo "📊 Estado del clúster Ceph (verificación $i/40):"
  
  # Mostrar estado de pods
  POD_COUNT=$(kubectl -n rook-ceph get pods 2>/dev/null | grep -v NAME | wc -l || echo "0")
  RUNNING_PODS=$(kubectl -n rook-ceph get pods 2>/dev/null | grep -c "Running" || echo "0")
  
  echo "   • Pods: $RUNNING_PODS/$POD_COUNT ejecutándose"
  
  # Verificar OSDs
  OSD_COUNT=$(kubectl -n rook-ceph get pods 2>/dev/null | grep -c "rook-ceph-osd" || echo "0")
  if [ "$OSD_COUNT" -gt 0 ]; then
    echo "   • OSDs detectados: $OSD_COUNT"
  fi
  
  # Verificar estado del cluster
  if kubectl -n rook-ceph get cephcluster rook-ceph -o jsonpath='{.status.phase}' 2>/dev/null | grep -q "Ready"; then
    echo "✅ Clúster Ceph está READY"
    break
  fi
  
  if [ $i -eq 40 ]; then
    echo "⚠️  Ceph no está completamente listo después de 20 minutos"
    echo "📋 Estado actual de pods:"
    kubectl -n rook-ceph get pods
    echo ""
    echo "🔄 ¿Continuar con la creación del StorageClass? (y/N)"
    read -r -n 1 response
    echo
    if [[ ! "$response" =~ ^[Yy]$ ]]; then
      echo "❌ Instalación cancelada por el usuario"
      exit 1
    fi
    break
  fi
  
  sleep 30
done

# 9. CREAR STORAGECLASS
# =====================
echo "📄 Creando StorageClass para Ceph..."

cat > ceph-storageclass.yaml <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: rook-ceph-block
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: rook-ceph.rbd.csi.ceph.com
parameters:
  clusterID: rook-ceph
  pool: replicapool
  imageFormat: "2"
  imageFeatures: layering
  csi.storage.k8s.io/provisioner-secret-name: rook-csi-rbd-provisioner
  csi.storage.k8s.io/provisioner-secret-namespace: rook-ceph
  csi.storage.k8s.io/controller-expand-secret-name: rook-csi-rbd-provisioner
  csi.storage.k8s.io/controller-expand-secret-namespace: rook-ceph
  csi.storage.k8s.io/node-stage-secret-name: rook-csi-rbd-node
  csi.storage.k8s.io/node-stage-secret-namespace: rook-ceph
  csi.storage.k8s.io/fstype: ext4
allowVolumeExpansion: true
reclaimPolicy: Delete
volumeBindingMode: Immediate
EOF

kubectl apply -f ceph-storageclass.yaml

# 10. CREAR POOL DE REPLICACIÓN
# =============================
echo "🏊 Creando pool de replicación..."

cat > ceph-blockpool.yaml <<EOF
apiVersion: ceph.rook.io/v1
kind: CephBlockPool
metadata:
  name: replicapool
  namespace: rook-ceph
spec:
  failureDomain: host
  replicated:
    size: $([ $STORAGE_COUNT -ge 3 ] && echo 3 || echo $STORAGE_COUNT)
    requireSafeReplicaSize: true
  parameters:
    compression_mode: none
EOF

kubectl apply -f ceph-blockpool.yaml

# 11. VERIFICACIÓN FINAL
# ======================
echo ""
echo "🔍 Verificación final del almacenamiento Ceph..."

# Estado del clúster
echo "📊 Estado del clúster Ceph:"
kubectl -n rook-ceph get cephcluster

# Pods de Ceph
echo ""
echo "🐚 Pods de Ceph:"
kubectl -n rook-ceph get pods

# StorageClasses
echo ""
echo "💾 StorageClasses disponibles:"
kubectl get storageclass

# Verificar que el pool esté listo
echo ""
echo "🏊 Estado del pool de bloques:"
kubectl -n rook-ceph get cephblockpool

# 12. CREAR PVC DE PRUEBA
# =======================
echo ""
echo "🧪 Creando PVC de prueba para validar Ceph..."

cat > test-pvc.yaml <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ceph-test-pvc
  namespace: default
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
  storageClassName: rook-ceph-block
EOF

kubectl apply -f test-pvc.yaml

# Esperar a que el PVC esté bound
echo "⏳ Esperando que el PVC de prueba esté bound..."
for i in {1..12}; do
  PVC_STATUS=$(kubectl get pvc ceph-test-pvc -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
  if [ "$PVC_STATUS" = "Bound" ]; then
    echo "✅ PVC de prueba está bound correctamente"
    break
  elif [ $i -eq 12 ]; then
    echo "⚠️  PVC de prueba no se pudo crear en 3 minutos"
    kubectl describe pvc ceph-test-pvc
  else
    echo "⏳ PVC status: $PVC_STATUS (intento $i/12)"
    sleep 15
  fi
done

# Limpiar PVC de prueba
kubectl delete pvc ceph-test-pvc || true
rm -f test-pvc.yaml

echo ""
echo "🎉 Instalación de Ceph completada exitosamente"
echo "📊 Resumen:"
echo "   • Clúster Ceph: rook-ceph"
echo "   • Nodos de storage: $STORAGE_COUNT"
echo "   • StorageClass: rook-ceph-block (default)"
echo "   • Pool de replicación: replicapool"
echo "   • Dashboard: Habilitado (SSL)"
echo ""
echo "📁 Archivos generados:"
echo "   • rook-crds.yaml, rook-common.yaml, rook-operator.yaml"
echo "   • ceph-cluster.yaml, ceph-storageclass.yaml, ceph-blockpool.yaml"
echo ""
echo "👉 Continúa con: scripts/04-install-metallb.sh"
