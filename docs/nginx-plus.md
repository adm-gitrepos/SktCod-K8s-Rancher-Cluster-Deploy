# 🧩 NGINX Plus como Load Balancer para RKE2 + Rancher

Este archivo describe la configuración recomendada de **NGINX Plus** para balancear tráfico hacia un clúster RKE2 con Rancher en alta disponibilidad, utilizando la nueva configuración centralizada con `NODES_CONFIG`.

> ⚠️ **IMPORTANTE:** Antes de usar esta configuración, asegúrate de haber leído los [requisitos previos críticos en el README](../README.md#️⚠️-importante-requisitos-previos-críticos).

---

## 🆕 Novedades de la Versión 2.0

### ✨ **Configuración Dinámica**
- **Generación automática** de upstreams basada en `NODES_CONFIG`
- **Detección automática** de nodos por tipo (master, worker, storage)
- **Escalabilidad** fácil al agregar/quitar nodos
- **Consistencia** garantizada con la configuración del clúster

### 🔧 **Scripts Helper Incluidos**
- **Generación automática** de configuración NGINX
- **Validación** de nodos activos antes de generar config
- **Templates** reutilizables para diferentes escenarios

---

## 🎯 Objetivo

Configurar un NGINX Plus externo que actúe como LoadBalancer L4/L7 para:

* **API de Kubernetes** (`6443`, `9345`) → Nodos master
* **Interfaz Web de Rancher** (`80`, `443`) → Nodos worker

---

## 📦 Requisitos previos

* **NGINX Plus** instalado con módulo stream habilitado
* **Acceso** a la configuración via `/etc/nginx/nginx.conf`
* **IP estática** definida como `$LB_IP` en tu `.env`
* **Configuración centralizada** con `NODES_CONFIG` en formato JSON

---

## 🔧 Generación Automática de Configuración

### 📄 **Script Generador de Configuración NGINX**

Crea este script para generar automáticamente la configuración NGINX basada en tu `NODES_CONFIG`:

```bash
#!/bin/bash
# generate-nginx-config.sh - Generador automático de configuración NGINX

# Cargar configuración
[ -f .env ] && source .env || { echo "❌ Falta archivo .env"; exit 1; }
[ -f scripts/node-helpers.sh ] && source scripts/node-helpers.sh || { echo "❌ Falta node-helpers.sh"; exit 1; }

validate_nodes_config

echo "🔧 Generando configuración NGINX Plus..."

# Obtener nodos por tipo
MASTER_NODES=$(get_nodes_by_type "master")
WORKER_NODES=$(get_nodes_by_type "worker")

echo "📊 Nodos detectados:"
echo "   • Masters: $(echo "$MASTER_NODES" | wc -l)"
echo "   • Workers: $(echo "$WORKER_NODES" | wc -l)"

# Generar configuración stream (L4)
cat > nginx-rke2-stream.conf <<EOF
# 🚀 RKE2 + Rancher NGINX Plus Configuration
# Generado automáticamente desde NODES_CONFIG
# Fecha: $(date)

stream {
    # 🔧 Upstream para API de Kubernetes (puerto 6443)
    upstream rke2_api {
$(echo "$MASTER_NODES" | while read -r hostname; do
    if [ -n "$hostname" ]; then
        echo "        server $hostname:6443 max_fails=3 fail_timeout=30s;"
    fi
done)
    }

    # 🔧 Upstream para etcd/RKE2 (puerto 9345)
    upstream rke2_etcd {
$(echo "$MASTER_NODES" | while read -r hostname; do
    if [ -n "$hostname" ]; then
        echo "        server $hostname:9345 max_fails=3 fail_timeout=30s;"
    fi
done)
    }

    # 📡 Proxy para API de Kubernetes
    server {
        listen $LB_IP:6443;
        proxy_pass rke2_api;
        proxy_timeout 10s;
        proxy_connect_timeout 3s;
        proxy_responses 1;
    }

    # 📡 Proxy para etcd/RKE2
    server {
        listen $LB_IP:9345;
        proxy_pass rke2_etcd;
        proxy_timeout 10s;
        proxy_connect_timeout 3s;
        proxy_responses 1;
    }
}
EOF

# Generar configuración HTTP (L7)
cat > nginx-rke2-http.conf <<EOF
# 🌐 Configuración HTTP para Rancher UI

http {
    # 🔧 Upstream para Rancher HTTP
    upstream rancher_http {
$(echo "$WORKER_NODES" | while read -r hostname; do
    if [ -n "$hostname" ]; then
        echo "        server $hostname:80 max_fails=3 fail_timeout=30s;"
    fi
done)
    }

    # 🔧 Upstream para Rancher HTTPS
    upstream rancher_https {
$(echo "$WORKER_NODES" | while read -r hostname; do
    if [ -n "$hostname" ]; then
        echo "        server $hostname:443 max_fails=3 fail_timeout=30s;"
    fi
done)
    }

    # 📊 Configuración de logging
    log_format rancher_access '\$remote_addr - \$remote_user [\$time_local] '
                              '"\$request" \$status \$body_bytes_sent '
                              '"\$http_referer" "\$http_user_agent" '
                              'upstream: \$upstream_addr';

    # 🌐 Virtual Host para HTTP (redirección a HTTPS)
    server {
        listen $LB_IP:80;
        server_name $RANCHER_DOMAIN;
        
        access_log /var/log/nginx/rancher-access.log rancher_access;
        error_log /var/log/nginx/rancher-error.log warn;
        
        # Redirección forzada a HTTPS
        return 301 https://\$server_name\$request_uri;
    }

    # 🔐 Virtual Host para HTTPS
    server {
        listen $LB_IP:443 ssl http2;
        server_name $RANCHER_DOMAIN;
        
        # 🔒 Configuración SSL (ajustar rutas según tu setup)
        ssl_certificate /etc/nginx/ssl/$RANCHER_DOMAIN.crt;
        ssl_certificate_key /etc/nginx/ssl/$RANCHER_DOMAIN.key;
        ssl_protocols TLSv1.2 TLSv1.3;
        ssl_ciphers ECDHE-RSA-AES256-GCM-SHA384:ECDHE-RSA-CHACHA20-POLY1305;
        ssl_prefer_server_ciphers off;
        
        # 📊 Logging
        access_log /var/log/nginx/rancher-ssl-access.log rancher_access;
        error_log /var/log/nginx/rancher-ssl-error.log warn;
        
        # 🔧 Configuración de proxy
        location / {
            proxy_pass https://rancher_https;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
            proxy_set_header X-Forwarded-Host \$host;
            proxy_set_header X-Forwarded-Port \$server_port;
            
            # Timeouts para Rancher
            proxy_connect_timeout 30s;
            proxy_send_timeout 60s;
            proxy_read_timeout 60s;
            
            # Buffering
            proxy_buffering off;
            proxy_request_buffering off;
            
            # WebSocket support para Rancher
            proxy_http_version 1.1;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection "upgrade";
        }
        
        # 📊 Health check endpoint
        location /nginx-health {
            access_log off;
            return 200 "healthy\n";
            add_header Content-Type text/plain;
        }
    }
}
EOF

echo "✅ Configuración generada:"
echo "   • nginx-rke2-stream.conf (L4 - API Kubernetes)"
echo "   • nginx-rke2-http.conf (L7 - Rancher UI)"
echo ""
echo "📋 Resumen de configuración:"
echo "   • LoadBalancer IP: $LB_IP"
echo "   • Dominio Rancher: $RANCHER_DOMAIN"
echo "   • Masters configurados: $(echo "$MASTER_NODES" | wc -l)"
echo "   • Workers configurados: $(echo "$WORKER_NODES" | wc -l)"
```

### 🚀 **Uso del Script Generador:**

```bash
# Hacer ejecutable
chmod +x generate-nginx-config.sh

# Generar configuración
./generate-nginx-config.sh

# Copiar a NGINX Plus
sudo cp nginx-rke2-stream.conf /etc/nginx/conf.d/
sudo cp nginx-rke2-http.conf /etc/nginx/conf.d/

# Validar configuración
sudo nginx -t

# Recargar NGINX
sudo systemctl reload nginx
```

---

## 📄 Configuración Completa de Ejemplo

### 🔧 **`/etc/nginx/nginx.conf` - Configuración Principal**

```nginx
# NGINX Plus - Configuración principal
user nginx;
worker_processes auto;
error_log /var/log/nginx/error.log warn;
pid /var/run/nginx.pid;

# Event processing
events {
    worker_connections 1024;
    use epoll;
    multi_accept on;
}

# Incluir configuraciones generadas automáticamente
include /etc/nginx/conf.d/nginx-rke2-stream.conf;
include /etc/nginx/conf.d/nginx-rke2-http.conf;
```

### 🔍 **Configuración con Health Checks (NGINX Plus)**

```nginx
# Configuración avanzada con health checks
stream {
    upstream rke2_api {
        zone rke2_api 64k;
        # Nodos generados automáticamente
        server prd3appk8sm1:6443 max_fails=3 fail_timeout=30s;
        server prd3appk8sm2:6443 max_fails=3 fail_timeout=30s;
        server prd3appk8sm3:6443 max_fails=3 fail_timeout=30s;
    }
    
    # Health check para API
    match api_check {
        expect ~* "200|401";
    }
    
    server {
        listen 6443;
        proxy_pass rke2_api;
        health_check match=api_check interval=10s;
    }
}

http {
    upstream rancher_https {
        zone rancher_https 64k;
        # Nodos worker generados automáticamente
        server prd3appk8sw1:443 max_fails=3 fail_timeout=30s;
        server prd3appk8sw2:443 max_fails=3 fail_timeout=30s;
        server prd3appk8sw3:443 max_fails=3 fail_timeout=30s;
    }
    
    # Health check para Rancher
    match rancher_check {
        status 200-399;
        header Content-Type ~ "text/html|application/json";
    }
    
    server {
        listen 443 ssl;
        server_name rancher.midominio.com;
        
        location / {
            proxy_pass https://rancher_https;
            health_check match=rancher_check interval=30s uri=/ping;
        }
    }
}
```

---

## 🔧 Configuración Dinámica Avanzada

### 📱 **Script de Actualización Automática**

```bash
#!/bin/bash
# update-nginx-from-cluster.sh - Actualiza NGINX basado en estado del clúster

source .env
source scripts/node-helpers.sh

echo "🔄 Actualizando configuración NGINX desde estado del clúster..."

# Verificar nodos activos en el clúster
ACTIVE_MASTERS=""
ACTIVE_WORKERS=""

get_nodes_by_type "master" | while read -r hostname; do
    if kubectl get node "$hostname" &>/dev/null; then
        if kubectl get node "$hostname" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' | grep -q "True"; then
            ACTIVE_MASTERS="$ACTIVE_MASTERS $hostname"
        fi
    fi
done

get_nodes_by_type "worker" | while read -r hostname; do
    if kubectl get node "$hostname" &>/dev/null; then
        if kubectl get node "$hostname" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' | grep -q "True"; then
            ACTIVE_WORKERS="$ACTIVE_WORKERS $hostname"
        fi
    fi
done

echo "📊 Nodos activos detectados:"
echo "   • Masters: $ACTIVE_MASTERS"
echo "   • Workers: $ACTIVE_WORKERS"

# Regenerar configuración solo con nodos activos
# ... lógica de generación ...

# Recargar NGINX si hay cambios
if ! diff -q nginx-rke2-stream.conf /etc/nginx/conf.d/nginx-rke2-stream.conf &>/dev/null; then
    echo "🔄 Detectados cambios, recargando NGINX..."
    sudo cp nginx-rke2-*.conf /etc/nginx/conf.d/
    sudo nginx -t && sudo systemctl reload nginx
fi
```

### ⏰ **Automatización con Cron**

```bash
# Crontab para actualización automática cada 5 minutos
*/5 * * * * /opt/rke2-installer/update-nginx-from-cluster.sh >> /var/log/nginx-update.log 2>&1
```

---

## ✅ Validaciones y Troubleshooting

### 🔍 **Script de Validación**

```bash
#!/bin/bash
# validate-nginx-config.sh - Valida configuración y conectividad

echo "🔍 Validando configuración NGINX para RKE2..."

# Verificar sintaxis de NGINX
echo -n "📝 Sintaxis de configuración: "
if nginx -t &>/dev/null; then
    echo "✅ OK"
else
    echo "❌ Error en configuración"
    nginx -t
    exit 1
fi

# Verificar conectividad a upstreams
echo ""
echo "🔗 Verificando conectividad a nodos:"

get_nodes_by_type "master" | while read -r hostname; do
    echo -n "   • Master $hostname:6443: "
    if timeout 3 bash -c "</dev/tcp/$hostname/6443" 2>/dev/null; then
        echo "✅ OK"
    else
        echo "❌ No accesible"
    fi
done

get_nodes_by_type "worker" | while read -r hostname; do
    echo -n "   • Worker $hostname:443: "
    if timeout 3 bash -c "</dev/tcp/$hostname/443" 2>/dev/null; then
        echo "✅ OK"
    else
        echo "❌ No accesible"
    fi
done

# Verificar respuesta del LoadBalancer
echo ""
echo "🌐 Verificando respuesta del LoadBalancer:"
echo -n "   • API Kubernetes ($LB_IP:6443): "
if timeout 5 bash -c "</dev/tcp/$LB_IP/6443" 2>/dev/null; then
    echo "✅ Puerto accesible"
else
    echo "❌ Puerto no accesible"
fi

echo -n "   • Rancher HTTPS ($LB_IP:443): "
if curl -k --max-time 5 -s -I "https://$LB_IP" | grep -q "HTTP"; then
    echo "✅ Respuesta HTTP"
else
    echo "❌ Sin respuesta HTTP"
fi
```

### 📊 **Monitoreo de NGINX Plus**

```bash
# Configurar API de estado de NGINX Plus
location /api {
    api write=on;
    allow 127.0.0.1;
    allow $LB_IP;
    deny all;
}

# Dashboard de NGINX Plus
location = /dashboard.html {
    root /usr/share/nginx/html;
    allow 127.0.0.1;
    allow $LB_IP;
    deny all;
}
```

### 🔧 **Comandos de Troubleshooting**

```bash
# Verificar estado de upstreams
curl -s http://$LB_IP/api/6/http/upstreams | jq

# Ver conexiones activas
curl -s http://$LB_IP/api/6/connections | jq

# Logs en tiempo real
tail -f /var/log/nginx/rancher-access.log

# Estadísticas de NGINX
nginx -s reload  # Recargar configuración
nginx -s reopen  # Rotar logs
```

---

## 📊 Configuración de Monitoreo

### 📈 **Métricas de NGINX Plus**

```nginx
# Configuración de métricas para Prometheus
location /metrics {
    access_log off;
    allow 127.0.0.1;
    allow 10.0.0.0/8;  # Ajustar según tu red
    deny all;
    
    # Exportar métricas en formato Prometheus
    return 200 "# NGINX Plus metrics endpoint\n";
}
```

### 🔔 **Alertas Recomendadas**

```yaml
# alerts.yml para Prometheus
groups:
- name: nginx-rke2
  rules:
  - alert: NginxUpstreamDown
    expr: nginx_upstream_server_up == 0
    for: 2m
    labels:
      severity: critical
    annotations:
      summary: "NGINX upstream server down"
      description: "Upstream server {{ $labels.server }} in {{ $labels.upstream }} is down"

  - alert: NginxHighErrorRate
    expr: rate(nginx_http_requests_total{status=~"5.."}[5m]) > 0.1
    for: 5m
    labels:
      severity: warning
    annotations:
      summary: "High error rate in NGINX"
      description: "Error rate is {{ $value }} for {{ $labels.server_name }}"

  - alert: RancherUnavailable
    expr: probe_success{job="rancher-blackbox"} == 0
    for: 3m
    labels:
      severity: critical
    annotations:
      summary: "Rancher UI unavailable"
      description: "Rancher UI is not accessible through NGINX"
```

---

## 🔄 Integración con Automatización

### 🤖 **Ansible Playbook para NGINX**

```yaml
# nginx-rke2-setup.yml
---
- name: Configure NGINX Plus for RKE2 + Rancher
  hosts: nginx_servers
  become: yes
  vars:
    rke2_domain: "{{ rancher_domain }}"
    lb_ip: "{{ loadbalancer_ip }}"
  
  tasks:
    - name: Generate NGINX configuration from nodes config
      template:
        src: nginx-rke2.conf.j2
        dest: /etc/nginx/conf.d/rke2.conf
      notify: reload nginx
    
    - name: Validate NGINX configuration
      command: nginx -t
      changed_when: false
    
    - name: Ensure NGINX is running
      systemd:
        name: nginx
        state: started
        enabled: yes

  handlers:
    - name: reload nginx
      systemd:
        name: nginx
        state: reloaded
```

### 🐳 **Docker Compose para Testing**

```yaml
# docker-compose.nginx.yml
version: '3.8'
services:
  nginx:
    image: nginx:alpine
    ports:
      - "80:80"
      - "443:443"
      - "6443:6443"
      - "9345:9345"
    volumes:
      - ./nginx-rke2-stream.conf:/etc/nginx/conf.d/stream.conf
      - ./nginx-rke2-http.conf:/etc/nginx/conf.d/default.conf
      - ./ssl:/etc/nginx/ssl
    environment:
      - RANCHER_DOMAIN=${RANCHER_DOMAIN}
      - LB_IP=${LB_IP}
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "nginx", "-t"]
      interval: 30s
      timeout: 10s
      retries: 3
```

---

## 🔐 Configuración SSL/TLS Avanzada

### 🔒 **Certificados Let's Encrypt con Certbot**

```bash
#!/bin/bash
# setup-ssl-rancher.sh - Configurar SSL automático para Rancher

# Instalar certbot
yum install -y certbot python3-certbot-nginx

# Obtener certificado para Rancher
certbot --nginx -d $RANCHER_DOMAIN --email admin@$RANCHER_DOMAIN --agree-tos --non-interactive

# Configurar renovación automática
echo "0 12 * * * /usr/bin/certbot renew --quiet" | crontab -

# Verificar certificado
openssl x509 -in /etc/letsencrypt/live/$RANCHER_DOMAIN/fullchain.pem -text -noout
```

### 🔐 **Configuración SSL Hardened**

```nginx
# Configuración SSL segura para producción
server {
    listen 443 ssl http2;
    server_name rancher.midominio.com;
    
    # 🔒 Certificados
    ssl_certificate /etc/letsencrypt/live/rancher.midominio.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/rancher.midominio.com/privkey.pem;
    
    # 🔐 Configuración SSL hardened
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;
    
    # 🔒 Headers de seguridad
    add_header Strict-Transport-Security "max-age=63072000" always;
    add_header X-Frame-Options DENY always;
    add_header X-Content-Type-Options nosniff always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    
    # 🔐 OCSP Stapling
    ssl_stapling on;
    ssl_stapling_verify on;
    ssl_trusted_certificate /etc/letsencrypt/live/rancher.midominio.com/chain.pem;
    
    # 🚀 Optimizaciones
    ssl_session_cache shared:SSL:50m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;
    
    location / {
        proxy_pass https://rancher_https;
        # Headers y configuración de proxy...
    }
}
```

---

## 📊 Dashboard y Monitoreo

### 📈 **NGINX Plus Dashboard**

```nginx
# Configuración del dashboard de NGINX Plus
server {
    listen 8080;
    server_name nginx-dashboard.local;
    
    location / {
        root /usr/share/nginx/html;
        index dashboard.html;
    }
    
    location /api {
        api write=on;
        allow 127.0.0.1;
        allow 10.0.0.0/8;
        deny all;
    }
    
    location /metrics {
        access_log off;
        allow 127.0.0.1;
        allow 10.0.0.0/8;
        deny all;
        return 200 "NGINX Plus metrics available at /api\n";
    }
}
```

### 📊 **Grafana Dashboard Config**

```json
{
  "dashboard": {
    "title": "NGINX Plus - RKE2 LoadBalancer",
    "panels": [
      {
        "title": "Upstream Health",
        "type": "stat",
        "targets": [
          {
            "expr": "nginx_upstream_server_up",
            "legendFormat": "{{upstream}}/{{server}}"
          }
        ]
      },
      {
        "title": "Request Rate",
        "type": "graph",
        "targets": [
          {
            "expr": "rate(nginx_http_requests_total[5m])",
            "legendFormat": "{{server_name}}"
          }
        ]
      }
    ]
  }
}
```

---

## 🚀 Scripts de Automatización Completos

### 📄 **Script Master de Configuración**

```bash
#!/bin/bash
# master-nginx-setup.sh - Configuración completa de NGINX para RKE2

set -euo pipefail

# Cargar configuración
source .env
source scripts/node-helpers.sh

echo "🚀 Configuración completa de NGINX Plus para RKE2 + Rancher"
echo "============================================================"

# Validar prerequisitos
validate_nodes_config

# 1. Generar configuración
echo "📝 Generando configuración NGINX..."
./generate-nginx-config.sh

# 2. Validar configuración
echo "🔍 Validando configuración..."
nginx -t

# 3. Backup configuración existente
echo "💾 Creando backup de configuración actual..."
sudo cp -r /etc/nginx/conf.d /etc/nginx/conf.d.backup-$(date +%s)

# 4. Aplicar nueva configuración
echo "🔧 Aplicando nueva configuración..."
sudo cp nginx-rke2-*.conf /etc/nginx/conf.d/

# 5. Recargar NGINX
echo "🔄 Recargando NGINX..."
sudo systemctl reload nginx

# 6. Verificar funcionamiento
echo "✅ Verificando funcionamiento..."
sleep 5

# Test API Kubernetes
if timeout 5 bash -c "</dev/tcp/$LB_IP/6443" 2>/dev/null; then
    echo "   ✅ API Kubernetes accesible en $LB_IP:6443"
else
    echo "   ❌ API Kubernetes no accesible"
fi

# Test Rancher
if curl -k --max-time 10 -s -I "https://$RANCHER_DOMAIN" | grep -q "HTTP"; then
    echo "   ✅ Rancher accesible en https://$RANCHER_DOMAIN"
else
    echo "   ❌ Rancher no accesible"
fi

echo ""
echo "🎉 Configuración de NGINX completada"
echo "📊 Dashboard disponible en: http://$LB_IP:8080"
echo "📈 Métricas disponibles en: http://$LB_IP:8080/api"
echo "🌐 Rancher UI: https://$RANCHER_DOMAIN"
```

### 🔄 **Script de Mantenimiento**

```bash
#!/bin/bash
# nginx-maintenance.sh - Mantenimiento automático de NGINX

LOG_FILE="/var/log/nginx-maintenance.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "$(date): Iniciando mantenimiento de NGINX"

# Rotar logs
nginx -s reopen

# Verificar upstreams
source .env
source scripts/node-helpers.sh

UNHEALTHY_NODES=0

get_nodes_by_type "master" | while read -r hostname; do
    if ! timeout 3 bash -c "</dev/tcp/$hostname/6443" 2>/dev/null; then
        echo "⚠️  Master $hostname:6443 no accesible"
        ((UNHEALTHY_NODES++))
    fi
done

get_nodes_by_type "worker" | while read -r hostname; do
    if ! timeout 3 bash -c "</dev/tcp/$hostname/443" 2>/dev/null; then
        echo "⚠️  Worker $hostname:443 no accesible"
        ((UNHEALTHY_NODES++))
    fi
done

if [ $UNHEALTHY_NODES -gt 0 ]; then
    echo "❌ $UNHEALTHY_NODES nodos no están respondiendo"
    # Enviar alerta (email, Slack, etc.)
else
    echo "✅ Todos los nodos están saludables"
fi

# Verificar certificados SSL
if [ -f "/etc/letsencrypt/live/$RANCHER_DOMAIN/fullchain.pem" ]; then
    CERT_EXPIRY=$(openssl x509 -enddate -noout -in "/etc/letsencrypt/live/$RANCHER_DOMAIN/fullchain.pem" | cut -d= -f2)
    CERT_EXPIRY_EPOCH=$(date -d "$CERT_EXPIRY" +%s)
    CURRENT_EPOCH=$(date +%s)
    DAYS_TO_EXPIRY=$(( (CERT_EXPIRY_EPOCH - CURRENT_EPOCH) / 86400 ))
    
    if [ $DAYS_TO_EXPIRY -lt 30 ]; then
        echo "⚠️  Certificado SSL expira en $DAYS_TO_EXPIRY días"
    else
        echo "✅ Certificado SSL válido por $DAYS_TO_EXPIRY días más"
    fi
fi

echo "$(date): Mantenimiento completado"
```

---

## 📚 Referencias y Documentación

### 🔗 **Enlaces Útiles**
- **[NGINX Plus Documentation](https://docs.nginx.com/nginx/)**: Documentación oficial
- **[Stream Module](https://nginx.org/en/docs/stream/ngx_stream_core_module.html)**: Configuración L4
- **[Health Checks](https://docs.nginx.com/nginx/admin-guide/load-balancer/http-health-check/)**: Monitoreo de upstreams
- **[SSL Configuration](https://ssl-config.mozilla.org/)**: Generador de configuración SSL

### 📖 **Referencias Cruzadas**
- **[README.md](../README.md)**: Guía principal de instalación
- **[index.md](./index.md)**: Documentación técnica completa
- **`.env.example`**: Variables de configuración

### 🔧 **Herramientas Recomendadas**
- **[SSL Labs Test](https://www.ssllabs.com/ssltest/)**: Validar configuración SSL
- **[nginx-config-formatter](https://github.com/1connect/nginx-config-formatter)**: Formatear configuración
- **[nginxconfig.io](https://nginxconfig.io/)**: Generador de configuración NGINX

---

## 🎯 Conclusiones y Mejores Prácticas

### ✅ **Configuración Óptima**
1. **Usar la configuración dinámica** basada en `NODES_CONFIG`
2. **Implementar health checks** para detección automática de fallos
3. **Configurar SSL hardened** para seguridad en producción
4. **Monitorear métricas** y configurar alertas
5. **Automatizar mantenimiento** con scripts programados

### 🔧 **Troubleshooting Rápido**
```bash
# Verificar configuración
nginx -t

# Ver logs en tiempo real
tail -f /var/log/nginx/error.log

# Verificar upstreams
curl -s http://$LB_IP/api/6/http/upstreams | jq

# Recargar configuración
nginx -s reload
```

### 📊 **Métricas Importantes**
- **Upstream health**: Estado de nodos backend
- **Request rate**: Tasa de peticiones por segundo
- **Error rate**: Porcentaje de errores 5xx
- **Response time**: Tiempo de respuesta promedio
- **SSL certificate expiry**: Días hasta expiración

---

## 📜 Licencia

Este proyecto está licenciado bajo los términos de la [Licencia MIT](../LICENSE), lo que permite su uso, copia, modificación y distribución con fines personales, académicos o comerciales.

> **Autoría**: Este software fue creado y es mantenido por [@SktCod.ByChisto](https://github.com/adm-gitrepos).  
> Aunque es de código abierto, se agradece el reconocimiento correspondiente en derivados o menciones públicas.

---

## 👤 Autor

Desarrollado por [@SktCod.ByChisto](https://github.com/adm-gitrepos)  
© 2025 – Todos los derechos reservados.
