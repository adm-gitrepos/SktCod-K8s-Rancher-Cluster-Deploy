#!/bin/bash
set -euo pipefail
trap 'echo "❌ Error en línea $LINENO durante instalación de Rancher. Revisa el log." && exit 1' ERR

# Cargar variables y funciones
[ -f .env ] && source .env || { echo "❌ Falta archivo .env"; exit 1; }
[ -f scripts/node-helpers.sh ] && source scripts/node-helpers.sh || { echo "❌ Falta archivo scripts/node-helpers.sh"; exit 1; }

LOG="logs/05-install-rancher-$(date +%F-%H%M).log"
mkdir -p logs && exec > >(tee -a "$LOG") 2>&1

echo "🚀 Iniciando instalación de Rancher..."

# 1. VALIDACIONES INICIALES
# =========================
validate_nodes_config

export PATH=$PATH:/var/lib/rancher/rke2/bin
export KUBECONFIG=/etc/rancher/rke2/rke2.yaml

# Verificar comandos requeridos
for cmd in kubectl helm; do
  if ! command -v $cmd &>/dev/null; then
    if [ "$cmd" = "helm" ]; then
      echo "⬇️  Instalando Helm..."
      curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
      chmod 700 get_helm.sh
      ./get_helm.sh
      rm -f get_helm.sh
      echo "✅ Helm instalado correctamente"
    else
      echo "❌ Falta comando: $cmd"
      echo "💡 Asegúrate de que RKE2 esté instalado correctamente"
      exit 1
    fi
  fi
done

# Verificar que el clúster esté funcionando
if ! kubectl get nodes &>/dev/null; then
  echo "❌ El clúster Kubernetes no está accesible"
  echo "💡 Ejecuta primero: scripts/02-install-cluster.sh"
  exit 1
fi

# 2. VALIDAR CONFIGURACIÓN DE RANCHER
# ===================================
echo "🔍 Validando configuración de Rancher..."

if [ -z "${RANCHER_DOMAIN:-}" ]; then
  echo "❌ RANCHER_DOMAIN no está definido en .env"
  echo "💡 Ejemplo: RANCHER_DOMAIN=rancher.midominio.com"
  exit 1
fi

if [ -z "${BOOTSTRAP_PASSWORD:-}" ]; then
  echo "❌ BOOTSTRAP_PASSWORD no está definido en .env"
  echo "💡 Ejemplo: BOOTSTRAP_PASSWORD=MiPasswordSegura123"
  exit 1
fi

echo "📊 Configuración de Rancher:"
echo "   • Dominio: $RANCHER_DOMAIN"
echo "   • Versión: ${RANCHER_VERSION:-latest}"
echo "   • Password bootstrap: ${BOOTSTRAP_PASSWORD:0:5}..."

# Validar que el dominio resuelva correctamente
echo -n "🌐 Verificando resolución DNS de $RANCHER_DOMAIN: "
if getent hosts "$RANCHER_DOMAIN" >/dev/null; then
  RESOLVED_IP=$(getent hosts "$RANCHER_DOMAIN" | awk '{print $1}')
  echo "✅ Resuelve a: $RESOLVED_IP"
else
  echo "❌ No resuelve"
  echo "💡 Configura DNS o agrega a /etc/hosts:"
  echo "   echo '$LB_IP $RANCHER_DOMAIN' >> /etc/hosts"
  exit 1
fi

# 3. VERIFICAR PREREQUISITOS DEL CLÚSTER
# ======================================
echo "🔍 Verificando prerequisitos del clúster..."

# Verificar nodos worker (donde se desplegará Rancher)
WORKER_NODES=$(get_nodes_by_type "worker")
if [ -z "$WORKER_NODES" ]; then
  echo "❌ No hay nodos worker configurados"
  echo "💡 Rancher necesita nodos worker para desplegarse"
  exit 1
fi

WORKER_COUNT=$(echo "$WORKER_NODES" | wc -l)
echo "📊 Nodos worker disponibles: $WORKER_COUNT"

# Verificar que los nodos worker estén listos
echo "$WORKER_NODES" | while read -r hostname; do
  if [ -n "$hostname" ]; then
    echo -n "➡️  Verificando $hostname: "
    if kubectl get node "$hostname" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' | grep -q "True"; then
      echo "✅ Listo"
    else
      echo "❌ No está listo"
      exit 1
    fi
  fi
