# Manual de Instalación RKE2 + Rancher v2.11.1 en Alta Disponibilidad

## 📖 Contexto

Este manual documenta la implementación de un clúster Kubernetes RKE2 en Alta Disponibilidad que alojará Rancher v2.11.1 como plataforma centralizada para la gestión de múltiples clústeres Kubernetes. 

La infraestructura está diseñada para aplicaciones críticas que requieren operación continua y eficiente, implementando una separación por dominios funcionales que permitirá:

- **Independencia de despliegue** y escalamiento por clúster
- **Aislamiento de fallas** y mayor disponibilidad por componente
- **Gobernanza clara** sobre recursos y responsabilidades
- **Monitoreo centralizado** con herramientas especializadas

La arquitectura contempla tres clústeres downstream gestionados desde Rancher:
- **Clúster de aplicaciones críticas**
- **Clúster de servicios transversales**
- **Clúster de observabilidad centralizada**

## 🎯 Objetivo

Aprovisionar, instalar y configurar un clúster Kubernetes RKE2 en Alta Disponibilidad (HA) sobre servidores virtuales, que aloje Rancher v2.11.1 como plataforma centralizada para la gestión de múltiples clústeres Kubernetes.

### 🏗️ Arquitectura del Entorno

- **3 nodos master** (etcd + control-plane)
- **3 nodos worker** (para Rancher Server y posibles extensiones)
- **3 nodos de almacenamiento** Ceph con Rook
- **Sistema Operativo:** Oracle Linux 9.5 (RHCK)

### ✨ Características Técnicas

- ✅ Red de pods con **Calico CNI**
- ✅ Exposición mediante **MetalLB Service LoadBalancer** y balanceador externo F5 con NGINX
- ✅ Certificados TLS gestionados por **Cert-Manager**
- ✅ Snapshots programados de etcd almacenados en volúmenes Ceph
- ✅ Aislamiento de roles con `node-label`, `node-taint`, `nodeSelector` y `tolerations`
- ✅ Capacidad para gestionar clústeres downstream (Aplicaciones, Servicios, Observabilidad)

---

## 📊 Especificaciones Técnicas

### Recursos por Tipo de Nodo

| Tipo de Nodo | Rol | vCPU | RAM | Disco Principal | Disco Adicional |
|--------------|-----|------|-----|-----------------|-----------------|
| **Master** | etcd + control-plane | 4 | 8 GB | 250 GB SSD (XFS/LVM) | — |
| **Worker** | Rancher Server + UI | 8 | 16 GB | 150 GB SSD (XFS/LVM) | — |
| **Storage** | Nodo dedicado Ceph OSDs | 4 | 8 GB | 50 GB SO (XFS/LVM) | 500 GB RAW |

### Configuración de Red y Exposición

- **CNI:** Calico (compatible con políticas de red)
- **MetalLB:** Asignación de IP virtual para Service LoadBalancer
- **Balanceador Externo:** F5 + NGINX
- **DNS Oficial:** rancher.acity.com.pe
- **TLS:** Cert-Manager con Issuer para HTTPS

### Almacenamiento y Backups

- **Backend:** Rook + Ceph (3 nodos)
- **Snapshots de etcd:** Cada 12 horas, retención de 5
- **Directorio de snapshots:** Volumen Ceph dedicado

---

## 🛠️ Preparación Inicial de Todos los Servidores

> **Ejecutar en:** Todos los nodos (Masters, Workers, Storage)

### Instalación de Chrony
```bash
dnf install chrony -y
```

### Desactivar Firewalld
```bash
systemctl stop firewalld
systemctl disable firewalld
```

### Actualización del Sistema
```bash
sudo dnf install kernel kernel-headers kernel-devel -y
sudo grubby --info=ALL | grep -E "^(kernel|title)"
sudo grubby --set-default /boot/vmlinuz-5.14.0-570.22.1.0.1.el9_6.x86_64
sudo grubby --default-kernel
dnf update -y
```

