# 🚀 NGINX Plus LoadBalancer Configuration

## 📋 Resumen

Este documento describe la configuración de **NGINX Plus** como LoadBalancer externo para el cluster RKE2 + Rancher HA. Utiliza un enfoque elegante basado en **subdominios** donde todos los servicios responden por puerto **443** (HTTPS) y se enrutan internamente a los puertos correspondientes.

## 🏗️ Arquitectura de Nodos

| Hostname | IP | Tipo | Servicios | Puertos |
|----------|----|----|-----------|---------|
| **prd3appk8sm1** | `192.168.1.101` | master+primary | API+Registration+Rancher | 6443, 9345, 443 |
| **prd3appk8sm2** | `192.168.1.102` | master | API+Registration+Rancher | 6443, 9345, 443 |
| **prd3appk8sm3** | `192.168.1.103` | master | API+Registration+Rancher | 6443, 9345, 443 |
| **prd3appk8sw1** | `192.168.1.111` | worker | Workloads | - |
| **prd3appk8sw2** | `192.168.1.112` | worker | Workloads | - |
| **prd3appk8sw3** | `192.168.1.113` | worker | Workloads | - |
| **prd3appk8ss1** | `192.168.1.121` | storage | Ceph OSDs | - |
| **prd3appk8ss2** | `192.168.1.122` | storage | Ceph OSDs | - |
| **prd3appk8ss3** | `192.168.1.123` | storage | Ceph OSDs | - |

**🎯 LoadBalancer:** `192.168.1.50` (NGINX Plus)

## 🌐 Esquema de Subdominios

### ✅ Enfoque Recomendado (Elegante)
```
api.midominio.com:443      → proxy_pass hacia masters:6443 (Kubernetes API)
reg.midominio.com:443      → proxy_pass hacia masters:9345 (Registration)  
rancher.midominio.com:443  → proxy_pass hacia masters:443 (Rancher UI)
```

### ❌ Enfoque Anterior (Menos Elegante)
```
rancher.midominio.com:6443  → API Kubernetes
rancher.midominio.com:9345  → Registration  
rancher.midominio.com:443   → Rancher UI
```

## 🔧 Configuración DNS Requerida

```bash
# Agregar a tu servidor DNS o /etc/hosts
192.168.1.50    api.midominio.com
192.168.1.50    reg.midominio.com  
192.168.1.50    rancher.midominio.com
192.168.1.50    status.midominio.com    # opcional
```

## 📝 Configuración NGINX Plus

### 📁 Ubicación del archivo
```bash
/etc/nginx/conf.d/rke2-rancher.conf
```

### 🔐 Certificados SSL
```bash
# Generar certificado wildcard para *.midominio.com
sudo mkdir -p /etc/nginx/ssl

# Opción 1: Let's Encrypt (recomendado)
sudo certbot certonly --nginx -d "*.midominio.com" -d "midominio.com"

# Opción 2: Certificado auto-firmado (desarrollo)
sudo openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout /etc/nginx/ssl/midominio.com.key \
  -out /etc/nginx/ssl/midominio.com.crt \
  -subj "/CN=*.midominio.com"

# Verificar permisos
sudo chmod 600 /etc/nginx/ssl/midominio.com.key
sudo chmod 644 /etc/nginx/ssl/midominio.com.crt
```

### ⚙️ Configuración Principal

