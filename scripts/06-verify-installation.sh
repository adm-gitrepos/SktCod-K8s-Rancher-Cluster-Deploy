#!/bin/bash
set -euo pipefail
trap 'echo "❌ Error en línea $LINENO durante verificación. Revisa el log." && exit 1' ERR

# Cargar variables y funciones
[ -f .env ] && source .env || { echo "❌ Falta archivo .env"; exit 1; }
[ -f scripts/node-helpers.sh ] && source scripts/node-helpers.sh || { echo "❌ Falta archivo scripts/node-helpers.sh"; exit 1; }

LOG="logs/06-verify-installation-$(date +%F-%H%M).log"
mkdir -p logs && exec > >(tee -a "$LOG") 2>&1

echo "🔍 Iniciando verificación completa del clúster..."

# 1. CONFIGURACIÓN INICIAL
# ========================
validate_nodes_config

# Validar configuración de subdominios
validate_subdomain_config

export PATH=$PATH:/var/lib/rancher/rke2/bin
export KUBECONFIG=${KUBECONFIG:-/etc/rancher/rke2/rke2.yaml}

# Verificar que kubeconfig use el endpoint correcto
if ! grep -q "$K8S_API_DOMAIN" "$KUBECONFIG" 2>/dev/null; then
  echo "⚠️  Warning: kubeconfig no apunta a $K8S_API_DOMAIN"
  echo "💡 Ejecuta primero: scripts/02-install-cluster.sh"
fi

# Verificar kubectl
if ! command -v kubectl &>/dev/null; then
  echo "❌ kubectl no está disponible"
  exit 1
fi

# Verificar acceso al clúster
if ! kubectl get nodes &>/dev/null; then
  echo "❌ No se puede acceder al clúster Kubernetes"
  exit 1
fi

echo "✅ Acceso al clúster confirmado"

# 2. VERIFICACIÓN DE NODOS
# ========================
echo ""
echo "🖥️  VERIFICACIÓN DE NODOS"
echo "=========================="

# Mostrar todos los nodos
echo "📊 Estado de todos los nodos:"
kubectl get nodes -o wide

echo ""
echo "🏷️  Etiquetas y roles de nodos:"
kubectl get nodes --show-labels | grep -E "(NAME|master|worker|storage)"

# Contar nodos por tipo
EXPECTED_MASTERS=$(echo "$NODES_CONFIG" | jq -r '[to_entries[] | select(.value.type == "master")] | length')
EXPECTED_WORKERS=$(echo "$NODES_CONFIG" | jq -r '[to_entries[] | select(.value.type == "worker")] | length')
EXPECTED_STORAGE=$(echo "$NODES_CONFIG" | jq -r '[to_entries[] | select(.value.type == "storage")] | length')
EXPECTED_TOTAL=$((EXPECTED_MASTERS + EXPECTED_WORKERS + EXPECTED_STORAGE))

ACTUAL_NODES=$(kubectl get nodes --no-headers | wc -l)
READY_NODES=$(kubectl get nodes --no-headers | grep -c " Ready " || echo "0")

echo ""
echo "📈 Resumen de nodos:"
echo "   • Esperados: $EXPECTED_TOTAL (M:$EXPECTED_MASTERS, W:$EXPECTED_WORKERS, S:$EXPECTED_STORAGE)"
echo "   • Actuales: $ACTUAL_NODES"
echo "   • Listos: $READY_NODES"

if [ "$READY_NODES" -eq "$EXPECTED_TOTAL" ]; then
  echo "✅ Todos los nodos esperados están listos"
else
  echo "⚠️  No todos los nodos están listos"
fi

# Verificar nodos por tipo específico
echo ""
echo "🔍 Verificación por tipo de nodo:"

# Masters
MASTER_NODES=$(kubectl get nodes -l rke2-master=true --no-headers | wc -l || echo "0")
echo "   • Masters: $MASTER_NODES/$EXPECTED_MASTERS $([ "$MASTER_NODES" -eq "$EXPECTED_MASTERS" ] && echo "✅" || echo "❌")"

