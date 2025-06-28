# 🚀 RKE2 + Rancher HA Installer

Instalador modular, automatizado y robusto para clústeres de Kubernetes RKE2 en alta disponibilidad con integración opcional de Rancher, Ceph y MetalLB. Completamente refactorizado con configuración centralizada y funciones helper para máxima flexibilidad y mantenimiento.

---

## ❗️⚠️ IMPORTANTE: Requisitos Previos Críticos

> **Estas configuraciones deben estar listas ANTES de ejecutar cualquier script**

* 🔴 **DNS**: Asegúrate de que el dominio definido en `.env` (ej. `${RANCHER_DOMAIN}`) resuelva correctamente hacia la IP del LoadBalancer externo (NGINX Plus o MetalLB).
* 🔴 **NGINX Plus**: Si usas NGINX Plus como proxy, debe estar configurado con los siguientes upstreams:
  * Kubernetes API: `6443` y `9345`
  * Rancher UI/API: `80` y `443`
    Consulta el archivo [`docs/nginx-plus.md`](docs/nginx-plus.md) para más detalles.
* 🔴 **Configuración de Nodos**: Todos los nodos deben estar definidos en la variable `NODES_CONFIG` del archivo `.env` con formato JSON.
* 🔴 **Contraseña unificada**: Todos los nodos deben tener la **misma contraseña SSH para el usuario root**, ya que los scripts automatizados ejecutan comandos remotos sin intervención.

Sin esto, la instalación de Rancher, la comunicación entre nodos y la automatización completa pueden fallar o requerir intervención manual.

---

## 🆕 Nuevas Características v2.0

### ✨ **Configuración Centralizada**
- **Un solo archivo** `.env` para toda la configuración
- **Formato JSON** para definición de nodos con tipos (master, worker, storage)
- **Escalabilidad** fácil: agrega/quita nodos modificando solo el `.env`
- **Consistencia** garantizada entre todos los scripts

### 🔧 **Funciones Helper**
- **Biblioteca centralizada** `scripts/node-helpers.sh`
- **Funciones reutilizables** para manejo de nodos por tipo
- **Validación automática** de configuración
- **Generación dinámica** de configuraciones YAML

### 🚀 **Instalación Automática**
- **Auto-instalación** de dependencias (jq, helm, sshpass)
- **Detección de SO** y uso del gestor de paquetes apropiado
- **Verificación de prerequisitos** exhaustiva antes de iniciar

---

## 📦 Características

* **Configuración centralizada** en archivo `.env` con formato JSON para nodos
* **Instalación 100% automatizada** vía shell scripts con funciones helper
* **Soporte para tres modos** de ejecución: `full`, `no-rancher`, `only-k8s`
* **Auto-instalación de dependencias** (jq, helm, certificados)
* **Configuración dinámica de SSH** sin contraseña con detección automática
* **Validación exhaustiva** de requisitos (RAM, discos, módulos kernel, etc.)
* **Despliegue inteligente de Ceph** con configuración automática por nodos storage
* **Integración completa con MetalLB** (L2) y LoadBalancer externo
* **Instalación de Rancher HA** con TLS automático vía Let's Encrypt
* **Pruebas de Alta Disponibilidad** con simulación de fallos reales
* **Validación integral** HTTPS, DNS y test de despliegue
* **Monitoreo en tiempo real** y logging detallado por paso

---

## ⚙️ Estructura del Proyecto

```
├── scripts/
│   ├── node-helpers.sh              # 🆕 Funciones helper centralizadas
│   ├── 00-check-prereqs.sh          # Valida requisitos y auto-instala dependencias
│   ├── 01-setup-ssh.sh              # Configura SSH sin contraseña (dinámico)
│   ├── 02-install-cluster.sh        # Instala RKE2 usando configuración centralizada
│   ├── 03-install-ceph.sh           # Despliega Rook-Ceph con nodos auto-detectados
│   ├── 04-install-metallb.sh        # Configura MetalLB con validación completa
│   ├── 05-install-rancher.sh        # Instala Rancher HA con auto-configuración
│   ├── 06-verify-installation.sh    # Verificación exhaustiva de todos los componentes
│   ├── 07-test-ha.sh                # Pruebas reales de Alta Disponibilidad
│   └── 08-dns-config.sh             # Configuración DNS y validación final
├── install-all.sh                   # Orquestador principal con verificaciones
├── .env.example                     # 🆕 Configuración centralizada con NODES_CONFIG
├── README.md
├── docs/
│   ├── index.md                     # Documentación técnica completa
│   └── nginx-plus.md                # Configuración de proxy externo
└── logs/                            # Logs detallados por script y timestamp
```

## 📌 Scripts y Funciones