```nginx
# 🚀 RKE2 + Rancher NGINX Plus Configuration - Enfoque por Subdominios
# Configuración elegante con subdominios y puerto 443 unificado
# Dominios: api.midominio.com, reg.midominio.com, rancher.midominio.com
#
# 🏗️ ARQUITECTURA DE NODOS:
# ┌─────────────────────┬─────────────────┬─────────────────┬───────────────────────┐
# │ HOSTNAME            │ IP              │ TIPO           │ SERVICIOS             │
# ├─────────────────────┼─────────────────┼─────────────────┼───────────────────────┤
# │ prd3appk8sm1        │ 192.168.1.101   │ master+primary │ API+Registration+Rancher │
# │ prd3appk8sm2        │ 192.168.1.102   │ master         │ API+Registration+Rancher │
# │ prd3appk8sm3        │ 192.168.1.103   │ master         │ API+Registration+Rancher │
# │ prd3appk8sw1        │ 192.168.1.111   │ worker         │ Workloads             │
# │ prd3appk8sw2        │ 192.168.1.112   │ worker         │ Workloads             │
# │ prd3appk8sw3        │ 192.168.1.113   │ worker         │ Workloads             │
# │ prd3appk8ss1        │ 192.168.1.121   │ storage        │ Ceph OSDs             │
# │ prd3appk8ss2        │ 192.168.1.122   │ storage        │ Ceph OSDs             │
# │ prd3appk8ss3        │ 192.168.1.123   │ storage        │ Ceph OSDs             │
# └─────────────────────┴─────────────────┴─────────────────┴───────────────────────┘
#
# 🎯 LOAD BALANCER: 192.168.1.50 (NGINX Plus)
# 📡 DNS RECORDS NEEDED:
#    api.midominio.com      → 192.168.1.50
#    reg.midominio.com      → 192.168.1.50  
#    rancher.midominio.com  → 192.168.1.50

http {
    # 🔧 Upstreams para Kubernetes API (puerto 6443)
    # Solo nodos MASTER ejecutan kube-apiserver en puerto 6443
    upstream k8s_api_backend {
        # prd3appk8sm1 - Master Primary - 192.168.1.101
        server 192.168.1.101:6443 max_fails=3 fail_timeout=30s weight=3;
        
        # prd3appk8sm2 - Master Secondary - 192.168.1.102  
        server 192.168.1.102:6443 max_fails=3 fail_timeout=30s weight=2;
        
        # prd3appk8sm3 - Master Tertiary - 192.168.1.103
        server 192.168.1.103:6443 max_fails=3 fail_timeout=30s weight=1;
    }

    # 🔧 Upstreams para Registration (puerto 9345)
    # Solo nodos MASTER ejecutan rke2-server registration en puerto 9345
    upstream k8s_registration_backend {
        # prd3appk8sm1 - Master Primary - 192.168.1.101
        server 192.168.1.101:9345 max_fails=3 fail_timeout=30s weight=3;
        
        # prd3appk8sm2 - Master Secondary - 192.168.1.102
        server 192.168.1.102:9345 max_fails=3 fail_timeout=30s weight=2;
        
        # prd3appk8sm3 - Master Tertiary - 192.168.1.103  
        server 192.168.1.103:9345 max_fails=3 fail_timeout=30s weight=1;
    }

    # 🔧 Upstreams para Rancher UI (puerto 443)
    # Rancher HA se despliega SOLO en nodos MASTER (no en workers/storage)
    upstream rancher_backend {
        # prd3appk8sm1 - Master Primary - 192.168.1.101 - Rancher Pod
        server 192.168.1.101:443 max_fails=3 fail_timeout=30s weight=3;
        
        # prd3appk8sm2 - Master Secondary - 192.168.1.102 - Rancher Pod
        server 192.168.1.102:443 max_fails=3 fail_timeout=30s weight=2;
        
        # prd3appk8sm3 - Master Tertiary - 192.168.1.103 - Rancher Pod
        server 192.168.1.103:443 max_fails=3 fail_timeout=30s weight=1;
    }

    # 📊 Logging unificado
    log_format unified_access '$remote_addr - $remote_user [$time_local] '
                             '"$request" $status $body_bytes_sent '
                             '"$http_referer" "$http_user_agent" '
                             'service: $server_name upstream: $upstream_addr';

    # 🔐 Configuración SSL unificada
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-RSA-AES256-GCM-SHA384:ECDHE-RSA-CHACHA20-POLY1305;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;

    # 🌐 HTTP -> HTTPS redirección global
    server {
        listen 80;
        server_name api.midominio.com reg.midominio.com rancher.midominio.com;
        return 301 https://$server_name$request_uri;
    }

    # 🔗 Kubernetes API - api.midominio.com:443
    # Proxy hacia kube-apiserver en nodos MASTER únicamente
    # Workers y Storage NO ejecutan kube-apiserver
    server {
        listen 443 ssl http2;
        server_name api.midominio.com;

        ssl_certificate /etc/nginx/ssl/midominio.com.crt;
        ssl_certificate_key /etc/nginx/ssl/midominio.com.key;

        access_log /var/log/nginx/k8s-api-access.log unified_access;
        error_log /var/log/nginx/k8s-api-error.log warn;

        location / {
            # Balanceamos SOLO hacia masters: 101, 102, 103
            proxy_pass https://k8s_api_backend;
            proxy_ssl_verify off;
            proxy_ssl_session_reuse on;
            
            # Headers para API de Kubernetes
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;

            # Timeouts para API calls
            proxy_connect_timeout 10s;
            proxy_send_timeout 60s;
            proxy_read_timeout 60s;

            # Streaming para kubectl exec/logs
            proxy_buffering off;
            proxy_request_buffering off;
            proxy_http_version 1.1;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection "upgrade";
        }

        # Health check
        location /nginx-health {
            access_log off;
            return 200 "k8s-api healthy\n";
            add_header Content-Type text/plain;
        }
    }

    # 🔗 Kubernetes Registration - reg.midominio.com:443  
    # Proxy hacia rke2-server registration en nodos MASTER únicamente
    # Este puerto es usado por workers para unirse al cluster
    server {
        listen 443 ssl http2;
        server_name reg.midominio.com;

        ssl_certificate /etc/nginx/ssl/midominio.com.crt;
        ssl_certificate_key /etc/nginx/ssl/midominio.com.key;

        access_log /var/log/nginx/k8s-reg-access.log unified_access;
        error_log /var/log/nginx/k8s-reg-error.log warn;

        location / {
            # Balanceamos SOLO hacia masters: 101, 102, 103
            proxy_pass https://k8s_registration_backend;
            proxy_ssl_verify off;
            proxy_ssl_session_reuse on;
            
            # Headers para Registration
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;

            # Timeouts para registration
            proxy_connect_timeout 5s;
            proxy_send_timeout 30s;
            proxy_read_timeout 30s;

            proxy_buffering off;
            proxy_request_buffering off;
        }

        # Health check
        location /nginx-health {
            access_log off;
            return 200 "k8s-registration healthy\n";
            add_header Content-Type text/plain;
        }
    }

    # 🔗 Rancher UI - rancher.midominio.com:443
    # Proxy hacia Rancher HA pods desplegados en nodos MASTER
    # Rancher NO se despliega en workers ni storage por defecto
    server {
        listen 443 ssl http2;
        server_name rancher.midominio.com;

        ssl_certificate /etc/nginx/ssl/midominio.com.crt;
        ssl_certificate_key /etc/nginx/ssl/midominio.com.key;

        access_log /var/log/nginx/rancher-access.log unified_access;
        error_log /var/log/nginx/rancher-error.log warn;

        location / {
            # Balanceamos SOLO hacia masters: 101, 102, 103
            proxy_pass https://rancher_backend;
            proxy_ssl_verify off;
            proxy_ssl_session_reuse on;
            
            # Headers específicos para Rancher
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
            proxy_set_header X-Forwarded-Host $host;
            proxy_set_header X-Forwarded-Port $server_port;

            # Timeouts para Rancher UI
            proxy_connect_timeout 30s;
            proxy_send_timeout 60s;
            proxy_read_timeout 300s;

            # WebSocket support para Rancher
            proxy_buffering off;
            proxy_request_buffering off;
            proxy_http_version 1.1;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection "upgrade";

            # Rancher specific headers
            proxy_set_header X-API-Host $server_name;
            proxy_set_header X-API-Scheme $scheme;
        }

        # Health check
        location /nginx-health {
            access_log off;
            return 200 "rancher healthy\n";
            add_header Content-Type text/plain;
        }
    }

    # 🎯 Status page unificado (opcional)
    server {
        listen 443 ssl;
        server_name status.midominio.com;

        ssl_certificate /etc/nginx/ssl/midominio.com.crt;
        ssl_certificate_key /etc/nginx/ssl/midominio.com.key;

        location / {
            return 200 "NGINX Plus Status - All services healthy";
            add_header Content-Type text/plain;
        }

        # NGINX Plus status (si está habilitado)
        location /status {
            api write=on;
            allow 192.168.1.0/24;
            deny all;
        }
    }
}
```

