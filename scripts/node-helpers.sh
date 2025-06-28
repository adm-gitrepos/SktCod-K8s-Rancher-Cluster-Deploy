#!/bin/bash
# 🧰 scripts/node-helpers.sh - Funciones Helper Centralizadas
# ============================================================
# Biblioteca de funciones para manejo dinámico de nodos basado en NODES_CONFIG
# Autor: @SktCod.ByChisto
# Versión: 2.0

# 🔧 Función para obtener todos los nodos de un tipo específico
# Uso: get_nodes_by_type "master" | "worker" | "storage"
get_nodes_by_type() {
    local node_type=$1
    if [ -z "$node_type" ]; then
        echo "❌ Error: get_nodes_by_type requiere un tipo de nodo (master|worker|storage)" >&2
        return 1
    fi
    
    echo "$NODES_CONFIG" | jq -r "to_entries[] | select(.value.type == \"$node_type\") | .key" 2>/dev/null || {
        echo "❌ Error procesando NODES_CONFIG para tipo: $node_type" >&2
        return 1
    }
}

# 🔍 Función para obtener la IP de un nodo específico
# Uso: get_node_ip "hostname"
get_node_ip() {
    local hostname=$1
    if [ -z "$hostname" ]; then
        echo "❌ Error: get_node_ip requiere un hostname" >&2
        return 1
    fi
    
    echo "$NODES_CONFIG" | jq -r ".\"$hostname\".ip // empty" 2>/dev/null || {
        echo "❌ Error obteniendo IP para nodo: $hostname" >&2
        return 1
    }
}

# 👑 Función para obtener el nodo master principal
# Uso: PRIMARY_MASTER=$(get_primary_master)
get_primary_master() {
    echo "$NODES_CONFIG" | jq -r "to_entries[] | select(.value.primary == true and .value.type == \"master\") | .key" 2>/dev/null || {
        echo "❌ Error: No se encontró master principal en NODES_CONFIG" >&2
        return 1
    }
}

# 🔄 Función para obtener todos los masters secundarios
# Uso: get_secondary_masters
get_secondary_masters() {
    echo "$NODES_CONFIG" | jq -r "to_entries[] | select(.value.primary != true and .value.type == \"master\") | .key" 2>/dev/null || {
        echo "❌ Error obteniendo masters secundarios" >&2
        return 1
    }
}

# 🌐 Función para obtener todos los nodos con formato IP:HOSTNAME (para prerequisitos)
# Uso: get_all_nodes_with_ips
get_all_nodes_with_ips() {
    echo "$NODES_CONFIG" | jq -r "to_entries[] | \"\(.value.ip):\(.key)\"" 2>/dev/null || {
        echo "❌ Error obteniendo lista de nodos con IPs" >&2
        return 1
    }
}

