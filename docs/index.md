# 🧭 Documentación Técnica Completa - RKE2 + Rancher HA v2.0

Este documento centraliza toda la información técnica actualizada, arquitectura mejorada, configuración centralizada, funciones helper y extensiones del instalador automatizado de clústeres RKE2 en alta disponibilidad con Rancher.

---

## 🆕 Novedades de la Versión 2.0

### ✨ **Refactorización Completa**
- **Configuración centralizada** en `.env` con formato JSON para nodos
- **Funciones helper** reutilizables en `scripts/node-helpers.sh`
- **Auto-instalación** de dependencias (jq, helm, etc.)
- **Validación exhaustiva** en cada script
- **Escalabilidad mejorada** para agregar/quitar nodos fácilmente

### 🔧 **Arquitectura Mejorada**
- **Un solo punto de configuración** para toda la infraestructura
- **Consistencia garantizada** entre todos los scripts
- **Mantenimiento simplificado** con funciones centralizadas
- **Flexibilidad total** en tipos y cantidad de nodos

---

## 🧱 Arquitectura General

```
+-------------------------------+
|          NGINX Plus          |
| (Load Balancer 80/443/9345)  |
+-------------------------------+
           |       |
    +------+-------+------+
    | prd3appk8sm1       |
    | prd3appk8sm2       |  <-- Master nodes (RKE2 Server)
    | prd3appk8sm3       |      Auto-detectados desde NODES_CONFIG
    +--------------------+
           |       |
    +------+-------+------+
    | prd3appk8sw1       |  <-- Worker nodes (Rancher pods)
    | prd3appk8sw2       |      Configuración dinámica
    | prd3appk8sw3       |
    +--------------------+
           |       |
    +------+-------+------+
    | prd3appk8ss1       |  <-- Storage nodes (Ceph OSD)
    | prd3appk8ss2       |      Auto-configuración de discos
    | prd3appk8ss3       |
    +--------------------+
```

### 🔧 **Características Dinámicas:**
- **Balanceo automático** hacia puertos `6443`, `9345`, `80`, `443`
- **Rancher HA** desplegado automáticamente en nodos worker
- **Ceph distribuido** en nodos con label `ceph-node=true`
- **MetalLB** con pools de IP configurables

---

## 🏗️ Configuración Centralizada

### 📄 **Archivo `.env` - Configuración Completa**

```dotenv
# 🌍 Configuración Básica del Clúster
ROOT_PASSWORD=TuPasswordSeguraAqui
LB_IP=1.1.1.1                          # IP del LoadBalancer externo
SSH_PORT=22                             # Puerto SSH (default: 22)
SSH_USER=root                           # Usuario SSH (default: root)
RANCHER_DOMAIN=rancher.midominio.com    # Dominio para Rancher UI
BOOTSTRAP_PASSWORD=AdminPassword123     # Password inicial de Rancher
RKE2_VERSION=v1.32.1+rke2r1            # Versión específica de RKE2
RANCHER_VERSION=v2.11.1                # Versión específica de Rancher
CLUSTER_TOKEN=TokenSuperSeguro123       # Token único del clúster
METALLB_IP_RANGE=1.1.1.200-1.1.1.210   # Rango de IPs para MetalLB

# 🏗️ CONFIGURACIÓN DINÁMICA DE NODOS (JSON)
# ============================================
# Formato: {"hostname": {"ip": "x.x.x.x", "type": "master|worker|storage", "primary": true/false}}
NODES_CONFIG='{
  "prd3appk8sm1": {"ip": "1.1.1.20", "type": "master", "primary": true},
  "prd3appk8sm2": {"ip": "1.1.1.21", "type": "master", "primary": false},
  "prd3appk8sm3": {"ip": "1.1.1.22", "type": "master", "primary": false},
  "prd3appk8sw1": {"ip": "1.1.1.30", "type": "worker", "primary": false},
  "prd3appk8sw2": {"ip": "1.1.1.31", "type": "worker", "primary": false},
  "prd3appk8sw3": {"ip": "1.1.1.32", "type": "worker", "primary": false},
  "prd3appk8ss1": {"ip": "1.1.1.40", "type": "storage", "primary": false},
  "prd3appk8ss2": {"ip": "1.1.1.41", "type": "storage", "primary": false},
  "prd3appk8ss3": {"ip": "1.1.1.42", "type": "storage", "primary": false}
}'
```