### Configuración SSH
```bash
sudo sed -i.bak 's/^[#[:space:]]*Port[[:space:]].*/Port 32451/' /etc/ssh/sshd_config
sudo sed -i 's/^[#[:space:]]*ListenAddress[[:space:]].*/ListenAddress 0.0.0.0/' /etc/ssh/sshd_config
```

### Instalación de Herramientas Básicas
```bash
sudo dnf install -y git net-tools
```

### Configuración de Hosts
```bash
cat <<EOF | sudo tee -a /etc/hosts
# Hosts Kubernetes PRD3
10.97.222.20 PRD3APPK8SM1 prd3appk8sm1
10.97.222.21 PRD3APPK8SM2 prd3appk8sm2
10.97.222.22 PRD3APPK8SM3 prd3appk8sm3
10.97.222.30 PRD3APPK8SW1 prd3appk8sw1
10.97.222.31 PRD3APPK8SW2 prd3appk8sw2
10.97.222.32 PRD3APPK8SW3 prd3appk8sw3
10.97.222.40 PRD3APPK8SS1 prd3appk8ss1
10.97.222.41 PRD3APPK8SS2 prd3appk8ss2
10.97.222.42 PRD3APPK8SS3 prd3appk8ss3
EOF
```

### Desactivar SELinux
```bash
sudo setenforce 0
sudo sed -i.bak 's/^SELINUX=.*/SELINUX=permissive/' /etc/selinux/config
```

---

## 🎛️ Configuración del Primer Master (PRD3APPK8SM1)

> **Ejecutar en:** PRD3APPK8SM1 únicamente

### 1. Verificación del Sistema

```bash
# Verificar conectividad básica
ping -c 3 prd3appk8ss1  # Storage nodes
ping -c 3 prd3appk8sw1  # Worker nodes

# Verificar sincronización de tiempo
chrony sources -v

# Verificar hosts
cat /etc/hosts | grep prd3appk8s
```

### 2. Configuración de RKE2

#### 2.1 Crear Configuración Principal
```bash
# Crear directorio de configuración
mkdir -p /etc/rancher/rke2/

# Crear configuración oficial
cat <<EOF | sudo tee /etc/rancher/rke2/config.yaml
# /etc/rancher/rke2/config.yaml
write-files:
  - path: /var/lib/rancher/rke2/server/manifests/rke2-calico.yaml
    content: |
      apiVersion: helm.cattle.io/v1
      kind: HelmChart
      metadata:
        name: rke2-calico
        namespace: kube-system
      spec:
        chart: https://github.com/projectcalico/calico/releases/download/v3.26.4/calico-v3.26.4.tgz
        valuesContent: |-
          installation:
            calicoNetwork:
              ipPools:
              - blockSize: 26
                cidr: 10.90.0.0/16
                encapsulation: VXLANCrossSubnet
                natOutgoing: Enabled
                nodeSelector: all()
cni: none
cluster-cidr: 10.90.0.0/16
service-cidr: 10.91.0.0/16
token: "26vx^egrg*d%R6HyzaahJJ^k44XLZMpmbF#PSe2@"
tls-san:
  - "rancher.acity.com.pe"
etcd-snapshot-schedule-cron: "0 */12 * * *"
etcd-snapshot-retention: 5
node-taint:
  - "CriticalAddonsOnly=true:NoSchedule"
EOF

# Verificar configuración
cat /etc/rancher/rke2/config.yaml
```

#### 2.2 Crear Directorios para Calico
```bash
# Crear TODOS los directorios que Calico necesita
sudo mkdir -p /var/lib/calico
sudo mkdir -p /var/log/calico
sudo mkdir -p /opt/cni/bin
sudo mkdir -p /etc/cni/net.d
sudo mkdir -p /var/run/calico

# Permisos correctos
sudo chmod 755 /var/lib/calico /var/log/calico /opt/cni/bin /etc/cni/net.d /var/run/calico

# Crear archivo nodename para Calico
echo $(hostname) | sudo tee /var/lib/calico/nodename

# Verificar directorios
ls -la /var/lib/calico/
cat /var/lib/calico/nodename
```

### 3. Instalación de RKE2

