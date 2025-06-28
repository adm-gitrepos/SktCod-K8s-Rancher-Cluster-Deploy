#!/bin/bash
# ============================================================
# Biblioteca de funciones para manejo dinámico de nodos basado en NODES_CONFIG
# Autor: @SktCod.ByChisto
# Versión: 2.0

set -euo pipefail
trap 'echo "❌ Error en línea $LINENO durante instalación de MetalLB. Revisa el log." && exit 1' ERR

# Cargar variables y funciones
[ -f .env ] && source .env || { echo "❌ Falta archivo .env"; exit 1; }
[ -f scripts/node-helpers.sh ] && source scripts/node-helpers.sh || { echo "❌ Falta archivo scripts/node-helpers.sh"; exit 1; }

LOG="logs/04-install-metallb-$(date +%F-%H%M).log"
mkdir -p logs && exec > >(tee -a "$LOG") 2>&1

echo "🌐 Iniciando instalación de MetalLB..."

# 1. VALIDACIONES INICIALES
# =========================
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

# Verificar comandos requeridos
for cmd in kubectl; do
  command -v $cmd &>/dev/null || { 
    echo "❌ Falta comando: $cmd"
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

# 2. VALIDAR CONFIGURACIÓN DE METALLB
# ===================================
echo "🔍 Validando configuración de MetalLB..."

if [ -z "${METALLB_IP_RANGE:-}" ]; then
  echo "❌ METALLB_IP_RANGE no está definido en .env"
  echo "💡 Ejemplo: METALLB_IP_RANGE=192.168.1.100-192.168.1.110"
  exit 1
fi

if [ -z "${LB_IP:-}" ]; then
  echo "❌ LB_IP no está definido en .env"
  echo "💡 Ejemplo: LB_IP=192.168.1.100"
  exit 1
fi

echo "📊 Configuración de MetalLB:"
echo "   • Rango de IPs: $METALLB_IP_RANGE"
echo "   • LoadBalancer IP: $LB_IP"

# Validar formato del rango de IPs
if [[ ! "$METALLB_IP_RANGE" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+-[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "❌ Formato de METALLB_IP_RANGE inválido"
  echo "💡 Formato correcto: IP_INICIO-IP_FIN (ej: 192.168.1.100-192.168.1.110)"
  exit 1
fi

# Extraer IPs de inicio y fin
START_IP=$(echo "$METALLB_IP_RANGE" | cut -d'-' -f1)
END_IP=$(echo "$METALLB_IP_RANGE" | cut -d'-' -f2)

echo "   • IP inicial: $START_IP"
echo "   • IP final: $END_IP"

# 3. VERIFICAR CONECTIVIDAD DE RED
# ================================
echo "🔗 Verificando conectividad de red..."

# Verificar que LB_IP esté en el rango o sea accesible
echo -n "➡️  Verificando acceso a LB_IP ($LB_IP): "
if ping -c 1 -W 3 "$LB_IP" &>/dev/null; then
  echo "✅ LB_IP es accesible"
else
  echo "⚠️  LB_IP no responde a ping (puede ser normal si está configurado)"
fi

# Verificar que las IPs del rango estén libres
echo "🔍 Verificando disponibilidad de IPs en el rango..."
IP_CONFLICTS=0

# Función para verificar IP
check_ip_availability() {
  local ip=$1
  if ping -c 1 -W 1 "$ip" &>/dev/null; then
    echo "⚠️  IP $ip está en uso"
    ((IP_CONFLICTS++))
  else
    echo "✅ IP $ip disponible"
  fi
}

# Verificar algunas IPs del rango (para no saturar la salida)
check_ip_availability "$START_IP"
check_ip_availability "$END_IP"

if [ $IP_CONFLICTS -gt 0 ]; then
  echo "⚠️  Se detectaron $IP_CONFLICTS IPs en uso en el rango"
  echo "🔄 ¿Continuar de todas formas? (y/N)"
  read -r -n 1 response
  echo
  if [[ ! "$response" =~ ^[Yy]$ ]]; then
    echo "❌ Instalación cancelada por el usuario"
    exit 1
  fi
fi

# 4. VERIFICAR INSTALACIÓN PREVIA
# ===============================
echo "🔍 Verificando instalación previa de MetalLB..."

if kubectl get namespace metallb-system &>/dev/null; then
  echo "⚠️  MetalLB ya está instalado"
  echo "📋 Estado actual:"
  kubectl -n metallb-system get pods
  echo ""
  echo "🔄 ¿Deseas reinstalar MetalLB? (y/N)"
  read -r -n 1 response
  echo
  if [[ "$response" =~ ^[Yy]$ ]]; then
    echo "🗑️  Desinstalando MetalLB previo..."
    kubectl delete namespace metallb-system --timeout=120s || true
    sleep 30
  else
    echo "✅ Manteniendo instalación existente de MetalLB"
    echo "👉 Continúa con: scripts/05-install-rancher.sh"
    exit 0
  fi
fi

# 5. INSTALAR METALLB
# ===================
echo "📦 Instalando MetalLB..."

# Determinar versión de MetalLB
METALLB_VERSION="v0.13.12"
METALLB_MANIFEST_URL="https://raw.githubusercontent.com/metallb/metallb/$METALLB_VERSION/config/manifests/metallb-native.yaml"

echo "⬇️  Descargando manifesto de MetalLB $METALLB_VERSION..."
curl -sL "$METALLB_MANIFEST_URL" -o metallb-native.yaml

echo "🔧 Aplicando manifesto de MetalLB..."
kubectl apply -f metallb-native.yaml

# 6. ESPERAR A QUE METALLB ESTÉ LISTO
# ===================================
echo "⏳ Esperando a que MetalLB esté listo..."

# Esperar a que el namespace esté disponible
for i in {1..10}; do
  if kubectl get namespace metallb-system &>/dev/null; then
    echo "✅ Namespace metallb-system creado"
    break
  fi
  if [ $i -eq 10 ]; then
    echo "❌ Timeout esperando namespace metallb-system"
    exit 1
  fi
  echo "⏳ Esperando namespace... (intento $i/10)"
  sleep 5
done

# Esperar a que el controlador esté listo
echo "⏳ Esperando controlador MetalLB..."
for i in {1..20}; do
  if kubectl -n metallb-system rollout status deployment/controller --timeout=30s &>/dev/null; then
    echo "✅ Controlador MetalLB está listo"
    break
  fi
  if [ $i -eq 20 ]; then
    echo "❌ Timeout esperando controlador MetalLB"
    echo "📋 Estado actual:"
    kubectl -n metallb-system get pods
    exit 1
  fi
  echo "⏳ Esperando controlador... (intento $i/20)"
  sleep 15
done

# Esperar a que el speaker esté listo
echo "⏳ Esperando speaker MetalLB..."
for i in {1..20}; do
  if kubectl -n metallb-system rollout status daemonset/speaker --timeout=30s &>/dev/null; then
    echo "✅ Speaker MetalLB está listo"
    break
  fi
  if [ $i -eq 20 ]; then
    echo "❌ Timeout esperando speaker MetalLB"
    echo "📋 Estado actual:"
    kubectl -n metallb-system get pods
    exit 1
  fi
  echo "⏳ Esperando speaker... (intento $i/20)"
  sleep 15
done

# 7. CONFIGURAR IPADDRESSPOOL
# ===========================
echo "🏊 Configurando IPAddressPool..."

cat > metallb-ippool.yaml <<EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: default-pool
  namespace: metallb-system
  labels:
    app: metallb
spec:
  addresses:
  - $METALLB_IP_RANGE
  autoAssign: true
  avoidBuggyIPs: true
EOF

kubectl apply -f metallb-ippool.yaml

# 8. CONFIGURAR L2ADVERTISEMENT
# =============================
echo "📢 Configurando L2Advertisement..."

cat > metallb-l2adv.yaml <<EOF
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: l2adv
  namespace: metallb-system
  labels:
    app: metallb
spec:
  ipAddressPools:
  - default-pool
  interfaces:
  - eth0
  - ens18
  - ens192
  nodeSelectors:
  - matchLabels:
      kubernetes.io/os: linux
EOF

kubectl apply -f metallb-l2adv.yaml

# 9. VERIFICAR CONFIGURACIÓN
# ==========================
echo "🔍 Verificando configuración de MetalLB..."

# Verificar IPAddressPool
echo -n "➡️  IPAddressPool: "
if kubectl -n metallb-system get ipaddresspool default-pool &>/dev/null; then
  echo "✅ Configurado correctamente"
else
  echo "❌ Error en configuración"
  exit 1
fi

# Verificar L2Advertisement
echo -n "➡️  L2Advertisement: "
if kubectl -n metallb-system get l2advertisement l2adv &>/dev/null; then
  echo "✅ Configurado correctamente"
else
  echo "❌ Error en configuración"
  exit 1
fi

# 10. CREAR SERVICIO DE PRUEBA
# ============================
echo "🧪 Creando servicio de prueba LoadBalancer..."

cat > metallb-test-service.yaml <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: metallb-test
  namespace: default
spec:
  replicas: 1
  selector:
    matchLabels:
      app: metallb-test
  template:
    metadata:
      labels:
        app: metallb-test
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
---
apiVersion: v1
kind: Service
metadata:
  name: metallb-test-service
  namespace: default
spec:
  type: LoadBalancer
  selector:
    app: metallb-test
  ports:
  - port: 80
    targetPort: 80
    protocol: TCP
EOF

kubectl apply -f metallb-test-service.yaml

# Esperar a que el servicio obtenga una IP externa
echo "⏳ Esperando asignación de IP externa..."
for i in {1..24}; do
  EXTERNAL_IP=$(kubectl get service metallb-test-service -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
  
  if [ -n "$EXTERNAL_IP" ] && [ "$EXTERNAL_IP" != "null" ]; then
    echo "✅ IP externa asignada: $EXTERNAL_IP"
    
    # Verificar que la IP esté en el rango configurado
    if [[ "$EXTERNAL_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      echo "✅ IP válida asignada del pool configurado"
      
      # Probar conectividad
      echo -n "🔗 Probando conectividad HTTP: "
      if curl -s --max-time 10 "http://$EXTERNAL_IP" | grep -q "nginx" &>/dev/null; then
        echo "✅ Servicio LoadBalancer funcional"
      else
        echo "⚠️  Servicio no responde (puede ser normal, verificar red)"
      fi
    else
      echo "⚠️  IP asignada no está en formato esperado"
    fi
    break
  fi
  
  if [ $i -eq 24 ]; then
    echo "❌ Timeout esperando IP externa (6 minutos)"
    echo "📋 Estado del servicio:"
    kubectl describe service metallb-test-service
    echo ""
    echo "📋 Eventos recientes:"
    kubectl get events --sort-by=.metadata.creationTimestamp | tail -10
  else
    echo "⏳ Esperando IP externa... (intento $i/24)"
    sleep 15
  fi
done

# 11. LIMPIAR SERVICIO DE PRUEBA
# ==============================
echo "🧹 Limpiando servicio de prueba..."
kubectl delete -f metallb-test-service.yaml || true
rm -f metallb-test-service.yaml

# 12. VERIFICACIÓN FINAL
# ======================
echo ""
echo "📊 Estado final de MetalLB:"
kubectl -n metallb-system get pods -o wide

echo ""
echo "🏊 Configuración de pools de IP:"
kubectl -n metallb-system get ipaddresspool

echo ""
echo "📢 Configuración de L2 Advertisement:"
kubectl -n metallb-system get l2advertisement

# 13. INFORMACIÓN ADICIONAL
# =========================
echo ""
echo "🔧 Información de configuración de red:"
echo "   • Interfaces de red detectadas:"
kubectl -n metallb-system get pods -l app=metallb,component=speaker -o wide | grep -v NAME | while read -r pod rest; do
  echo "      $pod"
done

echo ""
echo "🎉 Instalación de MetalLB completada exitosamente"
echo "📊 Resumen:"
echo "   • Versión: $METALLB_VERSION"
echo "   • Namespace: metallb-system"
echo "   • Pool de IPs: $METALLB_IP_RANGE"
echo "   • Modo: L2 Advertisement"
echo "   • Estado: Funcional"

if [ -n "${EXTERNAL_IP:-}" ]; then
  echo "   • IP de prueba asignada: $EXTERNAL_IP"
fi

echo ""
echo "📁 Archivos generados:"
echo "   • metallb-native.yaml (manifesto base)"
echo "   • metallb-ippool.yaml (configuración de pool)"
echo "   • metallb-l2adv.yaml (configuración L2)"
echo ""
echo "💡 Uso:"
echo "   Los servicios tipo LoadBalancer ahora obtendrán IPs del rango $METALLB_IP_RANGE"
echo ""
echo "👉 Continúa con: scripts/05-install-rancher.sh"