### 🔑 **Tipos de Nodos Soportados:**

| Tipo | Descripción | Características | Servicios |
|------|-------------|-----------------|-----------|
| `master` | Nodos control plane | etcd, API server, scheduler | RKE2 Server |
| `worker` | Nodos de aplicaciones | Rancher UI, aplicaciones usuario | RKE2 Agent |
| `storage` | Nodos de almacenamiento | Ceph OSDs, almacenamiento persistente | RKE2 Agent + Ceph |

### 🔧 **Configuración Adicional por Nodo:**
- **`primary: true`**: Solo para UN master (donde se ejecuta la instalación inicial)
- **`ip`**: Dirección IP accesible via SSH
- **`type`**: Determina qué servicios se instalan en cada nodo

---

## 🧰 Funciones Helper Centralizadas

### 📄 **`scripts/node-helpers.sh` - Biblioteca de Funciones**

```bash
# Funciones principales disponibles:
get_nodes_by_type()          # Obtiene nodos por tipo (master/worker/storage)
get_node_ip()                # Obtiene IP de un nodo específico
get_primary_master()         # Obtiene el nodo master principal
get_secondary_masters()      # Obtiene masters secundarios
get_all_nodes_with_ips()     # Obtiene todos los nodos con formato IP:HOSTNAME
validate_nodes_config()      # Valida configuración JSON y prerequisitos
generate_ceph_nodes_yaml()   # Genera YAML de Ceph dinámicamente
show_nodes_summary()         # Muestra resumen de configuración
```

### 🔄 **Ventajas de las Funciones Helper:**
- ✅ **Reutilización**: Código consistente entre scripts
- ✅ **Mantenimiento**: Un solo lugar para lógica de nodos
- ✅ **Validación**: Verificación automática de configuración
- ✅ **Flexibilidad**: Fácil extensión para nuevos tipos de nodos

---

## 🧭 Modos de Instalación Mejorados

El script `install-all.sh` permite ejecutar el despliegue completo o parcial con validaciones automáticas:

| Modo         | Scripts Ejecutados | Descripción |
| ------------ | ------------------ | ----------- |
| `full`       | 00-08 (todos)     | Stack completo: RKE2 + Ceph + MetalLB + Rancher |
| `no-rancher` | 00-04, 06-07      | Todo excepto Rancher (para clústeres base) |
| `only-k8s`   | 00-02             | Solo RKE2 (para testing o configuración manual) |

### 🔧 **Validaciones Automáticas:**
- **jq disponible**: Auto-instala si no está presente
- **Configuración JSON**: Valida formato y estructura
- **Prerequisitos**: RAM, disco, conectividad, módulos kernel

---

## 📂 Estructura de Scripts Refactorizada

```bash
scripts/
├── node-helpers.sh              # 🆕 Funciones centralizadas
├── 00-check-prereqs.sh          # Auto-instalación de dependencias
├── 01-setup-ssh.sh             # SSH dinámico por configuración
├── 02-install-cluster.sh       # RKE2 con nodos auto-detectados
├── 03-install-ceph.sh          # Ceph con configuración dinámica
├── 04-install-metallb.sh       # MetalLB con validación de red
├── 05-install-rancher.sh       # Rancher HA auto-configurado
├── 06-verify-installation.sh   # Verificación exhaustiva
├── 07-test-ha.sh               # Pruebas reales de HA con monitoreo
├── 08-dns-config.sh            # DNS y resumen final
```

### 🔧 **Mejoras por Script:**

#### **00-check-prereqs.sh**
- ✅ Auto-instalación de `jq`, `helm`, `sshpass`
- ✅ Validación de `NODES_CONFIG` JSON
- ✅ Verificación dinámica de nodos por tipo
- ✅ Carga automática de módulos kernel

#### **01-setup-ssh.sh**
- ✅ Detección automática de nodos desde configuración
- ✅ Verificación post-configuración
- ✅ Configuración SSH optimizada

#### **02-install-cluster.sh**
- ✅ Master principal auto-detectado
- ✅ Configuración específica por tipo de nodo
- ✅ Monitoreo de progreso en tiempo real
- ✅ Validación de quorum etcd