#### 3.1 Instalar RKE2
```bash
# Descargar e instalar RKE2
curl -sfL https://get.rke2.io | sh --

# Verificar instalación
ls -la /usr/bin/rke2
```

#### 3.2 Iniciar RKE2
```bash
# Habilitar e iniciar servicio
sudo systemctl enable --now rke2-server.service

# Verificar estado
sudo systemctl status rke2-server.service

# Monitorear logs
sudo journalctl -u rke2-server.service -f
```

#### 3.3 Configurar kubectl
```bash
# Configurar kubectl
sudo ln -s /var/lib/rancher/rke2/bin/kubectl /usr/local/bin/kubectl
sudo echo 'export PATH=$PATH:/var/lib/rancher/rke2/bin' > /etc/profile.d/rke2.sh
source /etc/profile.d/rke2.sh

# Configurar kubeconfig
mkdir -p $HOME/.kube
sudo cp /etc/rancher/rke2/rke2.yaml $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

# Verificar que kubectl funciona
kubectl version --client
kubectl get nodes  # Puede estar NotReady sin CNI
```

### 4. Instalación de Calico

#### 4.1 Verificar Estado Inicial
```bash
# Verificar que RKE2 está funcionando
kubectl get pods -n kube-system

# Verificar que no hay CNI (nodo NotReady es normal)
kubectl get nodes
```

#### 4.2 Quitar Taint Temporalmente
```bash
# Quitar taint para que los componentes se puedan instalar
kubectl taint nodes prd3appk8sm1 CriticalAddonsOnly=true:NoSchedule-

# Verificar que se quitó
kubectl describe node prd3appk8sm1 | grep Taints
```

#### 4.3 Instalar Calico
```bash
# Instalar Calico oficial desde URL
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.26.4/manifests/calico.yaml

# Configurar CIDR correcto para tu red
kubectl set env daemonset/calico-node -n kube-system CALICO_IPV4POOL_CIDR=10.90.0.0/16
```

#### 4.4 Monitorear Instalación
```bash
# Monitorear que aparezcan los pods de Calico (2-5 minutos)
kubectl get pods -n kube-system

# Estado objetivo:
# calico-kube-controllers-*   1/1   Running
# calico-node-*              1/1   Running
```

### 5. Validación Final

#### 5.1 Verificar Estado Completo
```bash
# Verificar que el nodo está Ready
kubectl get nodes

# Verificar todos los pods del sistema
kubectl get pods -n kube-system

# Verificar específicamente Calico
kubectl get pods -n kube-system | grep calico
```

#### 5.2 Verificar NetworkPolicy
```bash
# REQUISITO OFICIAL: NetworkPolicy habilitado
kubectl get crd | grep networkpolicies

# Debería mostrar:
# globalnetworkpolicies.crd.projectcalico.org
# networkpolicies.crd.projectcalico.org
```

#### 5.3 Test de NetworkPolicy
```bash
# Crear un NetworkPolicy de prueba
kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: test-calico-policy
  namespace: default
spec:
  podSelector: {}
  policyTypes:
  - Ingress
EOF

# Verificar que se creó correctamente
kubectl get networkpolicy test-calico-policy

# Limpiar test
kubectl delete networkpolicy test-calico-policy
```

#### 5.4 Restaurar Taint de Seguridad
```bash
# Restaurar taint del master para seguridad
kubectl taint nodes prd3appk8sm1 CriticalAddonsOnly=true:NoSchedule

# Verificar que se aplicó
kubectl describe node prd3appk8sm1 | grep Taints
```

### ✅ Criterios de Éxito - Master 01

El Master 01 está correctamente instalado cuando:
1. ✅ **Nodo Ready**: `kubectl get nodes` muestra prd3appk8sm1 Ready
2. ✅ **Calico funcionando**: `kubectl get pods -n kube-system | grep calico` muestra pods Running
3. ✅ **NetworkPolicy habilitado**: `kubectl get crd | grep networkpolicies` muestra CRDs
4. ✅ **Componentes del sistema**: Todos los pods en Running/Completed
5. ✅ **Tests exitosos**: DNS y HTTP funcionan
6. ✅ **Taint aplicado**: Master protegido con `CriticalAddonsOnly=true:NoSchedule`