done

# Verificar MetalLB
echo -n "🌐 Verificando MetalLB: "
if kubectl -n metallb-system get pods | grep -q "Running"; then
  echo "✅ MetalLB está ejecutándose"
else
  echo "❌ MetalLB no está funcionando"
  echo "💡 Ejecuta primero: scripts/04-install-metallb.sh"
  exit 1
fi

# 4. VERIFICAR INSTALACIÓN PREVIA
# ===============================
echo "🔍 Verificando instalación previa de Rancher..."

if kubectl get namespace cattle-system &>/dev/null; then
  echo "⚠️  Rancher ya está instalado"
  echo "📋 Estado actual:"
  kubectl -n cattle-system get pods
  echo ""
  echo "🔄 ¿Deseas reinstalar Rancher? ESTO ELIMINARÁ TODOS LOS DATOS. (y/N)"
  read -r -n 1 response
  echo
  if [[ "$response" =~ ^[Yy]$ ]]; then
    echo "🗑️  Desinstalando Rancher previo..."
    helm uninstall rancher -n cattle-system || true
    kubectl delete namespace cattle-system --timeout=180s || true
    sleep 30
  else
    echo "✅ Manteniendo instalación existente de Rancher"
    echo "👉 Continúa con: scripts/06-verify-installation.sh"
    exit 0
  fi
fi

# 5. CREAR NAMESPACE Y CONFIGURAR HELM
# ====================================
echo "📁 Preparando namespaces y repositorios Helm..."

# Crear namespaces
kubectl create namespace cattle-system || true
kubectl create namespace cert-manager || true

# Configurar repositorios Helm
echo "📥 Configurando repositorios Helm..."

# Repositorio de Rancher
if ! helm repo list | grep -q "rancher-latest"; then
  helm repo add rancher-latest https://releases.rancher.com/server-charts/latest
  echo "✅ Repositorio rancher-latest agregado"
else
  echo "✅ Repositorio rancher-latest ya existe"
fi

# Repositorio de Jetstack (cert-manager)
if ! helm repo list | grep -q "jetstack"; then
  helm repo add jetstack https://charts.jetstack.io
  echo "✅ Repositorio jetstack agregado"
else
  echo "✅ Repositorio jetstack ya existe"
fi

# Actualizar repositorios
echo "🔄 Actualizando repositorios Helm..."
helm repo update

# 6. INSTALAR CERT-MANAGER
# ========================
echo "🔐 Instalando cert-manager..."

# Verificar si cert-manager ya está instalado
if helm list -n cert-manager | grep -q "cert-manager"; then
  echo "✅ cert-manager ya está instalado"
else
  CERT_MANAGER_VERSION="v1.14.4"
  
  echo "⬇️  Instalando cert-manager $CERT_MANAGER_VERSION..."
  helm upgrade --install cert-manager jetstack/cert-manager \
    --namespace cert-manager \
    --create-namespace \
    --version "$CERT_MANAGER_VERSION" \
    --set installCRDs=true \
    --set global.leaderElection.namespace=cert-manager \
    --wait --timeout=10m
fi

# Esperar a que cert-manager esté listo
echo "⏳ Esperando que cert-manager esté listo..."
kubectl -n cert-manager rollout status deployment/cert-manager --timeout=300s
kubectl -n cert-manager rollout status deployment/cert-manager-cainjector --timeout=300s
kubectl -n cert-manager rollout status deployment/cert-manager-webhook --timeout=300s

echo "✅ cert-manager está listo"

# 7. CONFIGURAR VALORES PARA RANCHER
# ==================================
echo "📝 Configurando valores para Rancher..."

# Crear archivo de valores personalizado
cat > rancher-values.yaml <<EOF
# Configuración de Rancher para HA
hostname: $RANCHER_DOMAIN
replicas: 3

# Configuración de bootstrap
bootstrapPassword: "$BOOTSTRAP_PASSWORD"

# Configuración de TLS
ingress:
  tls:
    source: letsEncrypt

letsEncrypt:
  email: admin@$RANCHER_DOMAIN
  environment: production
  ingress:
    class: nginx

