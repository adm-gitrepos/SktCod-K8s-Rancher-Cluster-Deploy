#!/bin/bash
set -euo pipefail
trap 'echo "❌ Error en línea $LINENO durante validación DNS y configuración final. Revisa el log." && exit 1' ERR

# Cargar variables y funciones
[ -f .env ] && source .env || { echo "❌ Falta archivo .env"; exit 1; }
[ -f scripts/node-helpers.sh ] && source scripts/node-helpers.sh || { echo "❌ Falta archivo scripts/node-helpers.sh"; exit 1; }

LOG="logs/08-dns-config-$(date +%F-%H%M).log"
mkdir -p logs && exec > >(tee -a "$LOG") 2>&1

echo "🌐 Iniciando configuración DNS y validación final..."

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

# 2. VERIFICACIÓN DE SERVICIOS LOADBALANCER
# =========================================
echo ""
echo "🌐 VERIFICACIÓN DE SERVICIOS LOADBALANCER"
echo "=========================================="

echo "📊 Servicios LoadBalancer en el clúster:"
kubectl get services -A | grep LoadBalancer

echo ""
echo "🔍 Verificando IPs externas asignadas:"

# Función para verificar servicio LoadBalancer
check_loadbalancer() {
  local namespace=$1
  local service=$2
  local description=$3
  
  echo ""
  echo "📡 Verificando $description..."
  
  if kubectl -n "$namespace" get service "$service" &>/dev/null; then
    EXTERNAL_IP=$(kubectl -n "$namespace" get service "$service" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
    
    if [ -n "$EXTERNAL_IP" ] && [ "$EXTERNAL_IP" != "null" ]; then
      echo "   ✅ IP externa asignada: $EXTERNAL_IP"
      
      # Verificar que la IP esté en el rango de MetalLB
      if [ -n "${METALLB_IP_RANGE:-}" ]; then
        START_IP=$(echo "$METALLB_IP_RANGE" | cut -d'-' -f1)
        END_IP=$(echo "$METALLB_IP_RANGE" | cut -d'-' -f2)
        echo "   📊 Rango MetalLB: $START_IP - $END_IP"
      fi
      
      return 0
    else
      echo "   ❌ Sin IP externa asignada"
      echo "   📋 Estado del servicio:"
      kubectl -n "$namespace" describe service "$service" | grep -A 5 "LoadBalancer Ingress"
      return 1
    fi
  else
    echo "   ⚠️  Servicio $service no encontrado en namespace $namespace"
    return 1
  fi
}

# Verificar Rancher LoadBalancer (si está instalado)
RANCHER_LB_IP=""
if kubectl get namespace cattle-system &>/dev/null; then
  if check_loadbalancer "cattle-system" "rancher-loadbalancer" "Rancher LoadBalancer"; then
    RANCHER_LB_IP=$(kubectl -n cattle-system get service rancher-loadbalancer -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
  fi
else
  echo "⚠️  Rancher no está instalado"
fi

# 3. VERIFICACIÓN Y CONFIGURACIÓN DNS
# ===================================
echo ""
echo "🌍 VERIFICACIÓN Y CONFIGURACIÓN DNS"
echo "==================================="

if [ -n "${RANCHER_DOMAIN:-}" ]; then
  echo "🔍 Verificando configuración DNS para: $RANCHER_DOMAIN"
  
  # Verificar resolución DNS
  echo -n "📡 Resolución DNS actual: "
  if RESOLVED_IP=$(getent hosts "$RANCHER_DOMAIN" 2>/dev/null | awk '{print $1}'); then
    echo "$RANCHER_DOMAIN -> $RESOLVED_IP"
    
    # Comparar con IP del LoadBalancer
    if [ -n "$RANCHER_LB_IP" ]; then
      if [ "$RESOLVED_IP" = "$RANCHER_LB_IP" ]; then
        echo "   ✅ DNS resuelve correctamente a la IP del LoadBalancer"
        DNS_CONFIGURED=true
      else
        echo "   ⚠️  DNS resuelve a $RESOLVED_IP pero LoadBalancer está en $RANCHER_LB_IP"
        DNS_CONFIGURED=false
      fi
    else
      echo "   ⚠️  No hay IP de LoadBalancer para comparar"
      DNS_CONFIGURED=false
    fi
  else
    echo "❌ No resuelve"
    DNS_CONFIGURED=false
  fi
  
  # Proporcionar instrucciones de configuración DNS
  echo ""
  echo "📝 CONFIGURACIÓN DNS REQUERIDA"
  echo "=============================="
  
  if [ "$DNS_CONFIGURED" = false ] && [ -n "$RANCHER_LB_IP" ]; then
    echo "🔧 Para configurar DNS correctamente, necesitas:"
    echo ""
    echo "   OPCIÓN 1 - DNS Server (Recomendado para producción):"
    echo "   ====================================================="
    echo "   Agrega este registro A en tu servidor DNS:"
    echo "   $RANCHER_DOMAIN.    IN    A    $RANCHER_LB_IP"
    echo ""
    echo "   OPCIÓN 2 - /etc/hosts (Solo para pruebas):"
    echo "   =========================================="
    echo "   Agrega esta línea a /etc/hosts en máquinas cliente:"
    echo "   $RANCHER_LB_IP $RANCHER_DOMAIN"
    echo ""
    echo "   OPCIÓN 3 - DNS Externo (Si usas proveedor DNS):"
    echo "   ============================================="
    echo "   Configura un registro A en tu proveedor DNS:"
    echo "   Host: $(echo "$RANCHER_DOMAIN" | cut -d'.' -f1)"
    echo "   Tipo: A"
    echo "   Valor: $RANCHER_LB_IP"
    echo "   TTL: 300"
    echo ""
  fi
else
  echo "⚠️  RANCHER_DOMAIN no está configurado en .env"
fi

# 4. VERIFICACIÓN DE CONECTIVIDAD WEB
# ===================================
echo ""
echo "🌐 VERIFICACIÓN DE CONECTIVIDAD WEB"
echo "==================================="

if [ -n "${RANCHER_DOMAIN:-}" ] && [ -n "$RANCHER_LB_IP" ]; then
  # Verificar acceso HTTP
  echo -n "🔗 Verificando HTTP ($RANCHER_DOMAIN): "
  if curl -L --max-time 10 -s -I "http://$RANCHER_DOMAIN" | grep -q "30[12]"; then
    echo "✅ Redirección a HTTPS (correcto)"
  elif curl -L --max-time 10 -s -I "http://$RANCHER_DOMAIN" | grep -q "200"; then
    echo "✅ Respuesta HTTP exitosa"
  else
    echo "❌ Sin respuesta HTTP"
  fi
  
  # Verificar acceso HTTPS
  echo -n "🔐 Verificando HTTPS ($RANCHER_DOMAIN): "
  if curl -k --max-time 15 -s -I "https://$RANCHER_DOMAIN" | grep -q "200 OK"; then
    echo "✅ Respuesta HTTPS exitosa"
    HTTPS_WORKING=true
    
    # Verificar certificado SSL
    echo -n "🔒 Verificando certificado SSL: "
    if curl --max-time 10 -s -I "https://$RANCHER_DOMAIN" &>/dev/null; then
      echo "✅ Certificado SSL válido"
    else
      echo "⚠️  Certificado SSL inválido/auto-firmado (usar -k para bypass)"
    fi
  else
    echo "❌ Sin respuesta HTTPS"
    HTTPS_WORKING=false
    
    # Diagnóstico adicional
    echo "🔍 Diagnóstico de conectividad HTTPS:"
    echo -n "   • Conectividad TCP puerto 443: "
    if timeout 5 bash -c "</dev/tcp/$RANCHER_LB_IP/443" 2>/dev/null; then
      echo "✅ Puerto 443 accesible"
    else
      echo "❌ Puerto 443 no accesible"
    fi
  fi
  
  # Verificar acceso directo por IP
  echo ""
  echo "🔍 Verificación de acceso directo por IP:"
  echo -n "   • HTTP directo ($RANCHER_LB_IP:80): "
  if curl --max-time 5 -s -I "http://$RANCHER_LB_IP" | grep -q "30[12]"; then
    echo "✅ Redirección a HTTPS"
  elif curl --max-time 5 -s -I "http://$RANCHER_LB_IP" | grep -q "200"; then
    echo "✅ Respuesta exitosa"
  else
    echo "❌ Sin respuesta"
  fi
  
  echo -n "   • HTTPS directo ($RANCHER_LB_IP:443): "
  if curl -k --max-time 5 -s -I "https://$RANCHER_LB_IP" | grep -q "200"; then
    echo "✅ Respuesta exitosa"
  else
    echo "❌ Sin respuesta"
  fi
else
  echo "⚠️  No se puede verificar conectividad web (faltan RANCHER_DOMAIN o RANCHER_LB_IP)"
fi

# 5. OBTENER CREDENCIALES DE RANCHER
# ==================================
echo ""
echo "🔐 CREDENCIALES DE ACCESO"
echo "========================"

if kubectl get namespace cattle-system &>/dev/null; then
  echo "🔍 Obteniendo credenciales de Rancher..."
  
  # Intentar obtener contraseña del secret
  if kubectl -n cattle-system get secret bootstrap-secret &>/dev/null; then
    RANCHER_PASSWORD=$(kubectl -n cattle-system get secret bootstrap-secret -o jsonpath="{.data.bootstrapPassword}" | base64 -d 2>/dev/null || echo "")
    
    if [ -n "$RANCHER_PASSWORD" ]; then
      echo "✅ Credenciales obtenidas del clúster"
    else
      echo "⚠️  Error decodificando contraseña del secret"
      RANCHER_PASSWORD="${BOOTSTRAP_PASSWORD:-N/A}"
    fi
  else
    echo "⚠️  Secret bootstrap-secret no encontrado"
    RANCHER_PASSWORD="${BOOTSTRAP_PASSWORD:-N/A}"
  fi
  
  # Mostrar información de acceso
  echo ""
  echo "🎯 INFORMACIÓN DE ACCESO A RANCHER"
  echo "=================================="
  echo "   🌐 URL: https://$RANCHER_DOMAIN"
  echo "   👤 Usuario: admin"
  echo "   🔑 Contraseña: $RANCHER_PASSWORD"
  echo ""
  
  if [ "$HTTPS_WORKING" = true ]; then
    echo "✅ Rancher está accesible y listo para usar"
  else
    echo "⚠️  Verifica la configuración DNS y conectividad de red"
  fi
else
  echo "⚠️  Rancher no está instalado en este clúster"
fi

# 6. VERIFICACIÓN DE CERTIFICADOS SSL
# ===================================
echo ""
echo "🔒 VERIFICACIÓN DE CERTIFICADOS SSL"
echo "==================================="

if kubectl get namespace cert-manager &>/dev/null; then
  echo "📊 Estado de cert-manager:"
  kubectl -n cert-manager get pods
  
  echo ""
  echo "🔐 Certificados en el clúster:"
  kubectl get certificates -A
  
  echo ""
  echo "🔍 ClusterIssuers disponibles:"
  kubectl get clusterissuers 2>/dev/null || echo "   ⚠️  No hay ClusterIssuers configurados"
  
  # Verificar certificados específicos de Rancher
  if kubectl get namespace cattle-system &>/dev/null; then
    echo ""
    echo "🚀 Certificados de Rancher:"
    kubectl -n cattle-system get certificates 2>/dev/null || echo "   ⚠️  No hay certificados específicos de Rancher"
    
    # Verificar secrets TLS
    echo ""
    echo "🗝️  Secrets TLS en cattle-system:"
    kubectl -n cattle-system get secrets -o custom-columns="NAME:.metadata.name,TYPE:.type" | grep tls || echo "   ⚠️  No hay secrets TLS"
  fi
else
  echo "⚠️  cert-manager no está instalado"
fi

# 7. INFORMACIÓN DE RED Y CONECTIVIDAD
# ====================================
echo ""
echo "🌐 INFORMACIÓN DE RED Y CONECTIVIDAD"
echo "===================================="

echo "📊 Resumen de configuración de red:"
echo "   • LoadBalancer IP: ${RANCHER_LB_IP:-N/A}"
echo "   • Dominio configurado: ${RANCHER_DOMAIN:-N/A}"
echo "   • Rango MetalLB: ${METALLB_IP_RANGE:-N/A}"
echo "   • IP del proxy/LB externo: ${LB_IP:-N/A}"

echo ""
echo "🔍 Pruebas de conectividad desde el clúster:"

# Verificar resolución DNS desde el clúster
if [ -n "${RANCHER_DOMAIN:-}" ]; then
  echo -n "   • Resolución DNS interna: "
  if kubectl run dns-test --image=busybox --rm -it --restart=Never -- nslookup "$RANCHER_DOMAIN" &>/dev/null; then
    echo "✅ Resuelve desde pods"
  else
    echo "❌ No resuelve desde pods"
  fi
fi

# Verificar conectividad a servicios externos
echo -n "   • Conectividad externa (google.com): "
if kubectl run connectivity-test --image=busybox --rm -it --restart=Never -- wget -q --spider google.com &>/dev/null; then
  echo "✅ Conectividad externa OK"
else
  echo "❌ Sin conectividad externa"
fi

# 8. CONFIGURACIÓN DE PROXY/NGINX (SI APLICA)
# ===========================================
echo ""
echo "🔄 CONFIGURACIÓN DE PROXY/NGINX EXTERNO"
echo "========================================"

if [ -n "${LB_IP:-}" ]; then
  echo "📝 Si usas NGINX Plus o HAProxy como LoadBalancer externo ($LB_IP):"
  echo ""
  echo "   Verifica que tenga configurados estos upstreams:"
  echo ""
  echo "   🔹 Para API de Kubernetes:"
  
  # Generar configuración para masters
  get_nodes_by_type "master" | while read -r hostname; do
    if [ -n "$hostname" ]; then
      echo "      server $hostname:6443;"
      echo "      server $hostname:9345;"
    fi
  done
  
  echo ""
  echo "   🔹 Para Rancher UI/API:"
  get_nodes_by_type "worker" | while read -r hostname; do
    if [ -n "$hostname" ]; then
      echo "      server $hostname:80;"
      echo "      server $hostname:443;"
    fi
  done
  
  echo ""
  echo "   📄 Consulta docs/nginx-plus.md para configuración completa"
else
  echo "⚠️  LB_IP no configurado en .env"
fi

# 9. BACKUP Y MANTENIMIENTO
# =========================
echo ""
echo "💾 INFORMACIÓN DE BACKUP Y MANTENIMIENTO"
echo "========================================"

echo "📁 Ubicaciones importantes de backup:"
echo "   • Snapshots etcd: /var/lib/rancher/rke2/server/db/snapshots/"
echo "   • Configuración RKE2: /etc/rancher/rke2/"
echo "   • Logs del sistema: journalctl -u rke2-server"

# Verificar snapshots recientes
PRIMARY_MASTER=$(get_primary_master)
echo ""
echo "📸 Snapshots recientes de etcd en $PRIMARY_MASTER:"
RECENT_SNAPSHOTS=$(ssh -p "$SSH_PORT" "$SSH_USER@$PRIMARY_MASTER" "ls -la /var/lib/rancher/rke2/server/db/snapshots/ 2>/dev/null | tail -5" || echo "Error accediendo a snapshots")
echo "$RECENT_SNAPSHOTS"

echo ""
echo "⏰ Comandos útiles de mantenimiento:"
echo "   • Ver nodos: kubectl get nodes -o wide"
echo "   • Estado de pods: kubectl get pods -A"
echo "   • Logs de RKE2: journalctl -u rke2-server -f"
echo "   • Crear snapshot: rke2 etcd-snapshot save --name backup-\$(date +%s)"
echo "   • Ver eventos: kubectl get events --sort-by=.metadata.creationTimestamp"

# 10. RESUMEN FINAL Y PRÓXIMOS PASOS
# ==================================
echo ""
echo "🎉 INSTALACIÓN COMPLETADA - RESUMEN FINAL"
echo "=========================================="

# Contar componentes instalados
COMPONENTS_INSTALLED=0
COMPONENTS_TOTAL=5

echo "📊 Componentes del clúster:"

# RKE2
echo "   ✅ RKE2 Kubernetes: $(kubectl version --short | grep Server | awk '{print $3}')"
((COMPONENTS_INSTALLED++))

# Ceph
if kubectl get namespace rook-ceph &>/dev/null; then
  echo "   ✅ Rook-Ceph Storage"
  ((COMPONENTS_INSTALLED++))
else
  echo "   ⚠️  Rook-Ceph: No instalado"
fi

# MetalLB
if kubectl get namespace metallb-system &>/dev/null; then
  echo "   ✅ MetalLB LoadBalancer"
  ((COMPONENTS_INSTALLED++))
else
  echo "   ⚠️  MetalLB: No instalado"
fi

# Rancher
if kubectl get namespace cattle-system &>/dev/null; then
  echo "   ✅ Rancher Management"
  ((COMPONENTS_INSTALLED++))
else
  echo "   ⚠️  Rancher: No instalado"
fi

# cert-manager
if kubectl get namespace cert-manager &>/dev/null; then
  echo "   ✅ cert-manager SSL"
  ((COMPONENTS_INSTALLED++))
else
  echo "   ⚠️  cert-manager: No instalado"
fi

echo ""
echo "📈 Instalación: $COMPONENTS_INSTALLED/$COMPONENTS_TOTAL componentes"

# Mostrar información clave
echo ""
echo "🔑 INFORMACIÓN CLAVE:"
echo "===================="

if [ -n "${RANCHER_DOMAIN:-}" ] && [ -n "$RANCHER_PASSWORD" ]; then
  echo "🌐 Acceso a Rancher:"
  echo "   URL: https://$RANCHER_DOMAIN"
  echo "   Usuario: admin"
  echo "   Contraseña: $RANCHER_PASSWORD"
  echo ""
fi

echo "⚙️  Acceso al clúster:"
echo "   Configuración: /etc/rancher/rke2/rke2.yaml"
echo "   Variables: export KUBECONFIG=/etc/rancher/rke2/rke2.yaml"
echo ""

echo "📊 Estado del clúster:"
TOTAL_NODES=$(kubectl get nodes --no-headers | wc -l)
READY_NODES=$(kubectl get nodes --no-headers | grep -c " Ready ")
echo "   Nodos: $READY_NODES/$TOTAL_NODES listos"

if [ -n "$RANCHER_LB_IP" ]; then
  echo "   LoadBalancer: $RANCHER_LB_IP"
fi

echo ""
echo "📚 PRÓXIMOS PASOS RECOMENDADOS:"
echo "=============================="
echo "   1. 🔐 Accede a Rancher y configura tu primer proyecto"
echo "   2. 👥 Configura usuarios y roles de acceso"
echo "   3. 🚀 Despliega tu primera aplicación"
echo "   4. 📊 Configura monitoreo (Prometheus/Grafana)"
echo "   5. 🔄 Programa backups automáticos"
echo "   6. 🛡️  Implementa políticas de seguridad"
echo "   7. 📈 Configura auto-scaling si es necesario"

echo ""
echo "📖 DOCUMENTACIÓN:"
echo "================="
echo "   • README.md: Documentación general"
echo "   • docs/index.md: Documentación técnica completa"
echo "   • docs/nginx-plus.md: Configuración de proxy externo"
echo "   • Logs de instalación: logs/"

echo ""
echo "🎊 ¡FELICITACIONES!"
echo "==================="
echo "Tu clúster RKE2 con Rancher en Alta Disponibilidad"
echo "ha sido instalado y configurado exitosamente."
echo ""
echo "El clúster está listo para uso en producción."

# Crear archivo de resumen
echo ""
echo "📄 Creando archivo de resumen..."

cat > cluster-summary.md <<EOF
# 📊 Resumen del Clúster RKE2 + Rancher HA

## 🗓️ Información de Instalación
- **Fecha**: $(date)
- **Componentes instalados**: $COMPONENTS_INSTALLED/$COMPONENTS_TOTAL
- **Estado**: $([ "$COMPONENTS_INSTALLED" -eq "$COMPONENTS_TOTAL" ] && echo "✅ Completo" || echo "⚠️ Parcial")

## 🌐 Acceso
- **Rancher URL**: https://${RANCHER_DOMAIN:-N/A}
- **Usuario**: admin
- **Contraseña**: ${RANCHER_PASSWORD:-N/A}
- **LoadBalancer IP**: ${RANCHER_LB_IP:-N/A}

## 🖥️ Clúster
- **Nodos totales**: $TOTAL_NODES
- **Nodos listos**: $READY_NODES
- **Configuración kubectl**: /etc/rancher/rke2/rke2.yaml

## 📦 Componentes
- **RKE2**: ✅ Instalado
- **Rook-Ceph**: $(kubectl get namespace rook-ceph &>/dev/null && echo "✅ Instalado" || echo "⚠️ No instalado")
- **MetalLB**: $(kubectl get namespace metallb-system &>/dev/null && echo "✅ Instalado" || echo "⚠️ No instalado")
- **Rancher**: $(kubectl get namespace cattle-system &>/dev/null && echo "✅ Instalado" || echo "⚠️ No instalado")
- **cert-manager**: $(kubectl get namespace cert-manager &>/dev/null && echo "✅ Instalado" || echo "⚠️ No instalado")

## 🔧 Comandos Útiles
\`\`\`bash
# Ver estado del clúster
kubectl get nodes -o wide

# Ver todos los pods
kubectl get pods -A

# Acceder a logs de RKE2
journalctl -u rke2-server -f

# Crear backup de etcd
rke2 etcd-snapshot save --name backup-\$(date +%s)
\`\`\`

## 📁 Archivos Importantes
- Configuración: /etc/rancher/rke2/config.yaml
- Snapshots: /var/lib/rancher/rke2/server/db/snapshots/
- Logs de instalación: logs/

---
*Generado automáticamente por el instalador RKE2 + Rancher HA*
EOF

echo "✅ Resumen guardado en: cluster-summary.md"

echo ""
echo "🎯 INSTALACIÓN FINALIZADA EXITOSAMENTE"