# ✅ Función para validar que el archivo .env tenga la configuración de nodos válida
# Uso: validate_nodes_config
validate_nodes_config() {
    # Verificar que jq esté disponible
    if ! command -v jq &>/dev/null; then
        echo "❌ jq no está instalado. Es requerido para procesar NODES_CONFIG."
        echo "💡 Ejecuta: yum install -y jq (o dnf install -y jq / apt-get install -y jq)"
        echo "💡 O ejecuta: bash scripts/00-check-prereqs.sh para instalación automática"
        return 1
    fi
    
    # Verificar que NODES_CONFIG esté definido
    if [ -z "${NODES_CONFIG:-}" ]; then
        echo "❌ NODES_CONFIG no está definido en .env"
        echo "💡 Asegúrate de haber copiado .env.example a .env y configurado NODES_CONFIG"
        return 1
    fi
    
    # Verificar que NODES_CONFIG sea JSON válido
    if ! echo "$NODES_CONFIG" | jq . &>/dev/null; then
        echo "❌ NODES_CONFIG no es un JSON válido"
        echo "💡 Valida tu JSON con: echo \"\$NODES_CONFIG\" | jq ."
        echo "💡 Verifica que no falten comillas, comas o llaves"
        return 1
    fi
    
    # Verificar que hay al menos un nodo configurado
    local total_nodes=$(echo "$NODES_CONFIG" | jq -r 'length')
    if [ "$total_nodes" -eq 0 ]; then
        echo "❌ NODES_CONFIG está vacío. Se requiere al menos un nodo."
        return 1
    fi
    
    # Verificar que hay exactamente un master primario
    local primary_count=$(echo "$NODES_CONFIG" | jq -r "[to_entries[] | select(.value.primary == true and .value.type == \"master\")] | length")
    if [ "$primary_count" -eq 0 ]; then
        echo "❌ No se encontró ningún master primario (primary: true)"
        echo "💡 Exactamente un nodo master debe tener 'primary': true"
        return 1
    elif [ "$primary_count" -gt 1 ]; then
        echo "❌ Se encontraron $primary_count masters primarios. Solo debe haber uno."
        echo "💡 Exactamente un nodo master debe tener 'primary': true"
        return 1
    fi
    
    # Verificar que todos los nodos tienen las propiedades requeridas
    local invalid_nodes=""
    echo "$NODES_CONFIG" | jq -r 'to_entries[] | "\(.key):\(.value.ip // "missing"):\(.value.type // "missing"):\(.value.primary // false)"' | while IFS=':' read -r hostname ip type primary; do
        local errors=""
        
        # Verificar IP
        if [ "$ip" = "missing" ] || [ -z "$ip" ]; then
            errors="$errors IP_faltante"
        elif ! [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            errors="$errors IP_inválida"
        fi
        
        # Verificar tipo
        if [ "$type" = "missing" ] || [ -z "$type" ]; then
            errors="$errors tipo_faltante"
        elif [[ ! "$type" =~ ^(master|worker|storage)$ ]]; then
            errors="$errors tipo_inválido($type)"
        fi
        
        # Verificar primary (solo para masters)
        if [ "$type" = "master" ] && [ "$primary" != "true" ] && [ "$primary" != "false" ]; then
            errors="$errors primary_inválido"
        fi
        
        if [ -n "$errors" ]; then
            echo "❌ Nodo $hostname tiene errores: $errors" >&2
            invalid_nodes="$invalid_nodes $hostname"
        fi
    done
    
    if [ -n "$invalid_nodes" ]; then
        echo "❌ Configuración inválida en nodos:$invalid_nodes"
        echo "💡 Verifica que todos los nodos tengan: ip, type (master|worker|storage), primary (true/false para masters)"
        return 1
    fi
    
    # Verificar que hay al menos un master
    local master_count=$(echo "$NODES_CONFIG" | jq -r '[to_entries[] | select(.value.type == "master")] | length')
    if [ "$master_count" -eq 0 ]; then
        echo "❌ No se encontraron nodos master. Se requiere al menos uno."
        return 1
    fi
    
    return 0
}

# 🏊 Función para generar YAML de nodos Ceph dinámicamente
# Uso: generate_ceph_nodes_yaml
generate_ceph_nodes_yaml() {
    local storage_nodes
    storage_nodes=$(get_nodes_by_type "storage" 2>/dev/null)
    
    if [ -z "$storage_nodes" ]; then
        echo "❌ No se encontraron nodos de storage para Ceph" >&2
        return 1
    fi
    
    echo "    nodes:"
    while IFS= read -r node; do
        if [ -n "$node" ]; then
            echo "    - name: $node"
            echo "      devices:"
            echo "      - name: \"/dev/sdb\""
        fi
    done <<< "$storage_nodes"
}

# 📊 Función para mostrar resumen detallado de la configuración
# Uso: show_nodes_summary
show_nodes_summary() {
    echo "📋 Resumen de configuración de nodos:"
    echo "===================================="
    
    # Contadores por tipo
    local master_count=$(echo "$NODES_CONFIG" | jq -r '[to_entries[] | select(.value.type == "master")] | length' 2>/dev/null || echo "0")
    local worker_count=$(echo "$NODES_CONFIG" | jq -r '[to_entries[] | select(.value.type == "worker")] | length' 2>/dev/null || echo "0")
    local storage_count=$(echo "$NODES_CONFIG" | jq -r '[to_entries[] | select(.value.type == "storage")] | length' 2>/dev/null || echo "0")
    local total_count=$(echo "$NODES_CONFIG" | jq -r 'length' 2>/dev/null || echo "0")
    
    echo ""
    echo "📊 Estadísticas:"
    echo "   • Total de nodos: $total_count"
    echo "   • Masters: $master_count"
    echo "   • Workers: $worker_count"
    echo "   • Storage: $storage_count"
    
    # Mostrar masters
    echo ""
    echo "🔹 Nodos Master:"
    get_nodes_by_type "master" 2>/dev/null | while read -r node; do
        if [ -n "$node" ]; then
            local ip=$(get_node_ip "$node")
            local is_primary=$(echo "$NODES_CONFIG" | jq -r ".\"$node\".primary // false")
            if [ "$is_primary" = "true" ]; then
                echo "   • $node ($ip) [PRIMARIO] ⭐"
            else
                echo "   • $node ($ip)"
            fi
        fi
    done
    
    # Mostrar workers
    echo ""
    echo "🔹 Nodos Worker:"
    local workers=$(get_nodes_by_type "worker" 2>/dev/null)
    if [ -n "$workers" ]; then
        echo "$workers" | while read -r node; do
            if [ -n "$node" ]; then
                local ip=$(get_node_ip "$node")
                echo "   • $node ($ip)"
            fi
        done
    else
        echo "   (No hay nodos worker configurados)"
    fi
    
    # Mostrar storage
    echo ""
    echo "🔹 Nodos Storage:"
    local storage=$(get_nodes_by_type "storage" 2>/dev/null)
    if [ -n "$storage" ]; then
        echo "$storage" | while read -r node; do
            if [ -n "$node" ]; then
                local ip=$(get_node_ip "$node")
                echo "   • $node ($ip)"
            fi
        done
    else
        echo "   (No hay nodos storage configurados)"
    fi
    
    echo ""
}

# 🔍 Función para verificar conectividad SSH a todos los nodos
# Uso: verify_ssh_connectivity
verify_ssh_connectivity() {
    local failed_nodes=""
    local success_count=0
    local total_count=0
    
    echo "🔐 Verificando conectividad SSH a todos los nodos..."
    
    get_all_nodes_with_ips | while IFS=':' read -r ip hostname; do
        ((total_count++))
        echo -n "   • $hostname ($ip): "
        
        if ssh -p "${SSH_PORT:-22}" -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o BatchMode=yes "${SSH_USER:-root}@$ip" "echo OK" &>/dev/null; then
            echo "✅ SSH OK"
            ((success_count++))
        else
            echo "❌ SSH FAIL"
            failed_nodes="$failed_nodes $hostname"
        fi
    done
    
    if [ -n "$failed_nodes" ]; then
        echo ""
        echo "❌ Falló conectividad SSH a:$failed_nodes"
        echo "💡 Verifica:"
        echo "   - ROOT_PASSWORD en .env"
        echo "   - Conectividad de red a los nodos"
        echo "   - Puerto SSH ($SSH_PORT) accesible"
        return 1
    else
        echo ""
        echo "✅ Conectividad SSH verificada en $success_count/$total_count nodos"
        return 0
    fi
}

# 🧮 Función para contar nodos por tipo
# Uso: count_nodes_by_type "master"
count_nodes_by_type() {
    local node_type=$1
    if [ -z "$node_type" ]; then
        echo "0"
        return 1
    fi
    
    echo "$NODES_CONFIG" | jq -r "[to_entries[] | select(.value.type == \"$node_type\")] | length" 2>/dev/null || echo "0"
}

# 🔄 Función para obtener nodos excluyendo uno específico
# Uso: get_nodes_excluding "hostname"
get_nodes_excluding() {
    local exclude_hostname=$1
    if [ -z "$exclude_hostname" ]; then
        echo "❌ Error: get_nodes_excluding requiere un hostname a excluir" >&2
        return 1
    fi
    
    echo "$NODES_CONFIG" | jq -r "to_entries[] | select(.key != \"$exclude_hostname\") | .key" 2>/dev/null || {
        echo "❌ Error obteniendo nodos excluyendo: $exclude_hostname" >&2
        return 1
    }
}

# 🏷️ Función para generar etiquetas de nodos dinámicamente
# Uso: generate_node_labels "hostname"
generate_node_labels() {
    local hostname=$1
    if [ -z "$hostname" ]; then
        echo "❌ Error: generate_node_labels requiere un hostname" >&2
        return 1
    fi
    
    local node_type=$(echo "$NODES_CONFIG" | jq -r ".\"$hostname\".type // empty")
    local is_primary=$(echo "$NODES_CONFIG" | jq -r ".\"$hostname\".primary // false")
    
    case "$node_type" in
        master)
            echo "  - \"rke2-master=true\""
            echo "  - \"node-role.kubernetes.io/master=true\""
            if [ "$is_primary" = "true" ]; then
                echo "  - \"rke2-primary-master=true\""
            fi
            ;;
        worker)
            echo "  - \"rke2-worker=true\""
            echo "  - \"rke2-rancher=true\""
            echo "  - \"node-role.kubernetes.io/worker=true\""
            ;;
        storage)
            echo "  - \"rke2-storage=true\""
            echo "  - \"ceph-node=true\""
            echo "  - \"node-role.kubernetes.io/storage=true\""
            ;;
        *)
            echo "❌ Error: Tipo de nodo desconocido: $node_type" >&2
            return 1
            ;;
    esac
}