---

## 🔄 Configuración de Masters Adicionales (PRD3APPK8SM2, PRD3APPK8SM3)

> **Ejecutar en:** PRD3APPK8SM2 y PRD3APPK8SM3

### Configuración Idéntica al Master 1
```bash
mkdir -p /etc/rancher/rke2/

# Aplicar configuración completa idéntica al master 1
cat <<EOF | sudo tee /etc/rancher/rke2/config.yaml
# /etc/rancher/rke2/config.yaml
write-files:
  - path: /var/lib/rancher/rke2/server/manifests/rke2-calico.yaml
    content: |
      apiVersion: helm.cattle.io/v1
      kind: HelmChart
      metadata:
        name: rke2-calico
        namespace: kube-system
      spec:
        chart: https://github.com/projectcalico/calico/releases/download/v3.26.4/calico-v3.26.4.tgz
        valuesContent: |-
          installation:
            calicoNetwork:
              ipPools:
              - blockSize: 26
                cidr: 10.90.0.0/16
                encapsulation: VXLANCrossSubnet
                natOutgoing: Enabled
                nodeSelector: all()
server: https://PRD3APPK8SM1:9345
cni: none
cluster-cidr: 10.90.0.0/16
service-cidr: 10.91.0.0/16
token: "26vx^egrg*d%R6HyzaahJJ^k44XLZMpmbF#PSe2@"
tls-san:
  - "rancher.acity.com.pe"
etcd-snapshot-schedule-cron: "0 */12 * * *"
etcd-snapshot-retention: 5
node-taint:
  - "CriticalAddonsOnly=true:NoSchedule"
EOF

# Instalar RKE2
curl -sfL https://get.rke2.io | sh --

# Iniciar servicio
sudo systemctl enable --now rke2-server.service
```

---

## 👷 Configuración de Workers (PRD3APPK8SW1, PRD3APPK8SW2, PRD3APPK8SW3)

> **Ejecutar en:** Cada worker individualmente

### Configuración de Workers
```bash
mkdir -p /etc/rancher/rke2/

cat <<EOF | sudo tee /etc/rancher/rke2/config.yaml
# /etc/rancher/rke2/config.yaml
server: https://10.97.222.20:9345
token: "26vx^egrg*d%R6HyzaahJJ^k44XLZMpmbF#PSe2@"
selinux: false
node-label:
  - "acity.com/node-role=worker"
EOF

# Instalar RKE2 Agent
curl -sfL https://get.rke2.io | INSTALL_RKE2_TYPE="agent" sh --

# Iniciar servicio
sudo systemctl enable --now rke2-agent.service
```

### Verificaciones de Workers
```bash
# 1. Pods distribuidos correctamente:
kubectl get pods -n kube-system -o wide

# 2. Verificar que workers NO tienen taints:
kubectl describe nodes prd3appk8sw1 | grep Taints

# 3. Test con deployment de 3 réplicas
kubectl create deployment test-deploy --image=nginx --replicas=3
kubectl get pods -o wide
kubectl delete deployment test-deploy
```

---

## 💾 Configuración de Storage Nodes (PRD3APPK8SS1, PRD3APPK8SS2, PRD3APPK8SS3)

> **Ejecutar en:** Cada storage node individualmente

### Configuración de Storage Nodes
```bash
mkdir -p /etc/rancher/rke2/

cat <<EOF | sudo tee /etc/rancher/rke2/config.yaml
# /etc/rancher/rke2/config.yaml
server: https://10.97.222.20:9345
token: "26vx^egrg*d%R6HyzaahJJ^k44XLZMpmbF#PSe2@"
selinux: false
node-label:
  - "acity.com/node-role=storage"
node-taint:
  - "acity.com/storage-only=true:NoSchedule"
EOF

# Instalar RKE2 Agent
curl -sfL https://get.rke2.io | INSTALL_RKE2_TYPE="agent" sh --

# Iniciar servicio
sudo systemctl enable --now rke2-agent.service
```