#### **03-install-ceph.sh**
- ✅ Nodos storage auto-detectados
- ✅ Generación dinámica de CephCluster YAML
- ✅ Validación de discos en cada nodo storage
- ✅ Configuración automática de réplicas

#### **04-install-metallb.sh**
- ✅ Validación de rango de IPs
- ✅ Verificación de conectividad de red
- ✅ Prueba automática de LoadBalancer

#### **05-install-rancher.sh**
- ✅ Auto-instalación de Helm si no existe
- ✅ Configuración HA con 3 replicas
- ✅ Certificados SSL automáticos
- ✅ Verificación de acceso HTTPS

#### **06-verify-installation.sh**
- ✅ Verificación por tipos de nodos
- ✅ Aplicación de prueba integral
- ✅ Validación de todos los componentes
- ✅ Sistema de puntuación

#### **07-test-ha.sh**
- ✅ Pruebas reales de fallo de master
- ✅ Monitoreo continuo en background
- ✅ Verificación de recuperación automática
- ✅ Pruebas de failover de Rancher

#### **08-dns-config.sh**
- ✅ Configuración DNS automática
- ✅ Validación de conectividad web
- ✅ Extracción de credenciales reales
- ✅ Resumen final completo

---

## 🧪 Validaciones Integradas Mejoradas

### 🔍 **Verificaciones Automáticas:**

#### **Pre-instalación:**
- ✅ Validación de formato JSON en `NODES_CONFIG`
- ✅ Verificación de conectividad SSH a todos los nodos
- ✅ Validación de prerequisitos por tipo de nodo
- ✅ Auto-instalación de dependencias faltantes

#### **Durante Instalación:**
- ✅ Monitoreo en tiempo real de procesos
- ✅ Verificación de estado después de cada paso
- ✅ Timeouts apropiados para cada componente
- ✅ Logs detallados con timestamps

#### **Post-instalación:**
- ✅ Verificación exhaustiva de todos los componentes
- ✅ Aplicación de prueba con PVC + LoadBalancer
- ✅ Pruebas reales de Alta Disponibilidad
- ✅ Validación de DNS y conectividad web

### 🔄 **Pruebas de Alta Disponibilidad:**
- **Fallo simulado** de master principal con monitoreo continuo
- **Verificación de quorum** etcd durante fallos
- **Failover de Rancher** con recreación automática de pods
- **Recuperación automática** y rejoining al clúster
- **Snapshots etcd** automáticos y manuales

---

## ⚠️ Prerequisitos Críticos Actualizados

### 🔴 **Configuración Obligatoria Antes de Ejecutar:**

#### **1. Archivo `.env` Configurado**
```bash
# Copiar y configurar
cp .env.example .env
nano .env

# Validar configuración JSON
echo "$NODES_CONFIG" | jq .
```

#### **2. DNS Configurado**
```bash
# Verificar resolución
nslookup $RANCHER_DOMAIN

# O configurar temporalmente
echo "$LB_IP $RANCHER_DOMAIN" >> /etc/hosts
```

#### **3. NGINX Plus (si se usa como proxy externo)**
- Upstreams configurados para puertos `6443`, `9345`, `80`, `443`
- Ver [`docs/nginx-plus.md`](./nginx-plus.md) para configuración detallada

#### **4. Acceso SSH Unificado**
- Misma contraseña root en todos los nodos
- Conectividad SSH desde el nodo master principal

### 🔧 **Auto-instalación de Dependencias**
Los scripts automáticamente instalan:
- `jq` (requerido para procesar JSON)
- `helm` (para Rancher y cert-manager)
- `sshpass`, `curl`, `wget`, `tar`

---

## 🚀 Flujo de Instalación Recomendado

### **Paso 1: Preparación**
```bash
# Clonar repositorio
git clone <repo-url>
cd rke2-rancher-ha-installer

# Configurar variables
cp .env.example .env
nano .env  # Configurar NODES_CONFIG y demás variables
```

### **Paso 2: Validación**
```bash
# Verificar prerequisitos (auto-instala dependencias)
bash scripts/00-check-prereqs.sh
```

### **Paso 3: Instalación**
```bash
# Opción A: Instalación completa automática
./install-all.sh full

# Opción B: Paso a paso para debugging
bash scripts/01-setup-ssh.sh
bash scripts/02-install-cluster.sh
bash scripts/03-install-ceph.sh
bash scripts/04-install-metallb.sh
bash scripts/05-install-rancher.sh
bash scripts/06-verify-installation.sh
bash scripts/07-test-ha.sh
bash scripts/08-dns-config.sh
```