# 🔧 Función para generar taints de nodos dinámicamente
# Uso: generate_node_taints "hostname"
generate_node_taints() {
    local hostname=$1
    if [ -z "$hostname" ]; then
        echo "❌ Error: generate_node_taints requiere un hostname" >&2
        return 1
    fi
    
    local node_type=$(echo "$NODES_CONFIG" | jq -r ".\"$hostname\".type // empty")
    
    case "$node_type" in
        master)
            echo "  - \"CriticalAddonsOnly=true:NoExecute\""
            ;;
        worker)
            echo "  - \"node-role.kubernetes.io/worker=true:NoSchedule\""
            ;;
        storage)
            echo "  - \"node-role.kubernetes.io/storage=true:NoSchedule\""
            ;;
        *)
            echo "❌ Error: Tipo de nodo desconocido: $node_type" >&2
            return 1
            ;;
    esac
}

# 🧪 Función para validar configuración específica por tipo de nodo
# Uso: validate_node_type_config "storage"
validate_node_type_config() {
    local node_type=$1
    local errors=""
    
    case "$node_type" in
        storage)
            # Verificar que nodos storage tengan discos /dev/sdb
            get_nodes_by_type "storage" | while read -r hostname; do
                if [ -n "$hostname" ]; then
                    local ip=$(get_node_ip "$hostname")
                    if ! ssh -p "${SSH_PORT:-22}" "${SSH_USER:-root}@$ip" "lsblk /dev/sdb" &>/dev/null; then
                        echo "❌ Nodo storage $hostname no tiene disco /dev/sdb disponible" >&2
                        errors="$errors $hostname"
                    fi
                fi
            done
            ;;
        master)
            # Verificar que hay suficientes masters para HA
            local master_count=$(count_nodes_by_type "master")
            if [ "$master_count" -lt 1 ]; then
                echo "❌ Se requiere al menos 1 nodo master" >&2
                return 1
            elif [ "$master_count" -eq 2 ]; then
                echo "⚠️  Se recomienda usar 1 o 3+ masters (2 masters no proveen HA real)" >&2
            fi
            ;;
        worker)
            # Verificar que hay al menos un worker para Rancher
            local worker_count=$(count_nodes_by_type "worker")
            if [ "$worker_count" -lt 1 ]; then
                echo "⚠️  No hay nodos worker configurados. Rancher necesita workers para desplegarse." >&2
            fi
            ;;
    esac
    
    if [ -n "$errors" ]; then
        return 1
    fi
    return 0
}