## 🛠️ Instalación y Configuración

### 1️⃣ Instalar NGINX Plus

```bash
# Oracle Linux 8 / RHEL 8
sudo yum install -y nginx-plus

# Verificar instalación
nginx -v
```

### 2️⃣ Aplicar Configuración

```bash
# Backup configuración actual
sudo cp /etc/nginx/nginx.conf /etc/nginx/nginx.conf.backup

# Crear configuración específica
sudo nano /etc/nginx/conf.d/rke2-rancher.conf
# (Copiar contenido de la configuración arriba)

# Validar sintaxis
sudo nginx -t

# Aplicar cambios
sudo systemctl reload nginx
sudo systemctl enable nginx
```

### 3️⃣ Configurar Firewall

```bash
# Oracle Linux 8 / RHEL 8
sudo firewall-cmd --permanent --add-service=http
sudo firewall-cmd --permanent --add-service=https
sudo firewall-cmd --permanent --add-port=6443/tcp
sudo firewall-cmd --permanent --add-port=9345/tcp
sudo firewall-cmd --reload
```

## 🔍 Verificación y Testing

### ✅ Health Checks

```bash
# Verificar NGINX Plus
curl -k https://api.midominio.com/nginx-health
curl -k https://reg.midominio.com/nginx-health  
curl -k https://rancher.midominio.com/nginx-health

# Verificar conectividad a backends
curl -k https://192.168.1.101:6443/version
curl -k https://192.168.1.101:9345/readyz
curl -k https://192.168.1.101:443/
```

