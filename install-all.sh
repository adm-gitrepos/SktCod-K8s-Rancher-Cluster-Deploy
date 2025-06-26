#!/bin/bash
set -euo pipefail
trap 'echo "❌ Error en línea $LINENO durante ejecución del instalador. Abortando." && exit 1' ERR

MODE="${1:-full}"
LOG_DIR="logs"
mkdir -p "$LOG_DIR"

# Verificar que jq esté disponible desde el inicio
if ! command -v jq &>/dev/null; then
    echo "❌ jq no está instalado y es requerido para este instalador."
    echo "💡 Instálalo con uno de estos comandos:"
    echo "   • Red Hat/CentOS/Oracle Linux: yum install -y jq"
    echo "   • Fedora: dnf install -y jq"
    echo "   • Debian/Ubuntu: apt-get install -y jq"
    echo ""
    echo "🔄 Ejecuta el script 00-check-prereqs.sh para instalación automática:"
    echo "   bash scripts/00-check-prereqs.sh"
    exit 1
fi

# Verificar que existe el archivo .env
if [ ! -f .env ]; then
    echo "❌ Archivo .env no encontrado."
    echo "💡 Copia .env.example a .env y configúralo:"
    echo "   cp .env.example .env && nano .env"
    exit 1
fi

SCRIPTS=(
  "scripts/00-check-prereqs.sh"
  "scripts/01-setup-ssh.sh"
  "scripts/02-install-cluster.sh"
)

case "$MODE" in
  full)
    SCRIPTS+=(
      "scripts/03-install-ceph.sh"
      "scripts/04-install-metallb.sh"
      "scripts/05-install-rancher.sh"
      "scripts/06-verify-installation.sh"
      "scripts/07-test-ha.sh"
      "scripts/08-dns-config.sh"
    )
    ;;
  no-rancher)
    SCRIPTS+=(
      "scripts/03-install-ceph.sh"
      "scripts/04-install-metallb.sh"
      "scripts/06-verify-installation.sh"
      "scripts/07-test-ha.sh"
    )
    ;;
  only-k8s)
    # Solo mantiene los tres primeros pasos definidos arriba
    ;;
  *)
    echo "❌ Modo inválido: $MODE. Usa uno de: full | no-rancher | only-k8s"
    exit 1
    ;;
esac

echo "🚀 Ejecutando instalación completa en modo: $MODE"

for script in "${SCRIPTS[@]}"; do
  STEP_NAME=$(basename "$script" .sh)
  LOG_FILE="$LOG_DIR/${STEP_NAME}-$(date +%F-%H%M).log"

  echo -e "\n🔧 Ejecutando $STEP_NAME..."
  if bash "$script" | tee "$LOG_FILE"; then
    echo "✅ Completado: $STEP_NAME"
  else
    echo "❌ Error en $STEP_NAME. Revisa el log: $LOG_FILE"
    echo "❗ Puedes corregir el error y reejecutar este paso manualmente si no requiere rollback."
    exit 1
  fi
  echo "----------------------------------------"
  sleep 2

done

echo "🎉 Instalación completada en modo: $MODE"
echo "📘 Documentación disponible en: README.md"
