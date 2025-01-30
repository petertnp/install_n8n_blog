#!/bin/bash
set -eo pipefail

# Dinh dang mau
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Hien thi thong bao
log() {
  local level=$1
  local message=$2
  case $level in
    "info") echo -e "${GREEN}[INFO]${NC} $message" ;;
    "warn") echo -e "${YELLOW}[WARN]${NC} $message" ;;
    "error") echo -e "${RED}[ERROR]${NC} $message" >&2 ;;
  esac
}

# Kiem tra container
check_container() {
  local service=$1
  local timeout=${2:-300}
  local interval=5
  local attempts=$((timeout/interval))

  log "info" "Kiem tra $service..."
  for ((i=1; i<=attempts; i++)); do
    if docker-compose -f ~/docker/$service/docker-compose.yml ps | grep -q "Up (healthy)"; then
      log "info" "$service da san sang"
      return 0
    fi
    log "warn" "Cho $service ($i/$attempts)..."
    sleep $interval
  done
  log "error" "$service khong khoi dong sau $timeout giay"
  return 1
}

# Nhap thong tin
declare -A CONFIG=(
  ["N8N_DOMAIN"]="Nhap ten mien cho N8N"
  ["WP_DOMAIN"]="Nhap ten mien cho WordPress" 
  ["MYSQL_ROOT_PASSWORD"]="Nhap mat khau root MySQL (an)"
  ["N8N_DB_NAME"]="Nhap ten database cho N8N"
  ["N8N_DB_PASSWORD"]="Nhap mat khau N8N database (an)"
  ["WP_DB_NAME"]="Nhap ten database WordPress"
  ["WP_DB_PASSWORD"]="Nhap mat khau WordPress database (an)"
  ["NGINX_DB_NAME"]="Nhap ten database Nginx Proxy Manager"
  ["NGINX_DB_PASSWORD"]="Nhap mat khau Nginx database (an)"
)

declare -A SECRETS
for key in "${!CONFIG[@]}"; do
  if [[ $key == *"PASSWORD"* ]]; then
    read -sp "${CONFIG[$key]}: " SECRETS[$key]
    echo
  else
    read -p "${CONFIG[$key]}: " SECRETS[$key]
  fi
done

# Kiem tra DNS
check_dns() {
  local domain=$1
  log "info" "Kiem tra DNS cho $domain..."
  if ! dig +short "$domain" | grep -qP '^\d+\.\d+\.\d+\.\d+$'; then
    log "error" "Ten mien $domain chua tro IP!"
    return 1
  fi
}
check_dns "${SECRETS[N8N_DOMAIN]}" || exit 1
check_dns "${SECRETS[WP_DOMAIN]}" || exit 1

# Cai dat Docker
install_docker() {
  log "info" "Kiem tra Docker..."
  if ! command -v docker &>/dev/null; then
    log "info" "Cai dat Docker..."
    sudo apt update && sudo apt install -y docker.io
    sudo systemctl enable --now docker
    
    if ! docker --version &>/dev/null; then
      log "error" "Cai dat Docker that bai!"
      exit 1
    fi
    log "info" "Phien ban Docker: $(docker --version)"
    
    if ! sudo systemctl is-active --quiet docker; then
      log "warn" "Khoi dong lai Docker..."
      sudo systemctl restart docker
      sleep 5
      if ! sudo systemctl is-active --quiet docker; then
        log "error" "Khong the khoi dong Docker!"
        exit 1
      fi
    fi
  else
    log "info" "Da cai dat Docker: $(docker --version)"
  fi

  log "info" "Kiem tra hoat dong Docker..."
  if ! docker run --rm hello-world | grep -q "Hello from Docker!"; then
    log "error" "Docker khong hoat dong!"
    exit 1
  fi
}

# Cai dat Docker Compose 
install_docker_compose() {
  log "info" "Kiem tra Docker Compose..."
  if ! command -v docker-compose &>/dev/null; then
    log "info" "Cai dat Docker Compose..."
    sudo apt install -y docker-compose
    
    if ! docker-compose --version &>/dev/null; then
      log "error" "Cai dat Docker Compose that bai!"
      exit 1
    fi
  fi
  log "info" "Phien ban Docker Compose: $(docker-compose --version)"
}

# Cau hinh firewall
configure_firewall() {
  log "info" "Mo port firewall..."
  for port in 80 443 3306 8080 5678 9000 81; do
    sudo ufw allow $port/tcp >/dev/null 2>&1
  done
}

# Tao mang Docker
create_network() {
  if ! docker network inspect my-bridge-network &>/dev/null; then
    log "info" "Tao mang Docker..."
    docker network create my-bridge-network
  fi
}

# Tao file cau hinh
create_compose_file() {
  local service=$1
  local content=$2
  log "info" "Tao file cau hinh cho $service..."
  mkdir -p ~/docker/$service
  echo "$content" > ~/docker/$service/docker-compose.yml
}

# Cai dat MySQL
install_mysql() {
  create_compose_file "mysql" \
"version: '3.8'
services:
  mysql:
    image: mysql:8.0
    restart: unless-stopped
    networks:
      - my-bridge-network
    environment:
      MYSQL_ROOT_PASSWORD: ${SECRETS[MYSQL_ROOT_PASSWORD]}
    healthcheck:
      test: ['CMD', 'mysqladmin', 'ping', '-h', 'localhost']
      interval: 5s
      timeout: 3s
      retries: 10
    volumes:
      - mysql_data:/var/lib/mysql
volumes:
  mysql_data:
networks:
  my-bridge-network:
    external: true"

  docker-compose -f ~/docker/mysql/docker-compose.yml up -d
  check_container "mysql" || exit 1
}