# Configuración de recursos
resources:
  limits:
    cpu: 1000m
    memory: 2Gi
  requests:
    cpu: 500m
    memory: 1Gi

# Configuración de nodos
nodeSelector:
  rke2-rancher: "true"

tolerations:
- key: "node-role.kubernetes.io/worker"
  operator: "Equal"
  value: "true"
  effect: "NoSchedule"

# Configuración de anti-afinidad
antiAffinity: preferred

# Configuración adicional
addLocal: "auto"
useBundledSystemChart: true

# Configuración de audit logs
auditLog:
  level: 1
  destination: hostPath
  hostPath: /var/log/rancher/audit.log

# Configuración de proxy
systemDefaultRegistry: ""
useBundledSystemChart: true
EOF

# 8. INSTALAR RANCHER
# ===================
echo "🚀 Instalando Rancher..."

RANCHER_VERSION_PARAM=""
if [ -n "${RANCHER_VERSION:-}" ]; then
  RANCHER_VERSION_PARAM="--version $RANCHER_VERSION"
  echo "📦 Instalando Rancher versión: $RANCHER_VERSION"
else
  echo "📦 Instalando Rancher versión: latest"
fi

helm upgrade --install rancher rancher-latest/rancher \
  --namespace cattle-system \
  --values rancher-values.yaml \
  $RANCHER_VERSION_PARAM \
  --wait --timeout=15m

# 9. CREAR SERVICIO LOADBALANCER
# ==============================
echo "🌐 Creando servicio LoadBalancer para Rancher..."

cat > rancher-loadbalancer.yaml <<EOF
apiVersion: v1
kind: Service
metadata:
  name: rancher-loadbalancer
  namespace: cattle-system
  labels:
    app: rancher
    chart: rancher
spec:
  type: LoadBalancer
  selector:
    app: rancher
  ports:
  - name: http
    port: 80
    targetPort: 80
    protocol: TCP
  - name: https
    port: 443
    targetPort: 443
    protocol: TCP
  loadBalancerIP: $LB_IP
EOF

kubectl apply -f rancher-loadbalancer.yaml

# 10. MONITOREAR DESPLIEGUE
# =========================
echo "⏳ Monitoreando despliegue de Rancher..."

# Esperar a que los pods estén listos
for i in {1..30}; do
  READY_PODS=$(kubectl -n cattle-system get pods -l app=rancher --no-headers 2>/dev/null | grep -c "Running" || echo "0")
  TOTAL_PODS=$(kubectl -n cattle-system get pods -l app=rancher --no-headers 2>/dev/null | wc -l || echo "0")
  
  echo "📊 Estado de pods Rancher: $READY_PODS/$TOTAL_PODS ejecutándose"
  
  if [ "$READY_PODS" -eq 3 ] && [ "$TOTAL_PODS" -eq 3 ]; then
    echo "✅ Todos los pods de Rancher están ejecutándose"
    break
  fi
  
  if [ $i -eq 30 ]; then
    echo "❌ Timeout esperando pods de Rancher (15 minutos)"
    echo "📋 Estado actual:"
    kubectl -n cattle-system get pods -l app=rancher
    exit 1
  fi
  
  echo "⏳ Esperando pods de Rancher... (verificación $i/30)"
  sleep 30
done