# 📄 Función para generar archivo de configuración RKE2 por nodo
# Uso: generate_rke2_config "hostname" "master_token"
generate_rke2_config() {
    local hostname=$1
    local master_token=$2
    
    if [ -z "$hostname" ]; then
        echo "❌ Error: generate_rke2_config requiere hostname" >&2
        return 1
    fi
    
    local node_type=$(echo "$NODES_CONFIG" | jq -r ".\"$hostname\".type // empty")
    local is_primary=$(echo "$NODES_CONFIG" | jq -r ".\"$hostname\".primary // false")
    
    echo "# Configuración RKE2 para $hostname (tipo: $node_type)"
    
    case "$node_type" in
        master)
            if [ "$is_primary" = "true" ]; then
                # Master principal
                cat <<EOF
token: ${CLUSTER_TOKEN}
node-taint:
$(generate_node_taints "$hostname")
cni: calico
disable:
  - rke2-ingress-nginx
etcd-expose-metrics: true
etcd-snapshot-schedule-cron: "0 */12 * * *"
etcd-snapshot-retention: 5
node-label:
$(generate_node_labels "$hostname")
write-kubeconfig-mode: "0644"
EOF
            else
                # Master secundario - CORREGIDO para usar subdominios
                if [ -z "$master_token" ]; then
                    echo "❌ Error: master_token requerido para masters secundarios" >&2
                    return 1
                fi
                cat <<EOF