# Workers
WORKER_NODES=$(kubectl get nodes -l rke2-worker=true --no-headers | wc -l || echo "0")
echo "   • Workers: $WORKER_NODES/$EXPECTED_WORKERS $([ "$WORKER_NODES" -eq "$EXPECTED_WORKERS" ] && echo "✅" || echo "❌")"

# Storage
STORAGE_NODES=$(kubectl get nodes -l rke2-storage=true --no-headers | wc -l || echo "0")
echo "   • Storage: $STORAGE_NODES/$EXPECTED_STORAGE $([ "$STORAGE_NODES" -eq "$EXPECTED_STORAGE" ] && echo "✅" || echo "❌")"

# 3. VERIFICACIÓN DEL SISTEMA
# ===========================
echo ""
echo "🔧 VERIFICACIÓN DE PODS DEL SISTEMA"
echo "===================================="

echo "📦 Pods del sistema críticos:"
kubectl get pods -n kube-system | grep -E "(etcd|kube-apiserver|kube-controller|kube-scheduler|kube-proxy|calico)"

echo ""
echo "🔍 Estado de componentes críticos:"

# Verificar etcd
ETCD_PODS=$(kubectl get pods -n kube-system -l component=etcd --no-headers | grep -c "Running" || echo "0")
ETCD_EXPECTED=$EXPECTED_MASTERS
echo "   • etcd: $ETCD_PODS/$ETCD_EXPECTED pods $([ "$ETCD_PODS" -eq "$ETCD_EXPECTED" ] && echo "✅" || echo "❌")"

# Verificar API server
API_PODS=$(kubectl get pods -n kube-system -l component=kube-apiserver --no-headers | grep -c "Running" || echo "0")
echo "   • kube-apiserver: $API_PODS/$ETCD_EXPECTED pods $([ "$API_PODS" -eq "$ETCD_EXPECTED" ] && echo "✅" || echo "❌")"

# Verificar CNI (Calico)
CALICO_PODS=$(kubectl get pods -n kube-system -l k8s-app=calico-node --no-headers | grep -c "Running" || echo "0")
echo "   • Calico CNI: $CALICO_PODS/$EXPECTED_TOTAL pods $([ "$CALICO_PODS" -eq "$EXPECTED_TOTAL" ] && echo "✅" || echo "❌")"

# Verificar kube-proxy
PROXY_PODS=$(kubectl get pods -n kube-system -l k8s-app=kube-proxy --no-headers | grep -c "Running" || echo "0")
echo "   • kube-proxy: $PROXY_PODS/$EXPECTED_TOTAL pods $([ "$PROXY_PODS" -eq "$EXPECTED_TOTAL" ] && echo "✅" || echo "❌")"

# 4. VERIFICACIÓN DE CEPH
# =======================
echo ""
echo "💾 VERIFICACIÓN DE ALMACENAMIENTO CEPH"
echo "======================================="

if kubectl get namespace rook-ceph &>/dev/null; then
  echo "📊 Estado del clúster Ceph:"
  kubectl -n rook-ceph get cephcluster
  
  echo ""
  echo "🐚 Pods de Ceph:"
  kubectl -n rook-ceph get pods | grep -E "(NAME|Running|Error|Pending)"
  
  # Contar componentes Ceph
  MON_PODS=$(kubectl -n rook-ceph get pods -l app=rook-ceph-mon --no-headers | grep -c "Running" || echo "0")
  MGR_PODS=$(kubectl -n rook-ceph get pods -l app=rook-ceph-mgr --no-headers | grep -c "Running" || echo "0")
  OSD_PODS=$(kubectl -n rook-ceph get pods -l app=rook-ceph-osd --no-headers | grep -c "Running" || echo "0")
  
  echo ""
  echo "🔍 Componentes Ceph:"
  echo "   • MON pods: $MON_PODS $([ "$MON_PODS" -ge 1 ] && echo "✅" || echo "❌")"
  echo "   • MGR pods: $MGR_PODS $([ "$MGR_PODS" -ge 1 ] && echo "✅" || echo "❌")"
  echo "   • OSD pods: $OSD_PODS $([ "$OSD_PODS" -ge 1 ] && echo "✅" || echo "❌")"
  
  # Verificar StorageClass
  echo ""
  echo "💽 StorageClasses:"
  kubectl get storageclass
  
  if kubectl get storageclass rook-ceph-block &>/dev/null; then
    echo "✅ StorageClass rook-ceph-block disponible"
  else
    echo "❌ StorageClass rook-ceph-block no encontrada"
  fi