### **Paso 4: Verificación Final**
```bash
# Acceder a Rancher
curl -k https://$RANCHER_DOMAIN

# Verificar clúster
kubectl get nodes -o wide
kubectl get pods -A
```

---

## 🔧 Configuración Avanzada

### **Agregar Nuevos Nodos**
```bash
# 1. Actualizar .env
NODES_CONFIG='{
  "existing-nodes": {...},
  "new-node": {"ip": "10.0.0.100", "type": "worker", "primary": false}
}'

# 2. Re-ejecutar scripts relevantes
bash scripts/01-setup-ssh.sh     # SSH al nuevo nodo
bash scripts/02-install-cluster.sh # Agregar al clúster
```

### **Cambiar Tipos de Nodos**
```bash
# Modificar tipo en NODES_CONFIG
"node-name": {"ip": "...", "type": "storage", "primary": false}

# Re-ejecutar configuración
bash scripts/02-install-cluster.sh
bash scripts/03-install-ceph.sh  # Si se agregó storage
```

### **Escalado de Componentes**
```bash
# Aumentar réplicas de Rancher
kubectl -n cattle-system scale deployment rancher --replicas=5

# Agregar más OSDs de Ceph (automático al agregar nodos storage)
# Expandir pool de MetalLB (modificar METALLB_IP_RANGE)
```

---

## 🧩 Extensiones Posibles

### **Monitoreo y Observabilidad**
```bash
# Prometheus + Grafana
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm install prometheus prometheus-community/kube-prometheus-stack

# Logging con ELK
kubectl apply -f https://raw.githubusercontent.com/elastic/cloud-on-k8s/main/config/crds.yaml
```

### **GitOps y CI/CD**
```bash
# ArgoCD
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Fleet (integrado con Rancher)
# Se configura desde la UI de Rancher
```

### **Seguridad Avanzada**
```bash
# Falco para runtime security
helm repo add falcosecurity https://falcosecurity.github.io/charts
helm install falco falcosecurity/falco

# OPA Gatekeeper para policies
kubectl apply -f https://raw.githubusercontent.com/open-policy-agent/gatekeeper/release-3.14/deploy/gatekeeper.yaml
```

### **Backup Automatizado**
```bash
# Velero para backup de aplicaciones
wget https://github.com/vmware-tanzu/velero/releases/download/v1.12.0/velero-v1.12.0-linux-amd64.tar.gz
tar -xvf velero-v1.12.0-linux-amd64.tar.gz
./velero install --provider aws --bucket mybucket --secret-file ./credentials-velero
```

---

## 🔍 Troubleshooting Avanzado

### **Problemas de Configuración JSON**
```bash
# Validar JSON
echo "$NODES_CONFIG" | jq .

# Formatear JSON
echo "$NODES_CONFIG" | jq . > nodes-formatted.json

# Verificar tipos permitidos
echo "$NODES_CONFIG" | jq -r 'to_entries[] | select(.value.type | contains("master", "worker", "storage") | not)'
```

### **Problemas de SSH**
```bash
# Debug SSH
ssh -vvv -p $SSH_PORT $SSH_USER@<node-ip>

# Verificar configuración SSH
bash scripts/node-helpers.sh
source scripts/node-helpers.sh
show_nodes_summary
```

### **Problemas de Red**
```bash
# Verificar conectividad entre nodos
for node in $(get_nodes_by_type "master"); do
  echo "Testing $node"
  ssh $SSH_USER@$node "ping -c 3 <other-node-ip>"
done

# Verificar puertos críticos
nmap -p 6443,9345,2379,2380 <master-ip>
```

### **Problemas de Ceph**
```bash
# Estado detallado de Ceph
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph status
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph osd status
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph df
```

### **Problemas de Rancher**
```bash
# Logs de Rancher
kubectl -n cattle-system logs -f deployment/rancher

# Reiniciar Rancher
kubectl -n cattle-system rollout restart deployment/rancher

# Verificar certificados
kubectl -n cattle-system get certificates
kubectl -n cattle-system describe certificate <cert-name>
```

---

## 📊 Métricas y Monitoreo