token: $master_token
server: $(get_rke2_server_url "master")
node-taint:
$(generate_node_taints "$hostname")
cni: calico
disable:
  - rke2-ingress-nginx
etcd-expose-metrics: true
etcd-snapshot-schedule-cron: "0 */12 * * *"
etcd-snapshot-retention: 5
node-label:
$(generate_node_labels "$hostname")
write-kubeconfig-mode: "0644"
EOF
            fi
            ;;
        worker|storage)
            # Worker o storage node - CORREGIDO para usar subdominios
            if [ -z "$master_token" ]; then
                echo "❌ Error: master_token requerido para workers/storage" >&2
                return 1
            fi
            cat <<EOF
token: $master_token
server: $(get_rke2_server_url "$node_type")
node-label:
$(generate_node_labels "$hostname")
node-taint:
$(generate_node_taints "$hostname")
EOF
            ;;
        *)
            echo "❌ Error: Tipo de nodo desconocido: $node_type" >&2
            return 1
            ;;
    esac
}

# 🎯 Función para mostrar ayuda de las funciones disponibles
# Uso: show_helper_functions
show_helper_functions() {
    cat <<EOF
🧰 Funciones Helper Disponibles:
==============================

📋 Información de Nodos:
  get_nodes_by_type "type"           - Obtiene nodos por tipo (master|worker|storage)
  get_node_ip "hostname"             - Obtiene IP de un nodo específico
  get_primary_master                 - Obtiene el master principal
  get_secondary_masters              - Obtiene masters secundarios
  get_all_nodes_with_ips             - Obtiene todos los nodos con formato IP:HOSTNAME
  count_nodes_by_type "type"         - Cuenta nodos por tipo
  get_nodes_excluding "hostname"     - Obtiene nodos excluyendo uno específico

✅ Validación:
  validate_nodes_config              - Valida configuración JSON completa
  verify_ssh_connectivity           - Verifica SSH a todos los nodos
  validate_node_type_config "type"  - Valida configuración específica por tipo
  validate_subdomain_config          - Valida configuración de subdominios

🔧 Generación de Configuración:
  generate_ceph_nodes_yaml           - Genera YAML de nodos Ceph
  generate_node_labels "hostname"    - Genera etiquetas de nodo
  generate_node_taints "hostname"    - Genera taints de nodo
  generate_rke2_config "hostname" "token" - Genera config RKE2 completa
  get_rke2_server_url "node_type"    - Genera server URL por tipo de nodo
  get_complete_tls_sans "node_ip"    - Genera TLS SANs completos

📊 Información:
  show_nodes_summary                 - Muestra resumen detallado
  show_helper_functions              - Muestra esta ayuda

📝 Ejemplos de Uso:
  source scripts/node-helpers.sh
  validate_nodes_config
  validate_subdomain_config
  show_nodes_summary
  PRIMARY=\$(get_primary_master)
  get_nodes_by_type "worker" | while read node; do
    echo "Worker: \$node (\$(get_node_ip \$node))"
  done
EOF
}