# Cai dat Nginx Proxy Manager
install_nginx_proxy() {
  create_compose_file "nginx-proxy" \
"version: '3.8'
services:
  nginx:
    image: jc21/nginx-proxy-manager:latest
    restart: unless-stopped
    depends_on:
      - mysql
    networks:
      - my-bridge-network
    environment:
      DB_MYSQL_HOST: mysql
      DB_MYSQL_PORT: 3306
      DB_MYSQL_USER: root
      DB_MYSQL_PASSWORD: ${SECRETS[MYSQL_ROOT_PASSWORD]}
      DB_MYSQL_NAME: ${SECRETS[NGINX_DB_NAME]}
    ports:
      - 80:80
      - 443:443
      - 81:81
    volumes:
      - data:/data
      - letsencrypt:/etc/letsencrypt
volumes:
  data:
  letsencrypt:
networks:
  my-bridge-network:
    external: true"

  docker-compose -f ~/docker/nginx-proxy/docker-compose.yml up -d
  check_container "nginx-proxy" || exit 1
}

# Cau hinh SSL
configure_ssl() {
  log "info" "Cau hinh SSL..."
  curl -X POST "http://localhost:81/api/nginx/certificates" \
    -H "Content-Type: application/json" \
    -d '{
      "domain_names": ["'${SECRETS[N8N_DOMAIN]}'", "'${SECRETS[WP_DOMAIN]}'"],
      "provider": "letsencrypt",
      "meta": {"letsencrypt_agree": true}
    }' || log "warn" "Khong the cap SSL tu dong"
}

# Cai dat WordPress
install_wordpress() {
  create_compose_file "wordpress" \
"version: '3.8'
services:
  wordpress:
    image: wordpress:latest
    restart: unless-stopped
    depends_on:
      - mysql
    networks:
      - my-bridge-network
    environment:
      WORDPRESS_DB_HOST: mysql
      WORDPRESS_DB_USER: root
      WORDPRESS_DB_PASSWORD: ${SECRETS[MYSQL_ROOT_PASSWORD]}
      WORDPRESS_DB_NAME: ${SECRETS[WP_DB_NAME]}
    healthcheck:
      test: ['CMD', 'curl', '-f', 'http://localhost:80']
      interval: 10s
      timeout: 5s
      retries: 10
    ports:
      - 8080:80
networks:
  my-bridge-network:
    external: true"

  docker-compose -f ~/docker/wordpress/docker-compose.yml up -d
  check_container "wordpress" || exit 1
}

# Cai dat N8N
install_n8n() {
  create_compose_file "n8n" \
"version: '3.8'
services:
  n8n:
    image: n8nio/n8n
    restart: unless-stopped
    depends_on:
      - mysql
    networks:
      - my-bridge-network
    environment:
      DB_TYPE: mysql
      DB_MYSQLDB_HOST: mysql
      DB_MYSQLDB_DATABASE: ${SECRETS[N8N_DB_NAME]}
      DB_MYSQLDB_USER: root
      DB_MYSQLDB_PASSWORD: ${SECRETS[MYSQL_ROOT_PASSWORD]}
      N8N_HOST: ${SECRETS[N8N_DOMAIN]}
      WEBHOOK_URL: https://${SECRETS[N8N_DOMAIN]}/
    ports:
      - 5678:5678
networks:
  my-bridge-network:
    external: true"

  docker-compose -f ~/docker/n8n/docker-compose.yml up -d
  check_container "n8n" || exit 1
}

# Cai dat Portainer
install_portainer() {
  create_compose_file "portainer" \
"version: '3.8'
services:
  portainer:
    image: portainer/portainer-ce:latest
    restart: unless-stopped
    networks:
      - my-bridge-network
    ports:
      - 9000:9000
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - portainer_data:/data
volumes:
  portainer_data:
networks:
  my-bridge-network:
    external: true"

  docker-compose -f ~/docker/portainer/docker-compose.yml up -d
  check_container "portainer" || exit 1
}

# Tao dich vu tu dong khoi dong
create_systemd_service() {
  log "info" "Tao dich vu tu dong khoi dong..."
  sudo tee /etc/systemd/system/docker-stack.service > /dev/null <<EOF
[Unit]
Description=Tu dong khoi dong Docker Stack
After=docker.service

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'docker-compose -f ~/docker/mysql/docker-compose.yml up -d && \\
                        docker-compose -f ~/docker/nginx-proxy/docker-compose.yml up -d && \\
                        docker-compose -f ~/docker/wordpress/docker-compose.yml up -d && \\
                        docker-compose -f ~/docker/n8n/docker-compose.yml up -d && \\
                        docker-compose -f ~/docker/portainer/docker-compose.yml up -d'

[Install]
WantedBy=multi-user.target
EOF

  sudo systemctl daemon-reload
  sudo systemctl enable docker-stack.service
}

# Main
main() {
  install_docker
  install_docker_compose
  configure_firewall
  create_network
  install_mysql
  install_nginx_proxy
  configure_ssl
  install_wordpress
  install_n8n
  install_portainer
  create_systemd_service

  echo -e "\n${GREEN}=== CAI DAT HOAN TAT ===${NC}"
  echo "Portainer:      http://$(hostname -I | awk '{print $1}'):9000"
  echo "Nginx Manager:  http://$(hostname -I | awk '{print $1}'):81"
  echo "WordPress:      https://${SECRETS[WP_DOMAIN]}"
  echo "N8N:            https://${SECRETS[N8N_DOMAIN]}"
  echo -e "\nLuu y: SSL co the mat 5-10 phut de kich hoat"
}

main