else
  echo "⚠️  Namespace rook-ceph no encontrado - Ceph no está instalado"
fi

# 5. VERIFICACIÓN DE METALLB
# ==========================
echo ""
echo "🌐 VERIFICACIÓN DE METALLB"
echo "=========================="

if kubectl get namespace metallb-system &>/dev/null; then
  echo "📊 Pods de MetalLB:"
  kubectl -n metallb-system get pods
  
  # Verificar componentes MetalLB
  CONTROLLER_PODS=$(kubectl -n metallb-system get pods -l app=metallb,component=controller --no-headers | grep -c "Running" || echo "0")
  SPEAKER_PODS=$(kubectl -n metallb-system get pods -l app=metallb,component=speaker --no-headers | grep -c "Running" || echo "0")
  
  echo ""
  echo "🔍 Componentes MetalLB:"
  echo "   • Controller: $CONTROLLER_PODS pods $([ "$CONTROLLER_PODS" -ge 1 ] && echo "✅" || echo "❌")"
  echo "   • Speaker: $SPEAKER_PODS pods $([ "$SPEAKER_PODS" -ge 1 ] && echo "✅" || echo "❌")"
  
  # Verificar configuración
  echo ""
  echo "🏊 Configuración de pools IP:"
  kubectl -n metallb-system get ipaddresspool
  
  echo ""
  echo "📢 Configuración L2Advertisement:"
  kubectl -n metallb-system get l2advertisement
else
  echo "⚠️  Namespace metallb-system no encontrado - MetalLB no está instalado"
fi

# 6. VERIFICACIÓN DE RANCHER
# ==========================
echo ""
echo "🚀 VERIFICACIÓN DE RANCHER"
echo "=========================="

if kubectl get namespace cattle-system &>/dev/null; then
  echo "📊 Pods de Rancher:"
  kubectl -n cattle-system get pods -l app=rancher
  
  # Verificar componentes Rancher
  RANCHER_PODS=$(kubectl -n cattle-system get pods -l app=rancher --no-headers | grep -c "Running" || echo "0")
  
  echo ""
  echo "🔍 Estado de Rancher:"
  echo "   • Rancher pods: $RANCHER_PODS/3 $([ "$RANCHER_PODS" -eq 3 ] && echo "✅" || echo "❌")"
  
  # Verificar servicios
  echo ""
  echo "🌐 Servicios de Rancher:"
  kubectl -n cattle-system get services
  
  # Verificar certificados
  echo ""
  echo "🔐 Certificados:"
  kubectl -n cattle-system get certificates 2>/dev/null || echo "No se encontraron certificados"
  
  # Verificar ingress
  echo ""
  echo "📋 Ingress:"
  kubectl -n cattle-system get ingress 2>/dev/null || echo "No se encontraron ingress"
  
  # Verificar acceso HTTPS
  if [ -n "${RANCHER_DOMAIN:-}" ]; then
    echo ""
    echo -n "🌐 Verificando acceso HTTPS a $RANCHER_DOMAIN: "
    if curl -k --max-time 10 -s -I "https://$RANCHER_DOMAIN" | grep -q "200 OK"; then
      echo "✅ Rancher responde correctamente"
    else
      echo "❌ Rancher no responde"
    fi
  fi
else
  echo "⚠️  Namespace cattle-system no encontrado - Rancher no está instalado"
fi

# 7. VERIFICACIÓN DE CERT-MANAGER
# ===============================
echo ""
echo "🔐 VERIFICACIÓN DE CERT-MANAGER"
echo "==============================="

