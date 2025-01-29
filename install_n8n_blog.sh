#!/bin/bash
set -eo pipefail

# Định dạng hiển thị
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Hàm hiển thị thông báo
log() {
  local level=$1
  local message=$2
  case $level in
    "info") echo -e "${GREEN}[INFO]${NC} $message" ;;
    "warn") echo -e "${YELLOW}[WARN]${NC} $message" ;;
    "error") echo -e "${RED}[ERROR]${NC} $message" >&2 ;;
  esac
}

# Hàm kiểm tra container
check_container() {
  local service=$1
  local timeout=${2:-300}
  local interval=5
  local attempts=$((timeout/interval))

  log "info" "Kiểm tra trạng thái $service..."
  for ((i=1; i<=attempts; i++)); do
    if docker-compose -f ~/docker/$service/docker-compose.yml ps | grep -q "Up (healthy)"; then
      log "info" "$service đã sẵn sàng"
      return 0
    fi
    log "warn" "Chờ $service ($i/$attempts)..."
    sleep $interval
  done
  log "error" "$service không khởi động được sau $timeout giây"
  return 1
}

# Nhập thông tin cấu hình
declare -A CONFIG=(
  ["N8N_DOMAIN"]="Nhập tên miền cho N8N"
  ["WP_DOMAIN"]="Nhập tên miền cho WordPress" 
  ["MYSQL_ROOT_PASSWORD"]="Nhập mật khẩu root MySQL (ẩn)"
  ["N8N_DB_NAME"]="Nhập tên database cho N8N"
  ["N8N_DB_PASSWORD"]="Nhập mật khẩu N8N database (ẩn)"
  ["WP_DB_NAME"]="Nhập tên database WordPress"
  ["WP_DB_PASSWORD"]="Nhập mật khẩu WordPress database (ẩn)"
  ["NGINX_DB_NAME"]="Nhập tên database Nginx Proxy Manager"
  ["NGINX_DB_PASSWORD"]="Nhập mật khẩu Nginx database (ẩn)"
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

# Kiểm tra DNS
check_dns() {
  local domain=$1
  log "info" "Kiểm tra DNS cho $domain..."
  if ! dig +short "$domain" | grep -qP '^\d+\.\d+\.\d+\.\d+$'; then
    log "error" "Tên miền $domain chưa được trỏ IP!"
    return 1
  fi
}
check_dns "${SECRETS[N8N_DOMAIN]}" || exit 1
check_dns "${SECRETS[WP_DOMAIN]}" || exit 1

# Cài đặt Docker
install_docker() {
  log "info" "Kiểm tra Docker..."
  if ! command -v docker &>/dev/null; then
    log "info" "Cài đặt Docker..."
    sudo apt update && sudo apt install -y docker.io
    sudo systemctl enable --now docker
    
    # Kiểm tra phiên bản
    if ! docker --version &>/dev/null; then
      log "error" "Cài đặt Docker thất bại!"
      exit 1
    fi
    log "info" "Phiên bản Docker: $(docker --version)"
    
    # Kiểm tra dịch vụ
    if ! sudo systemctl is-active --quiet docker; then
      log "warn" "Khởi động lại Docker..."
      sudo systemctl restart docker
      sleep 5
      if ! sudo systemctl is-active --quiet docker; then
        log "error" "Không thể khởi động Docker!"
        exit 1
      fi
    fi
  else
    log "info" "Docker đã được cài đặt: $(docker --version)"
  fi

  # Kiểm tra hoạt động
  log "info" "Kiểm tra container mẫu..."
  if ! docker run --rm hello-world | grep -q "Hello from Docker!"; then
    log "error" "Docker không hoạt động đúng!"
    exit 1
  fi
}

# Cài đặt Docker Compose 
install_docker_compose() {
  log "info" "Kiểm tra Docker Compose..."
  if ! command -v docker-compose &>/dev/null; then
    log "info" "Cài đặt Docker Compose..."
    sudo apt install -y docker-compose
    
    if ! docker-compose --version &>/dev/null; then
      log "error" "Cài đặt Docker Compose thất bại!"
      exit 1
    fi
  fi
  log "info" "Phiên bản Docker Compose: $(docker-compose --version)"
}

# Cấu hình firewall
configure_firewall() {
  log "info" "Cấu hình firewall..."
  for port in 80 443 3306 8080 5678 9000 81; do
    sudo ufw allow $port/tcp >/dev/null 2>&1
  done
}

# Tạo docker-compose template
create_compose_file() {
  local service=$1
  local content=$2
  
  log "info" "Tạo cấu hình cho $service..."
  mkdir -p ~/docker/$service
  echo "$content" > ~/docker/$service/docker-compose.yml
}

# Cài đặt các dịch vụ
install_services() {
  # MySQL
  create_compose_file "mysql" \
"version: '3.8'
services:
  mysql:
    image: mysql:8.0
    restart: unless-stopped
    environment:
      MYSQL_ROOT_PASSWORD: ${SECRETS[MYSQL_ROOT_PASSWORD]}
    healthcheck:
      test: ['CMD', 'mysqladmin', 'ping', '-h', 'localhost']
      interval: 5s
      timeout: 3s
      retries: 10
    ports:
      - 3306:3306
    volumes:
      - mysql_data:/var/lib/mysql
volumes:
  mysql_data:"

  docker-compose -f ~/docker/mysql/docker-compose.yml up -d
  check_container "mysql" || exit 1

  # Nginx Proxy Manager
  create_compose_file "nginx-proxy" \
"version: '3.8'
services:
  app:
    image: jc21/nginx-proxy-manager:latest
    restart: unless-stopped
    depends_on:
      mysql:
        condition: service_healthy
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
  letsencrypt:"

  docker-compose -f ~/docker/nginx-proxy/docker-compose.yml up -d
  check_container "nginx-proxy" || exit 1

  # Cấp SSL
  log "info" "Cấu hình SSL..."
  curl -X POST "http://localhost:81/api/nginx/certificates" \
    -H "Content-Type: application/json" \
    -d '{
      "domain_names": ["'${SECRETS[N8N_DOMAIN]}'", "'${SECRETS[WP_DOMAIN]}'"],
      "provider": "letsencrypt",
      "meta": {"letsencrypt_agree": true}
    }' || log "warn" "Không thể cấp SSL tự động"

  # WordPress
  create_compose_file "wordpress" \
"version: '3.8'
services:
  wordpress:
    image: wordpress:latest
    restart: unless-stopped
    depends_on:
      mysql:
        condition: service_healthy
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
      - 8080:80"

  docker-compose -f ~/docker/wordpress/docker-compose.yml up -d
  check_container "wordpress" || exit 1

  # N8N
  create_compose_file "n8n" \
"version: '3.8'
services:
  n8n:
    image: n8nio/n8n
    restart: unless-stopped
    depends_on:
      mysql:
        condition: service_healthy
    environment:
      DB_TYPE: mysql
      DB_MYSQLDB_HOST: mysql
      DB_MYSQLDB_DATABASE: ${SECRETS[N8N_DB_NAME]}
      DB_MYSQLDB_USER: root
      DB_MYSQLDB_PASSWORD: ${SECRETS[MYSQL_ROOT_PASSWORD]}
      N8N_HOST: ${SECRETS[N8N_DOMAIN]}
      WEBHOOK_URL: https://${SECRETS[N8N_DOMAIN]}/
    ports:
      - 5678:5678"

  docker-compose -f ~/docker/n8n/docker-compose.yml up -d
  check_container "n8n" || exit 1

  # Portainer
  create_compose_file "portainer" \
"version: '3.8'
services:
  portainer:
    image: portainer/portainer-ce:latest
    restart: unless-stopped
    ports:
      - 9000:9000
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - portainer_data:/data
volumes:
  portainer_data:"

  docker-compose -f ~/docker/portainer/docker-compose.yml up -d
  check_container "portainer" || exit 1
}

# Tạo systemd service
create_systemd_service() {
  log "info" "Cấu hình tự động khởi động..."
  sudo tee /etc/systemd/system/docker-stack.service > /dev/null <<EOF
[Unit]
Description=Docker Stack Auto-start
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

# Main execution
main() {
  install_docker
  install_docker_compose
  configure_firewall
  install_services
  create_systemd_service

  # Hiển thị thông tin
  echo -e "\n${GREEN}=== CÀI ĐẶT HOÀN TẤT ===${NC}"
  echo "Portainer:      http://$(hostname -I | awk '{print $1}'):9000"
  echo "Nginx Manager:  http://$(hostname -I | awk '{print $1}'):81"
  echo "WordPress:      https://${SECRETS[WP_DOMAIN]}"
  echo "N8N:            https://${SECRETS[N8N_DOMAIN]}"
  echo -e "\nLưu ý: Có thể mất 5-10 phút để SSL hoạt động hoàn toàn"
}

main