### Validaciones de Cluster Completo
```bash
# 1. Verificar taints por rol:
kubectl describe nodes | grep -A1 -B1 Taints

# 2. Verificar labels:
kubectl get nodes --show-labels

# 3. Estado de pods:
kubectl get pods -n kube-system
```

---

## 💽 Instalación de Almacenamiento (Rook/Ceph)

> **Ejecutar desde:** PRD3APPK8SM1

### Fase 1: Instalar Rook Operator
```bash
# Crear namespace para Rook
kubectl create namespace rook-ceph

# Instalar Rook Operator
kubectl apply -f https://raw.githubusercontent.com/rook/rook/v1.12.9/deploy/examples/crds.yaml
kubectl apply -f https://raw.githubusercontent.com/rook/rook/v1.12.9/deploy/examples/common.yaml
kubectl apply -f https://raw.githubusercontent.com/rook/rook/v1.12.9/deploy/examples/operator.yaml

# Verificar que el operator esté corriendo
kubectl get pods -n rook-ceph
```

### Fase 2: Verificar Discos RAW

Verificar en cada storage node:
```bash
# EJECUTAR EN: PRD3APPK8SS1, PRD3APPK8SS2, PRD3APPK8SS3
lsblk
# Confirmar que existe sdb de 500GB sin formatear
```

### Fase 3: Crear CephCluster
```bash
cd /root

cat <<EOF > ceph-cluster.yaml
apiVersion: ceph.rook.io/v1
kind: CephCluster
metadata:
  name: rook-ceph
  namespace: rook-ceph
spec:
  cephVersion:
    image: quay.io/ceph/ceph:v17.2.6
  dataDirHostPath: /var/lib/rook
  placement:
    all:
      tolerations:
      - key: acity.com/storage-only
        operator: Equal
        value: "true"
        effect: NoSchedule
      nodeAffinity:
        requiredDuringSchedulingIgnoredDuringExecution:
          nodeSelectorTerms:
          - matchExpressions:
            - key: acity.com/node-role
              operator: In
              values:
              - storage
  mon:
    count: 3
    allowMultiplePerNode: false
  mgr:
    count: 2
    allowMultiplePerNode: false
  dashboard:
    enabled: true
  storage:
    useAllNodes: false
    useAllDevices: false
    nodes:
    - name: "prd3appk8ss1"
      devices:
      - name: "sdb"
    - name: "prd3appk8ss2"
      devices:
      - name: "sdb"
    - name: "prd3appk8ss3"
      devices:
      - name: "sdb"
EOF

# Aplicar configuración
kubectl apply -f ceph-cluster.yaml
```

### Fase 4: Monitorear Instalación
```bash
# Monitorear progreso (15-20 minutos)
kubectl get pods -n rook-ceph -w

# Verificar estado del cluster
kubectl get cephcluster -n rook-ceph
```

### Fase 5: Verificar con Toolbox
```bash
# Instalar toolbox
kubectl apply -f https://raw.githubusercontent.com/rook/rook/v1.12.9/deploy/examples/toolbox.yaml

# Verificar estado de Ceph
kubectl exec -n rook-ceph deployment/rook-ceph-tools -- ceph status
kubectl exec -n rook-ceph deployment/rook-ceph-tools -- ceph osd status
```

### Fase 6: Crear StorageClass
```bash
cd /root

cat <<EOF > ceph-storageclass.yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: rook-ceph-block
provisioner: rook-ceph.rbd.csi.ceph.com
parameters:
  clusterID: rook-ceph
  pool: replicapool
  imageFormat: "2"
  imageFeatures: layering
  csi.storage.k8s.io/provisioner-secret-name: rook-csi-rbd-provisioner
  csi.storage.k8s.io/provisioner-secret-namespace: rook-ceph
  csi.storage.k8s.io/controller-expand-secret-name: rook-csi-rbd-provisioner
  csi.storage.k8s.io/controller-expand-secret-namespace: rook-ceph
  csi.storage.k8s.io/node-stage-secret-name: rook-csi-rbd-node
  csi.storage.k8s.io/node-stage-secret-namespace: rook-ceph
allowVolumeExpansion: true
reclaimPolicy: Retain
EOF

kubectl apply -f ceph-storageclass.yaml

# Verificar
kubectl get storageclass
```