if kubectl get namespace cert-manager &>/dev/null; then
  echo "📊 Pods de cert-manager:"
  kubectl -n cert-manager get pods
  
  # Verificar componentes cert-manager
  CM_PODS=$(kubectl -n cert-manager get pods -l app=cert-manager --no-headers | grep -c "Running" || echo "0")
  CAINJECTOR_PODS=$(kubectl -n cert-manager get pods -l app=cainjector --no-headers | grep -c "Running" || echo "0")
  WEBHOOK_PODS=$(kubectl -n cert-manager get pods -l app=webhook --no-headers | grep -c "Running" || echo "0")
  
  echo ""
  echo "🔍 Componentes cert-manager:"
  echo "   • cert-manager: $CM_PODS pods $([ "$CM_PODS" -ge 1 ] && echo "✅" || echo "❌")"
  echo "   • cainjector: $CAINJECTOR_PODS pods $([ "$CAINJECTOR_PODS" -ge 1 ] && echo "✅" || echo "❌")"
  echo "   • webhook: $WEBHOOK_PODS pods $([ "$WEBHOOK_PODS" -ge 1 ] && echo "✅" || echo "❌")"
else
  echo "⚠️  Namespace cert-manager no encontrado - cert-manager no está instalado"
fi

# 8. CREAR APLICACIÓN DE PRUEBA
# =============================
echo ""
echo "🧪 CREANDO APLICACIÓN DE PRUEBA"
echo "==============================="

# Limpiar aplicación previa si existe
kubectl delete -f test-app-complete.yaml --ignore-not-found &>/dev/null || true
sleep 5

echo "📦 Desplegando aplicación de prueba completa..."

cat > test-app-complete.yaml <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: test-nginx
  namespace: default
  labels:
    app: test-nginx
spec:
  replicas: 2
  selector:
    matchLabels:
      app: test-nginx
  template:
    metadata:
      labels:
        app: test-nginx
    spec:
      containers:
      - name: nginx
        image: nginx:alpine
        ports:
        - containerPort: 80
        resources:
          requests:
            memory: "64Mi"
            cpu: "50m"
          limits:
            memory: "128Mi"
            cpu: "100m"
        readinessProbe:
          httpGet:
            path: /
            port: 80
          initialDelaySeconds: 5
          periodSeconds: 10
        livenessProbe:
          httpGet:
            path: /
            port: 80
          initialDelaySeconds: 15
          periodSeconds: 20
---
apiVersion: v1
kind: Service
metadata:
  name: test-nginx-svc
  namespace: default
  labels:
    app: test-nginx
spec:
  type: LoadBalancer
  selector:
    app: test-nginx
  ports:
  - port: 80
    targetPort: 80
    protocol: TCP
    name: http
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-pvc
  namespace: default
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: rook-ceph-block
  resources:
    requests:
      storage: 1Gi
EOF

kubectl apply -f test-app-complete.yaml

# Esperar a que la aplicación esté lista
echo "⏳ Esperando que la aplicación esté lista..."
kubectl wait --for=condition=Available deployment/test-nginx --timeout=180s

echo ""
echo "📊 Estado de la aplicación de prueba:"
kubectl get deployment test-nginx
kubectl get pods -l app=test-nginx
kubectl get service test-nginx-svc
kubectl get pvc test-pvc

