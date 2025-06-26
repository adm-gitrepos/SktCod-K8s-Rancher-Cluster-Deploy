#!/bin/bash
set -euo pipefail
trap 'echo "❌ Error en línea $LINENO durante configuración SSH. Verifica conectividad y clave." && exit 1' ERR

# Cargar variables
[ -f .env ] && source .env || { echo "❌ Falta archivo .env"; exit 1; }

# Cargar funciones helper
[ -f scripts/node-helpers.sh ] && source scripts/node-helpers.sh || { 
  echo "❌ Falta archivo scripts/node-helpers.sh"
  echo "💡 Ejecuta primero: scripts/00-check-prereqs.sh"
  exit 1
}

LOG="logs/01-setup-ssh-$(date +%F-%H%M).log"
mkdir -p logs && exec > >(tee -a "$LOG") 2>&1

echo "🔐 Configurando SSH sin contraseña para el clúster..."

# 1. VALIDAR CONFIGURACIÓN
# =========================
validate_nodes_config

if [ -z "${ROOT_PASSWORD:-}" ]; then
  echo "❌ Falta definir ROOT_PASSWORD en el archivo .env"
  exit 1
fi

# 2. DETECTAR NODO MASTER PRINCIPAL
# =================================
PRIMARY_MASTER=$(get_primary_master)
CURRENT_HOSTNAME=$(hostname)

echo "📍 Nodo master principal configurado: $PRIMARY_MASTER"
echo "📍 Hostname actual: $CURRENT_HOSTNAME"

# Verificar que estamos ejecutando desde el master principal
if [ "$CURRENT_HOSTNAME" != "$PRIMARY_MASTER" ]; then
  echo "⚠️  ADVERTENCIA: Ejecutándose desde $CURRENT_HOSTNAME, no desde $PRIMARY_MASTER"
  echo "💡 Se recomienda ejecutar este script desde el nodo master principal"
  echo "🔄 ¿Continuar de todas formas? (y/N)"
  read -r -n 1 response
  echo
  if [[ ! "$response" =~ ^[Yy]$ ]]; then
    echo "❌ Operación cancelada por el usuario"
    exit 1
  fi
fi

# 3. VERIFICAR O GENERAR CLAVE SSH
# ================================
echo "🗝️  Verificando clave SSH..."

if [ ! -f "$HOME/.ssh/id_rsa" ]; then
  echo "🔧 Generando nueva clave SSH RSA..."
  ssh-keygen -t rsa -b 4096 -N "" -f "$HOME/.ssh/id_rsa"
  echo "✅ Clave SSH generada: $HOME/.ssh/id_rsa"
elif [ ! -f "$HOME/.ssh/id_rsa.pub" ]; then
  echo "🔧 Regenerando clave pública desde clave privada..."
  ssh-keygen -y -f "$HOME/.ssh/id_rsa" > "$HOME/.ssh/id_rsa.pub"
  echo "✅ Clave pública regenerada"
else
  echo "✅ Clave SSH ya existe"
fi

# Mostrar información de la clave
KEY_FINGERPRINT=$(ssh-keygen -lf "$HOME/.ssh/id_rsa.pub" | awk '{print $2}')
echo "🔑 Fingerprint de la clave: $KEY_FINGERPRINT"

# 4. OBTENER LISTA DE NODOS REMOTOS
# =================================
echo "📋 Obteniendo lista de nodos remotos..."

# Obtener todos los nodos excepto el actual
REMOTE_NODES=$(echo "$NODES_CONFIG" | jq -r "to_entries[] | select(.key != \"$CURRENT_HOSTNAME\") | .key")
REMOTE_COUNT=$(echo "$REMOTE_NODES" | wc -l)

if [ -z "$REMOTE_NODES" ] || [ "$REMOTE_NODES" = "" ]; then
  echo "⚠️  No hay nodos remotos para configurar SSH"
  echo "✅ Configuración SSH completada (solo nodo local)"
  exit 0
fi

echo "📊 Se configurará SSH en $REMOTE_COUNT nodos remotos"

# 5. CONFIGURAR SSH EN NODOS REMOTOS
# ==================================
echo "🔗 Configurando acceso SSH sin contraseña..."

SUCCESS_COUNT=0
FAILED_NODES=()