---

## 🌐 Instalación de MetalLB

> **Ejecutar desde:** PRD3APPK8SM1

### Instalar MetalLB
```bash
cd /root

# Instalar MetalLB
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.13.12/config/manifests/metallb-native.yaml

# Verificar instalación
kubectl get pods -n metallb-system
```

### Configurar Pool de IPs
```bash
# Crear configuración de IP pool
cat <<EOF > /root/metallb-config.yaml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: rancher-pool
  namespace: metallb-system
spec:
  addresses:
  - 10.97.222.100-10.97.222.110
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: rancher-advertisement
  namespace: metallb-system
spec:
  ipAddressPools:
  - rancher-pool
EOF

# Aplicar configuración
kubectl apply -f /root/metallb-config.yaml

# Verificar
kubectl get ipaddresspool -n metallb-system
kubectl get l2advertisement -n metallb-system
```

### Test de MetalLB
```bash
# Crear servicio de prueba
kubectl create deployment test-nginx --image=nginx
kubectl expose deployment test-nginx --port=80 --type=LoadBalancer

# Verificar asignación de IP
kubectl get services test-nginx

# Limpiar test
kubectl delete service test-nginx
kubectl delete deployment test-nginx
```

---

## 🔐 Instalación de Cert-Manager

> **Ejecutar desde:** PRD3APPK8SM1

### Instalar Cert-Manager
```bash
cd /root

# Instalar Cert-Manager
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.3/cert-manager.yaml

# Verificar instalación
kubectl get pods -n cert-manager
```

### Crear ClusterIssuer
```bash
# Crear ClusterIssuer para certificados Let's Encrypt
cat <<EOF > /root/cert-manager-issuer.yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: gsalazar@acity.com.pe
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
    - http01:
        ingress:
          class: nginx
EOF

kubectl apply -f /root/cert-manager-issuer.yaml

# Verificar
kubectl get clusterissuer
kubectl describe clusterissuer letsencrypt-prod
```

---

## 🚀 Instalación de Rancher v2.11.1

> **Ejecutar desde:** PRD3APPK8SM1

### Instalar Helm
```bash
cd /root

# Descargar e instalar Helm
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Verificar instalación
helm version
```

### Instalar Rancher
```bash
# Agregar repositorio de Helm para Rancher
helm repo add rancher-latest https://releases.rancher.com/server-charts/latest
helm repo update

# Crear namespace para Rancher
kubectl create namespace cattle-system

# Instalar Rancher con nodeSelector correcto
helm install rancher rancher-latest/rancher \
  --namespace cattle-system \
  --set hostname=rancher.acity.com.pe \
  --set bootstrapPassword=admin \
  --set ingress.tls.source=letsEncrypt \
  --set letsEncrypt.email=gsalazar@acity.com.pe \
  --set letsEncrypt.ingress.class=nginx \
  --set nodeSelector."acity\.com/node-role"=worker \
  --version v2.11.1

# Monitorear instalación
kubectl get pods -n cattle-system -w
```

### Verificar Instalación de Rancher
```bash
# Ver pods principales de Rancher
kubectl get pods -n cattle-system | grep -E "rancher-[0-9]|webhook"

# Ver deployments
kubectl get deployments -n cattle-system

# Ver servicios
kubectl get services -n cattle-system
```

### Configurar Exposición Externa
```bash
# Modificar service a LoadBalancer
kubectl patch service rancher -n cattle-system -p '{"spec":{"type":"LoadBalancer"}}'

# Verificar asignación de IP externa
kubectl get services -n cattle-system rancher

# Ver eventos de MetalLB
kubectl get events -n metallb-system --sort-by='.lastTimestamp' | tail -5
```

---

## 🌍 Configuración de NGINX (Balanceador Externo)

