#!/bin/bash
set -euo pipefail
trap 'echo "❌ Error en línea $LINENO del script de prerequisitos. Verifica el entorno antes de continuar." && exit 1' ERR

# Cargar variables
[ -f .env ] && source .env || { echo "❌ Falta archivo .env. Copia .env.example a .env y configúralo."; exit 1; }

LOG="logs/00-check-prereqs-$(date +%F-%H%M).log"
mkdir -p logs && exec > >(tee -a "$LOG") 2>&1

echo "🔍 Iniciando verificación de prerequisitos..."

# 1. VERIFICAR E INSTALAR PAQUETES REQUERIDOS
# ===========================================
echo "📦 Verificando e instalando paquetes requeridos..."
REQUIRED_PACKAGES=(curl wget jq tar sshpass)
MISSING_PACKAGES=()

for pkg in "${REQUIRED_PACKAGES[@]}"; do
  if rpm -q $pkg &>/dev/null; then
    echo "✅ $pkg ya instalado"
  else
    echo "⚠️  Falta: $pkg"
    MISSING_PACKAGES+=($pkg)
  fi
done

# Instalar paquetes faltantes automáticamente
if [ ${#MISSING_PACKAGES[@]} -gt 0 ]; then
  echo "🔧 Instalando paquetes faltantes: ${MISSING_PACKAGES[*]}"
  if command -v yum &>/dev/null; then
    yum install -y "${MISSING_PACKAGES[@]}" || {
      echo "❌ Error instalando paquetes con yum. Instálalos manualmente:"
      echo "   yum install -y ${MISSING_PACKAGES[*]}"
      exit 1
    }
  elif command -v dnf &>/dev/null; then
    dnf install -y "${MISSING_PACKAGES[@]}" || {
      echo "❌ Error instalando paquetes con dnf. Instálalos manualmente:"
      echo "   dnf install -y ${MISSING_PACKAGES[*]}"
      exit 1
    }
  elif command -v apt-get &>/dev/null; then
    apt-get update && apt-get install -y "${MISSING_PACKAGES[@]}" || {
      echo "❌ Error instalando paquetes con apt-get. Instálalos manualmente:"
      echo "   apt-get install -y ${MISSING_PACKAGES[*]}"
      exit 1
    }
  else
    echo "❌ No se encontró gestor de paquetes (yum/dnf/apt-get). Instala manualmente:"
    echo "   ${MISSING_PACKAGES[*]}"
    exit 1
  fi
  echo "✅ Paquetes instalados correctamente"
fi

# Cargar funciones helper DESPUÉS de asegurar que jq esté instalado
[ -f scripts/node-helpers.sh ] && source scripts/node-helpers.sh || { 
  echo "❌ Falta archivo scripts/node-helpers.sh"
  echo "💡 Asegúrate de que existe el archivo con las funciones helper"
  exit 1
}

# 2. VALIDAR CONFIGURACIÓN DE NODOS
# =================================
echo "🏗️  Validando configuración de nodos..."
validate_nodes_config

# Mostrar resumen de nodos configurados
show_nodes_summary

# 3. VALIDAR ROOT_PASSWORD
# =========================
if [ -z "${ROOT_PASSWORD:-}" ]; then
  echo "❌ Falta definir ROOT_PASSWORD en el archivo .env"
  exit 1
fi
echo "✅ ROOT_PASSWORD configurado"

# 4. VALIDAR DNS DE RANCHER
# =========================
echo "🌐 Verificando resolución DNS de $RANCHER_DOMAIN..."
if getent hosts "$RANCHER_DOMAIN" >/dev/null; then
  RESOLVED_IP=$(getent hosts "$RANCHER_DOMAIN" | awk '{print $1}')
  echo "✅ $RANCHER_DOMAIN resuelve a: $RESOLVED_IP"
else
  echo "❌ El dominio $RANCHER_DOMAIN no es resoluble."
  echo "💡 Configura DNS o agrega a /etc/hosts:"
  echo "   echo '$LB_IP $RANCHER_DOMAIN' >> /etc/hosts"
  exit 1
fi

# 5. VERIFICAR ACCESO SSH A TODOS LOS NODOS
# ==========================================
echo "🔐 Verificando acceso SSH a todos los nodos..."

get_all_nodes_with_ips | while IFS=':' read -r ip hostname; do
  echo -n "➡️  $hostname ($ip): "
  if sshpass -p "$ROOT_PASSWORD" ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -p "$SSH_PORT" "$SSH_USER@$ip" "echo OK" &>/dev/null; then
    echo "✅ Conexión SSH OK"
  else
    echo "❌ Fallo de conexión SSH o contraseña incorrecta"
    echo "💡 Verifica:"
    echo "   - Que $ip esté accesible desde esta máquina"
    echo "   - Que ROOT_PASSWORD sea correcta"
    echo "   - Que el puerto SSH ($SSH_PORT) esté abierto"
    exit 1
  fi
done

# 6. VERIFICAR MÓDULOS DEL KERNEL
# ===============================
echo "🔍 Verificando módulos del kernel requeridos..."
REQUIRED_MODULES=(br_netfilter overlay ip_vs ip_vs_rr ip_vs_wrr ip_vs_sh nf_conntrack)
MISSING_MODULES=()

for mod in "${REQUIRED_MODULES[@]}"; do
  if lsmod | grep -q "^$mod "; then
    echo "✅ Módulo $mod cargado"
  else
    echo "⚠️  Módulo $mod no cargado"
    MISSING_MODULES+=($mod)
  fi
done

if [ ${#MISSING_MODULES[@]} -gt 0 ]; then
  echo "🔧 Cargando módulos faltantes..."
  for mod in "${MISSING_MODULES[@]}"; do
    modprobe "$mod" && echo "✅ $mod cargado" || echo "❌ Error cargando $mod"
  done
fi

# 7. VERIFICAR DISCOS EN NODOS DE STORAGE
# =======================================
echo "💽 Verificando /dev/sdb en nodos de almacenamiento..."
get_nodes_by_type "storage" | while read -r node; do
  if [ -n "$node" ]; then
    echo -n "➡️  Verificando disco en $node: "
    if ssh -p "$SSH_PORT" "$SSH_USER@$node" "lsblk /dev/sdb" &>/dev/null; then
      DISK_SIZE=$(ssh -p "$SSH_PORT" "$SSH_USER@$node" "lsblk /dev/sdb -b -n -o SIZE" | head -1)
      DISK_SIZE_GB=$((DISK_SIZE / 1024 / 1024 / 1024))
      echo "✅ /dev/sdb disponible (${DISK_SIZE_GB}GB)"
    else
      echo "❌ /dev/sdb no encontrado o no accesible"
      echo "💡 Asegúrate de que el nodo $node tenga un disco /dev/sdb disponible para Ceph"
      exit 1
    fi
  fi
done

# 8. VERIFICAR SISTEMA OPERATIVO
# ==============================
echo "🖥️  Verificando sistema operativo..."
if [ -f /etc/os-release ]; then
  OS_INFO=$(grep PRETTY_NAME /etc/os-release | cut -d'"' -f2)
  echo "✅ Sistema: $OS_INFO"
else
  echo "⚠️  No se pudo determinar la versión del SO"
fi

# 9. VERIFICAR MEMORIA RAM
# ========================
echo "🧠 Verificando memoria RAM..."
TOTAL_RAM_GB=$(free -g | awk 'NR==2{print $2}')
if [ "$TOTAL_RAM_GB" -ge 4 ]; then
  echo "✅ RAM disponible: ${TOTAL_RAM_GB}GB (≥4GB requerido)"
else
  echo "❌ RAM insuficiente: ${TOTAL_RAM_GB}GB (mínimo 4GB requerido)"
  exit 1
fi

# 10. VERIFICAR ESPACIO EN DISCO
# ==============================
echo "💾 Verificando espacio en disco..."
ROOT_AVAILABLE=$(df -BG / | awk 'NR==2 {print $4}' | sed 's/G//')
if [ "$ROOT_AVAILABLE" -ge 20 ]; then
  echo "✅ Espacio disponible en /: ${ROOT_AVAILABLE}GB (≥20GB recomendado)"
else
  echo "⚠️  Espacio limitado en /: ${ROOT_AVAILABLE}GB (se recomienda ≥20GB)"
fi

echo ""
echo "🎉 Verificación de prerequisitos completada exitosamente"
echo "📋 Resumen:"
echo "   • Paquetes requeridos: ✅ Instalados"
echo "   • Configuración de nodos: ✅ Válida"
echo "   • Conectividad SSH: ✅ Funcionando"
echo "   • DNS de Rancher: ✅ Resoluble"
echo "   • Módulos kernel: ✅ Cargados"
echo "   • Discos storage: ✅ Disponibles"
echo "   • Recursos del sistema: ✅ Suficientes"
echo ""
echo "👉 Continúa con: scripts/01-setup-ssh.sh"