# Esperar a que el LoadBalancer tenga IP externa
echo "⏳ Esperando asignación de IP externa..."
for i in {1..20}; do
  EXTERNAL_IP=$(kubectl -n cattle-system get service rancher-loadbalancer -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
  
  if [ -n "$EXTERNAL_IP" ] && [ "$EXTERNAL_IP" != "null" ]; then
    echo "✅ IP externa asignada: $EXTERNAL_IP"
    break
  fi
  
  if [ $i -eq 20 ]; then
    echo "⚠️  No se asignó IP externa después de 10 minutos"
    echo "📋 Estado del servicio:"
    kubectl -n cattle-system describe service rancher-loadbalancer
  else
    echo "⏳ Esperando IP externa... (intento $i/20)"
    sleep 30
  fi
done

# 11. VERIFICAR ACCESO HTTPS
# ==========================
echo "🔐 Verificando acceso HTTPS a Rancher..."

for i in {1..20}; do
  echo -n "🌐 Probando https://$RANCHER_DOMAIN (intento $i/20): "
  
  if curl -k --max-time 10 -s -I "https://$RANCHER_DOMAIN" | grep -q "200 OK"; then
    echo "✅ Rancher responde correctamente"
    break
  elif curl -k --max-time 10 -s -I "https://$RANCHER_DOMAIN" | grep -q "503"; then
    echo "⏳ Rancher iniciando (503)"
  else
    echo "❌ Sin respuesta"
  fi
  
  if [ $i -eq 20 ]; then
    echo "⚠️  Rancher no responde después de 10 minutos"
    echo "💡 Verifica:"
    echo "   • DNS: $RANCHER_DOMAIN debe resolver a $LB_IP"
    echo "   • LoadBalancer: IP externa asignada"
    echo "   • Certificados: Let's Encrypt configurado"
  else
    sleep 30
  fi
done

# 12. OBTENER CREDENCIALES
# ========================
echo "🔐 Obteniendo credenciales de Rancher..."

# Esperar a que el secret de bootstrap esté disponible
for i in {1..10}; do
  if kubectl -n cattle-system get secret bootstrap-secret &>/dev/null; then
    PASSWORD=$(kubectl -n cattle-system get secret bootstrap-secret -o jsonpath="{.data.bootstrapPassword}" | base64 -d)
    echo "✅ Credenciales obtenidas"
    break
  fi
  
  if [ $i -eq 10 ]; then
    echo "⚠️  No se pudo obtener el secret de bootstrap"
    PASSWORD="$BOOTSTRAP_PASSWORD"
  else
    echo "⏳ Esperando secret de bootstrap... (intento $i/10)"
    sleep 10
  fi
done

# 13. CONFIGURAR INGRESS ADICIONAL (OPCIONAL)
# ===========================================
echo "🌐 Configurando ingress adicional..."

cat > rancher-ingress.yaml <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: rancher-ingress
  namespace: cattle-system
  annotations:
    nginx.ingress.kubernetes.io/proxy-connect-timeout: "30"
    nginx.ingress.kubernetes.io/proxy-read-timeout: "1800"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "1800"
    nginx.ingress.kubernetes.io/backend-protocol: "HTTPS"
spec:
  tls:
  - hosts:
    - $RANCHER_DOMAIN
    secretName: tls-rancher-ingress
  rules:
  - host: $RANCHER_DOMAIN
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: rancher
            port:
              number: 443
EOF

kubectl apply -f rancher-ingress.yaml

# 14. VERIFICACIÓN FINAL
# ======================
echo ""
echo "📊 Estado final de Rancher:"
kubectl -n cattle-system get pods -l app=rancher

echo ""
echo "🌐 Servicios de Rancher:"
kubectl -n cattle-system get services

echo ""
echo "🔐 Certificados:"
kubectl -n cattle-system get certificates

echo ""
echo "📋 Ingress:"
kubectl -n cattle-system get ingress

echo ""
echo "🎉 Instalación de Rancher completada exitosamente"
echo "📊 Resumen:"
echo "   • URL: https://$RANCHER_DOMAIN"
echo "   • Usuario: admin"
echo "   • Contraseña: $PASSWORD"
echo "   • Versión: ${RANCHER_VERSION:-latest}"
echo "   • Replicas: 3 (Alta Disponibilidad)"
echo "   • TLS: Let's Encrypt (Producción)"

if [ -n "${EXTERNAL_IP:-}" ]; then
  echo "   • LoadBalancer IP: $EXTERNAL_IP"
fi

echo ""
echo "📁 Archivos generados:"
echo "   • rancher-values.yaml (configuración Helm)"
echo "   • rancher-loadbalancer.yaml (servicio LoadBalancer)"
echo "   • rancher-ingress.yaml (ingress adicional)"
echo ""
echo "💡 Próximos pasos:"
echo "   1. Accede a https://$RANCHER_DOMAIN"
echo "   2. Inicia sesión con admin / $PASSWORD"
echo "   3. Configura tu primer proyecto/namespace"
echo ""
echo "👉 Continúa con: scripts/06-verify-installation.sh"