| Script                      | Descripción                                      | Nuevas Características |
| --------------------------- | ------------------------------------------------ | --------------------- |
| `node-helpers.sh`           | 🆕 Funciones centralizadas para manejo de nodos | Configuración JSON, validación, generación YAML |
| `00-check-prereqs.sh`       | Verifica prerequisitos y auto-instala dependencias | Auto-instalación jq/helm, validación dinámica |
| `01-setup-ssh.sh`           | Configura SSH sin contraseña en todos los nodos | Detección automática de nodos, validación post-config |
| `02-install-cluster.sh`     | Instala RKE2: master, worker y storage          | Configuración dinámica por tipo, monitoreo en tiempo real |
| `03-install-ceph.sh`        | Despliega Rook + Ceph en nodos de almacenamiento | Auto-detección storage, configuración dinámica |
| `04-install-metallb.sh`     | Configura MetalLB con IPs virtuales             | Validación de red, pruebas de conectividad |
| `05-install-rancher.sh`     | Instala Rancher en modo HA con Helm             | Auto-instalación Helm, configuración SSL completa |
| `06-verify-installation.sh` | Ejecuta test exhaustivo de todos los componentes | Aplicación de prueba integral, métricas detalladas |
| `07-test-ha.sh`             | Simula failover y prueba recuperación real      | Monitoreo continuo, pruebas de fallo reales |
| `08-dns-config.sh`          | Configuración DNS final y resumen completo      | Validación web, extracción de credenciales |

---

## 🚀 Modos de Instalación

```bash
./install-all.sh [modo]
```

### Modos disponibles:

| Modo         | Descripción                                                     |
| ------------ | --------------------------------------------------------------- |
| `full`       | Instala todo el stack completo: RKE2 + Ceph + MetalLB + Rancher |
| `no-rancher` | Instala todo excepto Rancher                                    |
| `only-k8s`   | Solo configura el clúster RKE2 (sin Ceph, MetalLB ni Rancher)   |

---

## 🔧 Configuración Centralizada (Nuevo)

### 📄 Variables `.env.example`

```dotenv
# 🌍 Configuración Básica
ROOT_PASSWORD=TuPasswordSeguraAqui
LB_IP=1.1.1.1
SSH_PORT=22
SSH_USER=root
RANCHER_DOMAIN=rancher.midominio.com     # Rancher UI
K8S_API_DOMAIN=api.midominio.com         # Kubernetes API
K8S_REG_DOMAIN=reg.midominio.com         # RKE2 Registration
BOOTSTRAP_PASSWORD=AdminPassword123
RKE2_VERSION=v1.32.1+rke2r1
RANCHER_VERSION=v2.11.1
CLUSTER_TOKEN=TokenSuperSeguro123
METALLB_IP_RANGE=1.1.1.200-1.1.1.210

# 🏗️ CONFIGURACIÓN DE NODOS (JSON) - ¡NUEVA CARACTERÍSTICA!
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

### 🔑 Ventajas de la Nueva Configuración:
- ✅ **Un solo lugar** para modificar nodos
- ✅ **Escalabilidad** fácil: agrega/quita nodos modificando solo JSON
- ✅ **Flexibilidad** de tipos: master, worker, storage
- ✅ **Consistencia** garantizada entre todos los scripts
- ✅ **Validación automática** de configuración JSON

---

## 🔧 Requisitos Previos Generales

* Todos los nodos deben tener:
  * Sistema operativo Oracle Linux 8 o equivalente (RHEL, CentOS, etc.)
  * Acceso SSH como root (misma contraseña en todos los nodos)
  * Disco `/dev/sdb` disponible para nodos storage (Ceph)
  * Conectividad entre nodos y al exterior (para Helm, Rancher, etc.)
  * Hostnames definidos correctamente (idealmente FQDN)
  * Mínimo 4GB RAM y 20GB espacio en disco

* **🆕 Auto-instalación**: Los scripts instalan automáticamente dependencias faltantes:
  * `jq` (requerido para procesar NODES_CONFIG)
  * `helm` (si no está presente)
  * `sshpass`, `curl`, `wget`, `tar`

---

## 🚀 Guía de Instalación Rápida

### 1. **Preparación Inicial**
```bash
# Clonar repositorio
git clone <repo-url>
cd rke2-rancher-ha-installer

# Configurar entorno
cp .env.example .env
nano .env  # Editar NODES_CONFIG y demás variables
```

### 2. **Validar Configuración**
```bash
# Verificar prerequisitos (auto-instala dependencias)
bash scripts/00-check-prereqs.sh
```

### 3. **Instalación Completa**
```bash
# Instalación full stack
./install-all.sh full