### 📊 Monitoreo de Logs

```bash
# Logs en tiempo real
sudo tail -f /var/log/nginx/k8s-api-access.log
sudo tail -f /var/log/nginx/k8s-reg-access.log
sudo tail -f /var/log/nginx/rancher-access.log

# Errores
sudo tail -f /var/log/nginx/k8s-api-error.log
sudo tail -f /var/log/nginx/rancher-error.log
```

### 🧪 Testing kubectl

```bash
# Configurar kubectl para usar el LoadBalancer
export KUBECONFIG=/path/to/kubeconfig

# Verificar conexión
kubectl cluster-info
kubectl get nodes
kubectl get pods -A
```

## 🚨 Troubleshooting

### ❗ Error: "502 Bad Gateway"

**Causa:** Backend no disponible

**Solución:**
```bash
# Verificar que los masters están ejecutando los servicios
sudo systemctl status rke2-server.service

# Verificar puertos en masters
sudo netstat -tulpn | grep -E "(6443|9345|443)"

# Verificar conectividad desde LB
telnet 192.168.1.101 6443
telnet 192.168.1.102 9345
```

### ❗ Error: "SSL handshake failed"

**Causa:** Problemas de certificado

**Solución:**
```bash
# Verificar certificados
sudo openssl x509 -in /etc/nginx/ssl/midominio.com.crt -text -noout

# Regenerar si es necesario
sudo certbot renew --nginx

# Verificar permisos
sudo ls -la /etc/nginx/ssl/
```

### ❗ Error: "Name resolution failed"

**Causa:** DNS no configurado