### **Comandos de Estado**
```bash
# Estado general del clúster
kubectl cluster-info
kubectl get nodes -o wide
kubectl top nodes  # Requiere metrics-server

# Estado de componentes críticos
kubectl get pods -n kube-system | grep -E "(etcd|api|scheduler|controller)"
kubectl get events --sort-by=.metadata.creationTimestamp | tail -20

# Estado de almacenamiento
kubectl get pv,pvc -A
kubectl get storageclass
kubectl -n rook-ceph get cephcluster

# Estado de red
kubectl get svc -A | grep LoadBalancer
kubectl -n metallb-system get ipaddresspool
```

### **Logs Importantes**
```bash
# RKE2
journalctl -u rke2-server -f
journalctl -u rke2-agent -f

# Contenedores del sistema
kubectl logs -n kube-system -l component=etcd
kubectl logs -n kube-system -l component=kube-apiserver

# Aplicaciones
kubectl logs -n cattle-system -l app=rancher
kubectl logs -n rook-ceph -l app=rook-ceph-mon
```

---

## 🔄 Migración y Upgrades

### **Migración desde Configuración Hardcodeada**
```bash
# 1. Backup configuración actual
cp scripts/ scripts-backup/

# 2. Crear NODES_CONFIG desde configuración existente
# Extraer IPs y hostnames de scripts antiguos
grep -r "ssh.*@" scripts-backup/ | grep -o "[0-9]\+\.[0-9]\+\.[0-9]\+\.[0-9]\+"

# 3. Construir JSON manualmente o con script
cat > migrate-config.sh <<'EOF'
#!/bin/bash
# Script de migración ejemplo
MASTERS=("prd3appk8sm1:1.1.1.20" "prd3appk8sm2:1.1.1.21")
WORKERS=("prd3appk8sw1:1.1.1.30" "prd3appk8sw2:1.1.1.31")

echo "NODES_CONFIG='{"
for i, master in ${MASTERS[@]}; do
  # Generar JSON...
done
echo "}'"
EOF
```

### **Upgrade de RKE2**
```bash
# 1. Actualizar versión en .env
RKE2_VERSION=v1.33.0+rke2r1

# 2. Upgrade nodo por nodo
for master in $(get_nodes_by_type "master"); do
  ssh $SSH_USER@$master "
    systemctl stop rke2-server
    curl -sfL https://get.rke2.io | INSTALL_RKE2_VERSION=$RKE2_VERSION sh -
    systemctl start rke2-server
  "
  sleep 60  # Esperar estabilización
done
```

### **Upgrade de Rancher**
```bash
# Actualizar versión en .env
RANCHER_VERSION=v2.12.0

# Upgrade con Helm
helm upgrade rancher rancher-latest/rancher \
  --namespace cattle-system \
  --version $RANCHER_VERSION
```

---

## 📚 Referencias Cruzadas

* **[README.md](../README.md)**: Guía de instalación y configuración básica
* **[nginx-plus.md](./nginx-plus.md)**: Configuración de LoadBalancer externo
* **`.env.example`**: Variables de configuración con ejemplos
* **Logs de instalación**: `logs/` - Debugging detallado por script

---

## 🔮 Roadmap y Futuras Mejoras

### **Versión 2.1 (Planeada)**
- [ ] Soporte para múltiples proveedores cloud (AWS, Azure, GCP)
- [ ] Auto-scaling automático de nodos
- [ ] Integración con Terraform/Ansible
- [ ] Dashboard web para configuración
- [ ] Backup automático programado

### **Versión 2.2 (Investigación)**
- [ ] Soporte para Kubernetes multi-cluster
- [ ] Integración con service mesh (Istio/Linkerd)
- [ ] Compliance automático (CIS benchmarks)
- [ ] AI/ML workloads optimization

---

## 📜 Licencia

Este proyecto está licenciado bajo los términos de la [Licencia MIT](../LICENSE), lo que permite su uso, copia, modificación y distribución con fines personales, académicos o comerciales.

> **Autoría**: Este software fue creado y es mantenido por [@SktCod.ByChisto](https://github.com/adm-gitrepos).  
> Aunque es de código abierto, se agradece el reconocimiento correspondiente en derivados o menciones públicas.

---

## 👤 Autor

Desarrollado por [@SktCod.ByChisto](https://github.com/adm-gitrepos)  
© 2025 – Todos los derechos reservados.