# Verificar PVC
PVC_STATUS=$(kubectl get pvc test-pvc -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
echo ""
echo "💾 Estado del almacenamiento:"
echo "   • PVC test-pvc: $PVC_STATUS $([ "$PVC_STATUS" = "Bound" ] && echo "✅" || echo "❌")"

# Verificar LoadBalancer
EXTERNAL_IP=$(kubectl get service test-nginx-svc -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")

if [ -n "$EXTERNAL_IP" ] && [ "$EXTERNAL_IP" != "null" ]; then
  echo "   • LoadBalancer IP: $EXTERNAL_IP ✅"
  
  # Probar conectividad HTTP
  echo -n "   • Conectividad HTTP: "
  if curl -s --max-time 10 "http://$EXTERNAL_IP" | grep -q "nginx" &>/dev/null; then
    echo "✅ Funcional"
  else
    echo "❌ Sin respuesta"
  fi
else
  echo "   • LoadBalancer IP: Pendiente ⏳"
fi

# 9. VERIFICAR RECURSOS DEL CLÚSTER
# =================================
echo ""
echo "📊 RECURSOS DEL CLÚSTER"
echo "======================="

echo "🧠 Uso de memoria por nodo:"
kubectl top nodes --no-headers 2>/dev/null | while read -r node cpu memory rest; do
  echo "   • $node: $memory memoria"
done || echo "   ⚠️  Metrics server no disponible"

echo ""
echo "💽 Uso de almacenamiento:"
kubectl get pv 2>/dev/null | grep -v NAME || echo "   ⚠️  No hay Persistent Volumes"

echo ""
echo "🌐 Servicios tipo LoadBalancer:"
kubectl get services -A | grep LoadBalancer || echo "   ⚠️  No hay servicios LoadBalancer"

# 10. EVENTOS RECIENTES
# =====================
echo ""
echo "📋 EVENTOS RECIENTES DEL CLÚSTER"
echo "================================"
kubectl get events --sort-by=.metadata.creationTimestamp | tail -20

# 11. LIMPIEZA DE APLICACIÓN DE PRUEBA
# ====================================
echo ""
echo "🧹 Limpiando aplicación de prueba..."
kubectl delete -f test-app-complete.yaml
rm -f test-app-complete.yaml

# 12. RESUMEN FINAL
# =================
echo ""
echo "📊 RESUMEN DE VERIFICACIÓN"
echo "=========================="

TOTAL_CHECKS=0
PASSED_CHECKS=0

# Función para incrementar contadores
check_status() {
  local status=$1
  ((TOTAL_CHECKS++))
  if [ "$status" = "pass" ]; then
    ((PASSED_CHECKS++))
    echo "✅"
  else
    echo "❌"
  fi
}

echo "🔍 Componentes verificados:"

# Nodos
echo -n "   • Nodos del clúster: "
[ "$READY_NODES" -eq "$EXPECTED_TOTAL" ] && check_status "pass" || check_status "fail"

# Sistema
echo -n "   • Pods del sistema: "
[ "$ETCD_PODS" -ge 1 ] && [ "$API_PODS" -ge 1 ] && check_status "pass" || check_status "fail"

# Ceph (si está instalado)
if kubectl get namespace rook-ceph &>/dev/null; then
  echo -n "   • Almacenamiento Ceph: "
  [ "$OSD_PODS" -ge 1 ] && [ "$MON_PODS" -ge 1 ] && check_status "pass" || check_status "fail"
fi

# MetalLB (si está instalado)
if kubectl get namespace metallb-system &>/dev/null; then
  echo -n "   • MetalLB LoadBalancer: "
  [ "$CONTROLLER_PODS" -ge 1 ] && [ "$SPEAKER_PODS" -ge 1 ] && check_status "pass" || check_status "fail"
fi

# Rancher (si está instalado)
if kubectl get namespace cattle-system &>/dev/null; then
  echo -n "   • Rancher Management: "
  [ "$RANCHER_PODS" -eq 3 ] && check_status "pass" || check_status "fail"
fi

# cert-manager (si está instalado)
if kubectl get namespace cert-manager &>/dev/null; then
  echo -n "   • cert-manager: "
  [ "$CM_PODS" -ge 1 ] && [ "$WEBHOOK_PODS" -ge 1 ] && check_status "pass" || check_status "fail"
fi

echo ""
echo "📈 Resultado final: $PASSED_CHECKS/$TOTAL_CHECKS verificaciones exitosas"

if [ "$PASSED_CHECKS" -eq "$TOTAL_CHECKS" ]; then
  echo "🎉 ¡Verificación completada exitosamente!"
  echo "✅ El clúster está completamente funcional"
else
  echo "⚠️  Algunas verificaciones fallaron"
  echo "💡 Revisa los logs y corrige los problemas antes de continuar"
fi

echo ""
echo "📁 Información del clúster:"
echo "   • Configuración: /etc/rancher/rke2/rke2.yaml"
echo "   • Logs del sistema: journalctl -u rke2-server"
if [ -n "${RANCHER_DOMAIN:-}" ]; then
  echo "   • Rancher UI: https://$RANCHER_DOMAIN"
fi

echo ""
echo "👉 Continúa con: scripts/07-test-ha.sh"