**Solución:**
```bash
# Verificar DNS
nslookup api.midominio.com
nslookup rancher.midominio.com

# Agregar temporalmente a /etc/hosts
echo "192.168.1.50 api.midominio.com" | sudo tee -a /etc/hosts
echo "192.168.1.50 reg.midominio.com" | sudo tee -a /etc/hosts
echo "192.168.1.50 rancher.midominio.com" | sudo tee -a /etc/hosts
```

### ❗ Error: "kubectl connection refused"

**Causa:** Configuración incorrecta en kubeconfig

**Solución:**
```bash
# Verificar kubeconfig
cat ~/.kube/config | grep server

# Debe apuntar a api.midominio.com:443
# Si apunta a otra IP, actualizar:
sed -i 's/server: https:\/\/[^\/]*/server: https:\/\/api.midominio.com:443/' ~/.kube/config
```

## 📈 Optimizaciones Avanzadas

### 🚀 Health Checks Activos (NGINX Plus)

```nginx
# Agregar a cada upstream
upstream k8s_api_backend {
    server 192.168.1.101:6443 max_fails=3 fail_timeout=30s weight=3;
    server 192.168.1.102:6443 max_fails=3 fail_timeout=30s weight=2;
    server 192.168.1.103:6443 max_fails=3 fail_timeout=30s weight=1;
    
    # Health check activo
    health_check interval=10s fails=3 passes=2 uri=/readyz;
}
```

### ⚡ Optimización de Performance

```nginx
# Agregar a http {}
upstream_conf.d/performance.conf;

worker_processes auto;
worker_connections 2048;

# Cache SSL sessions
ssl_session_cache shared:SSL:10m;
ssl_session_timeout 10m;

# Compresión
gzip on;
gzip_vary on;
gzip_min_length 1024;
gzip_types text/plain text/css application/json application/javascript;
```

## 🔄 Actualización de .env

Para usar este enfoque de subdominios, actualiza tu archivo `.env`:

```bash
# 🌍 Configuración con subdominios
ROOT_PASSWORD=TuPasswordSeguraAqui
LB_IP=192.168.1.50
SSH_PORT=22
SSH_USER=root

# 🏷️ Subdominios separados (enfoque elegante)
RANCHER_DOMAIN=rancher.midominio.com
K8S_API_DOMAIN=api.midominio.com
K8S_REG_DOMAIN=reg.midominio.com

BOOTSTRAP_PASSWORD=AdminPassword123
RKE2_VERSION=v1.32.1+rke2r1
RANCHER_VERSION=v2.11.1
CLUSTER_TOKEN=TokenSuperSeguro123
METALLB_IP_RANGE=192.168.1.200-192.168.1.210

# Configuración de nodos (ajustar IPs según tu entorno)
NODES_CONFIG='{
"prd3appk8sm1": {"ip": "192.168.1.101", "type": "master", "primary": true},
"prd3appk8sm2": {"ip": "192.168.1.102", "type": "master", "primary": false},
"prd3appk8sm3": {"ip": "192.168.1.103", "type": "master", "primary": false},
"prd3appk8sw1": {"ip": "192.168.1.111", "type": "worker", "primary": false},
"prd3appk8sw2": {"ip": "192.168.1.112", "type": "worker", "primary": false},
"prd3appk8sw3": {"ip": "192.168.1.113", "type": "worker", "primary": false},
"prd3appk8ss1": {"ip": "192.168.1.121", "type": "storage", "primary": false},
"prd3appk8ss2": {"ip": "192.168.1.122", "type": "storage", "primary": false},
"prd3appk8ss3": {"ip": "192.168.1.123", "type": "storage", "primary": false}
}'
```

## 📚 Referencias

- [NGINX Plus Documentation](https://docs.nginx.com/nginx/)
- [RKE2 Documentation](https://docs.rke2.io/)
- [Rancher Documentation](https://rancher.com/docs/)
- [Let's Encrypt SSL](https://letsencrypt.org/)

---

**Desarrollado por [@SktCod.ByChisto](https://github.com/adm-gitrepos)**
**© 2025 – Todos los derechos reservados**