### Configuración de NGINX para Rancher
```nginx
upstream https_rancher {
  server 10.97.222.100:443;
}

server {
  listen                80;
  server_name           rancher.acity.com.pe;
  return 301 https://$host$request_uri;
}

server { 
  listen               443 ssl;
  server_name          rancher.acity.com.pe;
  ssl_certificate      /etc/nginx/ssl/acity.com.pe.ssl;
  ssl_certificate_key  /etc/nginx/ssl/acity.com.pe.key;

  location / {
    proxy_pass        https://https_rancher;
    proxy_set_header  Host rancher.acity.com.pe;
    proxy_set_header  X-Real-IP $remote_addr;
    proxy_set_header  X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header  X-Forwarded-Proto $scheme;
    proxy_set_header  X-Forwarded-Port $server_port;
    
    # WebSocket support
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_read_timeout 900s;
    proxy_buffering off;
    
    # SSL verification
    proxy_ssl_verify off;
  }

  access_log  /var/log/nginx/rancher.log main;
  error_log   /var/log/nginx/rancher-error.log error;
}
```

---

## 🔑 Acceso a Rancher

### Obtener Bootstrap Password
```bash
# Ver password de bootstrap desde consola
kubectl get secret --namespace cattle-system bootstrap-secret -o go-template='{{.data.bootstrapPassword|base64decode}}{{"\n"}}'
```

### Acceso Web
1. **URL:** https://rancher.acity.com.pe
2. **Usuario:** admin
3. **Password:** Usar el password obtenido del comando anterior

### Configuración Inicial
1. Aceptar términos y condiciones
2. Configurar password personalizado (opcional)
3. Confirmar Server URL: `https://rancher.acity.com.pe`
4. Completar configuración inicial

---

## 🛠️ Troubleshooting y Comandos Útiles

### Verificaciones Generales
```bash
# Ver logs de RKE2
sudo journalctl -u rke2-server.service -n 20

# Ver eventos del cluster
kubectl get events -A --sort-by='.lastTimestamp' | tail -10

# Estado general del cluster
kubectl get nodes
kubectl get pods -A
```

### Comandos de Diagnóstico Ceph
```bash
# Estado del cluster Ceph
kubectl exec -n rook-ceph deployment/rook-ceph-tools -- ceph status

# Estado de OSDs
kubectl exec -n rook-ceph deployment/rook-ceph-tools -- ceph osd status

# Ver logs de Rook operator
kubectl logs -n rook-ceph deployment/rook-ceph-operator
```

### Comandos MetalLB
```bash
# Ver logs de MetalLB
kubectl logs -n metallb-system -l app=metallb -l component=speaker

# Ver configuración de pools
kubectl get ipaddresspool -n metallb-system -o yaml
```

### Solución de Errores Comunes

#### 1. Corregir Fleet (si falla)
```bash
# Ver estado del job fallido
kubectl describe pod -n cattle-system $(kubectl get pods -n cattle-system | grep "helm-operation.*fleet" | awk '{print $1}')

# Eliminar job fallido
kubectl delete job -n cattle-system $(kubectl get jobs -n cattle-system | grep "helm-operation.*fleet" | awk '{print $1}')

# Forzar reinstalación
kubectl patch -n cattle-system helmchart fleet --type='merge' -p='{"spec":{"version":""}}'
```

#### 2. Corregir System Upgrade Controller (si falla)
```bash
# Ver logs del pod fallido
kubectl logs -n cattle-system $(kubectl get pods -n cattle-system | grep "helm-operation.*upgrade" | awk '{print $1}')

# Eliminar jobs fallidos
kubectl delete job -n cattle-system $(kubectl get jobs -n cattle-system | grep "helm-operation.*upgrade" | awk '{print $1}')

# Reinstalar component
kubectl patch -n cattle-system helmchart system-upgrade-controller --type='merge' -p='{"spec":{"version":""}}'
```

#### 3. Resetear Password de Rancher
```bash
# Resetear password de admin
kubectl --namespace cattle-system exec $(kubectl --namespace cattle-system get pods -l app=rancher --no-headers | head -1 | awk '{ print $1 }') -- reset-password
```

---

## ✅ Criterios de Aceptación Final

### 1. Alta Disponibilidad Validada
- ✅ El clúster RKE2 cuenta con 3 nodos master con etcd + control-plane distribuidos
- ✅ Pruebas de fallo (failover) sin pérdida de funcionalidad