# 📝 Función para exportar configuración a diferentes formatos
# Uso: export_config "format" donde format puede ser: yaml, json, env
export_config() {
    local format=${1:-json}
    
    case "$format" in
        json)
            echo "$NODES_CONFIG" | jq .
            ;;
        yaml)
            echo "$NODES_CONFIG" | jq -r 'to_entries[] | "- hostname: \(.key)\n  ip: \(.value.ip)\n  type: \(.value.type)\n  primary: \(.value.primary // false)\n"'
            ;;
        env)
            echo "# Configuración de nodos exportada en formato ENV"
            echo "$NODES_CONFIG" | jq -r 'to_entries[] | "\(.key | ascii_upcase)_IP=\(.value.ip)\n\(.key | ascii_upcase)_TYPE=\(.value.type)"'
            ;;
        *)
            echo "❌ Formato no soportado: $format. Usa: json, yaml, env" >&2
            return 1
            ;;
    esac
}

# =======================================
# 🌐 FUNCIONES PARA SUBDOMINIOS (NUEVAS)
# =======================================

# Validar configuración de subdominios
validate_subdomain_config() {
    local required_domains=("RANCHER_DOMAIN" "K8S_API_DOMAIN" "K8S_REG_DOMAIN")
    local missing_domains=()
    
    for domain_var in "${required_domains[@]}"; do
        if [[ -z "${!domain_var}" ]]; then
            missing_domains+=("$domain_var")
        fi
    done
    
    if [[ ${#missing_domains[@]} -gt 0 ]]; then
        echo "❌ Error: Variables faltantes: ${missing_domains[*]}"
        echo "💡 Agregar al .env:"
        for domain in "${missing_domains[@]}"; do
            echo "   $domain=tu-subdominio.midominio.com"
        done
        return 1
    fi
    
    echo "✅ Configuración de subdominios válida"
    return 0
}

# Generar server URL según tipo de nodo
get_rke2_server_url() {
    local node_type="$1"
    if [[ "$node_type" == "master" ]]; then
        echo "https://${K8S_API_DOMAIN}:443"
    else
        echo "https://${K8S_REG_DOMAIN}:443"
    fi
}

# Generar TLS SANs completos
get_complete_tls_sans() {
    local node_ip="$1"
    cat << EOF
  - ${K8S_API_DOMAIN}
  - ${K8S_REG_DOMAIN}
  - ${RANCHER_DOMAIN}
  - ${LB_IP}
  - ${node_ip}
  - localhost
  - 127.0.0.1
EOF
}

# 🏁 Mensaje de carga exitosa
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    echo "🧰 Funciones helper de node-helpers.sh cargadas exitosamente"
    echo "💡 Usa 'show_helper_functions' para ver todas las funciones disponibles"
    echo "📋 Usa 'show_nodes_summary' para ver tu configuración actual"
fi

# 📜 Información del archivo
# =========================
# Archivo: scripts/node-helpers.sh
# Propósito: Funciones centralizadas para manejo dinámico de nodos
# Autor: @SktCod.ByChisto (https://github.com/adm-gitrepos)
# Versión: 2.0
# Licencia: MIT
# 
# Este archivo contiene todas las funciones necesarias para:
# - Procesar la configuración NODES_CONFIG en formato JSON
# - Validar configuración de nodos y prerequisitos
# - Generar configuraciones dinámicas para RKE2, Ceph, etc.
# - Proporcionar información y estadísticas de la infraestructura
# - Soporte completo para subdominios FQDN (K8S_API_DOMAIN, K8S_REG_DOMAIN, RANCHER_DOMAIN)
# 
# Uso típico:
# 1. source scripts/node-helpers.sh
# 2. validate_nodes_config
# 3. validate_subdomain_config
# 4. show_nodes_summary
# 5. PRIMARY=$(get_primary_master)
# 6. WORKERS=$(get_nodes_by_type "worker")