# O instalación paso a paso para debugging
bash scripts/01-setup-ssh.sh
bash scripts/02-install-cluster.sh
# ... etc
```

### 4. **Verificación Final**
```bash
# Verificar instalación completa
bash scripts/06-verify-installation.sh

# Probar Alta Disponibilidad
bash scripts/07-test-ha.sh

# Configuración DNS final
bash scripts/08-dns-config.sh
```

---

## 🧪 Pruebas y Validaciones Incluidas

### 🔍 **Verificaciones Automáticas:**
* **Prerequisitos**: SO, RAM, disco, módulos kernel, conectividad SSH
* **Nodos**: Estado Ready, etiquetas correctas, distribución por tipo
* **Sistema**: etcd quorum, API server, CNI (Calico), kube-proxy
* **Almacenamiento**: Ceph cluster, OSDs, MONs, StorageClass funcional
* **Red**: MetalLB pools, LoadBalancer IPs, conectividad externa
* **Rancher**: Pods HA, certificados SSL, acceso HTTPS
* **Aplicaciones**: Despliegue de prueba con PVC y LoadBalancer

### 🔄 **Pruebas de Alta Disponibilidad:**
* **Falla de master principal**: Simulación real con monitoreo continuo
* **Recuperación automática**: Verificación de rejoining al clúster
* **Failover de Rancher**: Recreación automática de pods
* **Snapshots etcd**: Backup automático y manual
* **Tolerancia de red**: Conectividad entre nodos y puertos críticos

---

## 🛠️ Comandos Útiles Post-Instalación

```bash
# Estado del clúster
kubectl get nodes -o wide
kubectl get pods -A

# Servicios LoadBalancer
kubectl get svc -A | grep LoadBalancer

# Estado de Ceph
kubectl -n rook-ceph get cephcluster
kubectl -n rook-ceph get pods

# Estado de Rancher
kubectl -n cattle-system get pods
kubectl -n cattle-system get svc

# Eventos recientes
kubectl get events --sort-by=.metadata.creationTimestamp | tail -20

# Logs del sistema
journalctl -u rke2-server -f

# Backup de etcd
rke2 etcd-snapshot save --name backup-$(date +%s)
```

---

## 🔧 Troubleshooting

### 🚨 **Problemas Comunes:**

**Error: "jq no encontrado"**
```bash
# Los scripts auto-instalan jq, pero si falla:
yum install -y jq  # RHEL/CentOS/Oracle Linux
dnf install -y jq  # Fedora
apt install -y jq  # Debian/Ubuntu
```

**Error: "NODES_CONFIG no es JSON válido"**
```bash
# Validar JSON:
echo "$NODES_CONFIG" | jq .
# Verificar que no falten comillas o comas
```

**Error: "No se puede conectar a nodos"**
```bash
# Verificar SSH y credenciales:
bash scripts/00-check-prereqs.sh
# Verificar ROOT_PASSWORD en .env
```

**Error: "DNS no resuelve"**
```bash
# Configurar DNS temporal:
echo "$LB_IP $RANCHER_DOMAIN" >> /etc/hosts
```

### 📋 **Logs Detallados:**
Cada script genera logs detallados en `logs/` con timestamp para debugging fácil.

---

## 📄 Documentación Completa

* **[Documentación Técnica](docs/index.md)**: Arquitectura, configuración avanzada, extensiones
* **[Configuración NGINX Plus](docs/nginx-plus.md)**: Setup de LoadBalancer externo
* **Logs de Instalación**: `logs/` - Logs detallados por script y timestamp
* **Resumen del Clúster**: `cluster-summary.md` - Generado automáticamente al finalizar

---

## 🔄 Migración desde Versión Anterior

Si tienes la versión anterior con nodos hardcodeados:

1. **Backup tu configuración actual**
2. **Actualizar `.env`** con el nuevo formato `NODES_CONFIG`
3. **Agregar `scripts/node-helpers.sh`**
4. **Usar los scripts actualizados**

Ejemplo de migración:
```bash
# Versión anterior (hardcodeado)
NODES=("server1" "server2" "server3")

# Nueva versión (JSON en .env)
NODES_CONFIG='{"server1": {"ip": "1.1.1.1", "type": "master", "primary": true}, ...}'
```

---

## 📜 Licencia

Este proyecto está licenciado bajo los términos de la [Licencia MIT](LICENSE), lo que permite su uso, copia, modificación y distribución con fines personales, académicos o comerciales.

> **Autoría**: Este software fue creado y es mantenido por [@SktCod.ByChisto](https://github.com/adm-gitrepos).  
> Aunque es de código abierto, se agradece el reconocimiento correspondiente en derivados o menciones públicas.

---

## 👤 Autor

Desarrollado por [@SktCod.ByChisto](https://github.com/adm-gitrepos)  
© 2025 – Todos los derechos reservados.