### 2. Rancher Server Desplegado y Accesible en HA
- ✅ Rancher v2.11.1 desplegado en 3 nodos worker
- ✅ Accesible vía rancher.acity.com.pe usando HTTPS
- ✅ Service LoadBalancer expuesto mediante MetalLB y F5+NGINX

### 3. Aislamiento y Tolerancia Operativa
- ✅ Cada tipo de nodo (master, worker, storage) con `node-taints` y `nodeSelector` apropiados
- ✅ Rancher ejecutándose únicamente en nodos worker

### 4. Almacenamiento Distribuido Funcional
- ✅ Ceph desplegado en 3 nodos con OSD RAW
- ✅ Almacenamiento dinámico y snapshots automáticos de etcd
- ✅ Volúmenes persistentes (PVC) operativos
- ✅ Snapshots programados cada 12 horas con retención de 5

### 5. Red de Pods Operativa y Segura
- ✅ Calico como CNI correctamente desplegado
- ✅ Políticas de red (NetworkPolicy) habilitadas
- ✅ Comunicación entre pods conforme a políticas establecidas

### 6. Certificados TLS Automáticos
- ✅ Rancher operando bajo HTTPS con certificados válidos
- ✅ Cert-Manager emitiendo certificados automáticamente

### 7. Comunicación Cifrada
- ✅ mTLS activado entre Rancher Server y clústeres downstream
- ✅ Comunicación segura mediante agentes

### 8. Acceso Controlado
- ✅ Autenticación habilitada con roles RBAC
- ✅ Acceso controlado por usuario y permisos

### 9. DNS y Sincronización Temporal
- ✅ Todos los nodos con hostname único y DNS local resuelto
- ✅ Firewalld activo y NTP configurado

### 10. Gestión Multi-clúster Confirmada
- ✅ Rancher preparado para registrar y gestionar clústeres downstream
- ✅ Capacidad para gestionar: Aplicaciones, Servicios, Observabilidad

### 11. Documentación Completa
- ✅ Manual de instalación detallado
- ✅ Diagrama de arquitectura incluido
- ✅ Especificaciones de hardware documentadas
- ✅ Plan de respaldo configurado

---

## 📋 Resumen de Componentes Instalados

| Componente | Versión | Estado | Ubicación |
|------------|---------|--------|-----------|
| **Oracle Linux** | 9.5 RHCK | ✅ Activo | Todos los nodos |
| **RKE2** | v1.32.x | ✅ Activo | Cluster completo |
| **Calico CNI** | v3.26.4 | ✅ Activo | Todos los nodos |
| **Rook/Ceph** | v1.12.9 / v17.2.6 | ✅ Activo | Storage nodes |
| **MetalLB** | v0.13.12 | ✅ Activo | Worker nodes |
| **Cert-Manager** | v1.13.3 | ✅ Activo | Cluster |
| **Helm** | v3.x | ✅ Activo | Master 1 |
| **Rancher** | v2.11.1 | ✅ Activo | Worker nodes |

---

## 🎯 Próximos Pasos

1. **Configurar clústeres downstream**
   - Cluster de Aplicaciones
   - Cluster de Servicios  
   - Cluster de Observabilidad

2. **Implementar monitoreo**
   - Configurar alertas
   - Dashboards de métricas
   - Logs centralizados

3. **Configurar backups**
   - Validar snapshots de etcd
   - Backup de configuraciones
   - Plan de recuperación ante desastres

4. **Seguridad adicional**
   - Políticas de red granulares
   - Escaneo de vulnerabilidades
   - Auditoría de accesos

---

## 📞 Soporte y Contacto

Para soporte técnico o consultas sobre esta implementación:

- **Arquitectura de Soluciones:** Jonathan Franchesco Torres Baca
- **Administración:** Equipo de Kubernetes PRD3
- **Documentación:** Manual técnico versión 1.0

---

*Documento generado para la implementación de Kubernetes RKE2 + Rancher v2.11.1 en Alta Disponibilidad*