echo "$REMOTE_NODES" | while read -r hostname; do
  if [ -n "$hostname" ]; then
    echo ""
    echo "🔧 Procesando nodo: $hostname"
    
    # Verificar si ya tiene acceso SSH sin contraseña
    echo -n "  🔍 Verificando acceso actual: "
    if ssh -p "$SSH_PORT" -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no "$SSH_USER@$hostname" "echo OK" &>/dev/null; then
      echo "✅ Ya tiene acceso SSH sin contraseña"
      ((SUCCESS_COUNT++))
      continue
    else
      echo "❌ Requiere configuración"
    fi
    
    # Copiar clave SSH
    echo -n "  🚀 Copiando clave pública: "
    if sshpass -p "$ROOT_PASSWORD" ssh-copy-id -i "$HOME/.ssh/id_rsa.pub" -p "$SSH_PORT" -o StrictHostKeyChecking=no "$SSH_USER@$hostname" &>/dev/null; then
      echo "✅ Clave copiada correctamente"
      
      # Verificar que funciona
      echo -n "  ✔️  Verificando funcionamiento: "
      if ssh -p "$SSH_PORT" -o BatchMode=yes -o ConnectTimeout=5 "$SSH_USER@$hostname" "echo OK" &>/dev/null; then
        echo "✅ SSH sin contraseña funcional"
        ((SUCCESS_COUNT++))
      else
        echo "❌ Fallo en verificación post-copia"
        FAILED_NODES+=("$hostname")
      fi
    else
      echo "❌ Error copiando clave SSH"
      FAILED_NODES+=("$hostname")
    fi
  fi
done

# 6. VERIFICACIÓN FINAL COMPLETA
# ==============================
echo ""
echo "🔍 Realizando verificación final de conectividad SSH..."

FINAL_SUCCESS=0
FINAL_FAILED=()

echo "$REMOTE_NODES" | while read -r hostname; do
  if [ -n "$hostname" ]; then
    echo -n "➡️  $hostname: "
    if ssh -p "$SSH_PORT" -o BatchMode=yes -o ConnectTimeout=5 "$SSH_USER@$hostname" "hostname && echo 'SSH OK'" &>/dev/null; then
      echo "✅ Conectividad SSH confirmada"
      ((FINAL_SUCCESS++))
    else
      echo "❌ Fallo de conectividad SSH"
      FINAL_FAILED+=("$hostname")
    fi
  fi
done

# 7. RESUMEN FINAL
# ================
echo ""
echo "📊 Resumen de configuración SSH:"
echo "   • Total nodos remotos: $REMOTE_COUNT"
echo "   • Configurados exitosamente: $SUCCESS_COUNT"

if [ ${#FAILED_NODES[@]} -gt 0 ]; then
  echo "   • Nodos con errores: ${#FAILED_NODES[@]}"
  echo "   • Lista de nodos fallidos: ${FAILED_NODES[*]}"
  echo ""
  echo "❌ Algunos nodos fallaron en la configuración SSH"
  echo "💡 Revisa la conectividad y credenciales de los nodos fallidos"
  exit 1
fi

# 8. CONFIGURAR ARCHIVO SSH CONFIG (OPCIONAL)
# ===========================================
echo "🔧 Configurando archivo SSH config para optimización..."

SSH_CONFIG="$HOME/.ssh/config"
if [ ! -f "$SSH_CONFIG" ] || ! grep -q "StrictHostKeyChecking no" "$SSH_CONFIG" 2>/dev/null; then
  cat >> "$SSH_CONFIG" <<EOF

# Configuración automática para clúster RKE2
Host $(echo "$REMOTE_NODES" | tr '\n' ' ')
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    LogLevel ERROR
    ConnectTimeout 10
    Port $SSH_PORT
    User $SSH_USER

EOF
  chmod 600 "$SSH_CONFIG"
  echo "✅ Archivo SSH config actualizado"
fi

echo ""
echo "🎉 Configuración SSH completada exitosamente"
echo "🔑 Clave SSH configurada para acceso sin contraseña a todos los nodos"
echo "📁 Archivos generados:"
echo "   • Clave privada: $HOME/.ssh/id_rsa"
echo "   • Clave pública: $HOME/.ssh/id_rsa.pub"
echo "   • Configuración SSH: $HOME/.ssh/config"
echo ""
echo "👉 Continúa con: scripts/02-install-cluster.sh"
