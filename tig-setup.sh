#!/bin/bash

function download_package {
	OS=$(uname -s | tr '[:upper:]' '[:lower:]')
	LATEST_URL=$(curl -s https://download.docker.com/linux/static/stable/${ARCH_URL}/ | grep -oP 'href="docker-[0-9.]+\.tgz"' | sed 's/href="//' | sed 's/"//' | sort -Vr | head -n1)
	if [ -z "$LATEST_URL" ]; then
		echo "Docker latest version not found!"
		exit 1
	else
		echo "Downloading... $LATEST_URL"
		curl -LO "https://download.docker.com/linux/static/stable/${ARCH_URL}/${LATEST_URL}"
		echo "Downloaded $LATEST_URL"
	fi
}

function create_user {
	if id "docker" &>/dev/null; then
        echo "User 'docker' already exists. Skipping user creation."
    else
		sudo useradd -m -s /bin/bash docker
		sudo usermod -aG docker docker	
	fi
	sudo usermod -aG docker $USER
}

function installing {
	sudo $PKG_MGR -y install wget tar unzip
	download_package
	create_user
	tar -xvzf "$LATEST_URL"
	sudo cp docker/* /usr/bin/
	echo "docker installed in /usr/bin/"
	compose-install
	create_systemd
	clear-file
}

function clear-file {
	for file in docker*; do
		[[ "$file" == "docker-compose.yml" ]] && continue
		rm -rv "$file"
	done
}

function check-version {
	docker --version
	docker compose version
}

function create_systemd {
if [ ! -f /etc/systemd/system/docker.service ]; then	
	sudo cat <<EOF | sudo tee /etc/systemd/system/docker.service > /dev/null
[Unit]
Description=Docker Service (manual install)
After=network.target

[Service]
ExecStart=/usr/bin/dockerd
ExecReload=/bin/kill -s HUP \$MAINPID
LimitNOFILE=infinity
LimitNPROC=infinity
LimitCORE=infinity
Delegate=yes
KillMode=process
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
fi
sudo systemctl daemon-reload
sudo systemctl enable docker
sudo systemctl start docker
}

function compose-install {
	COMPOSE_VERSION=$(curl -s https://api.github.com/repos/docker/compose/releases/latest \
	| grep '"tag_name":' | sed -E 's/.*"v([^"]+)".*/\1/')
	DOCKER_CONFIG=/usr/lib/docker/cli-plugins
	if [ ! -d "$DOCKER_CONFIG" ]; then
		sudo mkdir -p $DOCKER_CONFIG
	fi
	sudo curl -SL "https://github.com/docker/compose/releases/download/v${COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)" \
	-o "$DOCKER_CONFIG/docker-compose"
	sudo chmod +x "$DOCKER_CONFIG/docker-compose"
}

function start_service {
	local svc=$1
	if [[ "$INIT_SYSTEM" == "systemd" ]]; then
		sudo systemctl enable --now "$svc"
	elif [[ "$INIT_SYSTEM" == "openrc" ]]; then
		sudo rc-update add "$svc" default
		sudo rc-service "$svc" start
	fi
}

function check_service {
	local svc=$1
	if systemctl list-unit-files | grep -q "^$svc.service"; then
		echo "found"
	else
		echo "not found"
	fi
}

function check_active {
	local svc=$1
	if systemctl is-active --quiet $svc; then
		echo "running"
	else
		echo "stoped"
	fi
}

function check_os {
	OS=""
	PKG_MGR=""
	INIT_SYSTEM=""

	if [ -f /etc/os-release ]; then
		. /etc/os-release
		OS=$ID
	fi

	if command -v systemctl &>/dev/null; then
		INIT_SYSTEM="systemd"
	elif command -v rc-service &>/dev/null; then
		INIT_SYSTEM="openrc"
	else
		echo "Unsupported init system"
		return 1
	fi

	if [[ "$OS" =~ ^(ubuntu|debian)$ ]]; then
		PKG_MGR="apt"
	elif [[ "$OS" =~ ^(centos|rhel|almalinux|fedora)$ ]]; then
		if command -v dnf >/dev/null 2>&1; then
			PKG_MGR="dnf"
		else
			PKG_MGR="yum"
		fi
	elif [[ "$OS" == "alpine" ]]; then
		PKG_MGR="apk"
	else
		echo "Unsupported OS: $OS"
		return 1
	fi
}

function check_arch {
	ARCH=$(uname -m)
	case "$ARCH" in
		x86_64)
			ARCH_URL="x86_64"
			;;
		aarch64)
			ARCH_URL="aarch64"
			;;
		armel)
			ARCH_URL="armel"
			;;
		ppc64le)
			ARCH_URL="ppc64le"
			;;
		s390x)
			ARCH_URL="s390x"
			;;
		*)
			echo "Architecture $ARCH is not support!"
			exit 1
			;;
	esac
}

function check_firewall {
	if [[ "$PKG_MGR" == "apt" ]]; then
		if [[ $(check_service ufw) == "not found" ]]; then
			sudo $PKG_MGR install -y ufw
			sudo systemctl enable ufw
			sudo systemctl start ufw
		fi
	elif [[ "$PKG_MGR" == "dnf" || "$PKG_MGR" == "yum" ]]; then
		if [[ $(check_service firewalld) == "not found" ]]; then
			sudo $PKG_MGR install -y firewalld
			sudo systemctl enable firewalld
			sudo systemctl start firewalld
		fi
	elif [[ "$PKG_MGR" == "apk" ]]; then
		if [[ $(check_service iptables) == "not found" ]]; then
			sudo $PKG_MGR add iptables
			start_service iptables
		fi
	fi
}

function precheck {
	check_os
	check_arch
	check_firewall
}

function generate_docker_compose {
	echo "Generating docker-compose.yml..."
	if [ ! -f docker-compose.yml ]; then	
	cat <<EOF | tee docker-compose.yml > /dev/null
version: '3.8'

services:

  influxdb:
    image: influxdb:latest
    container_name: influxdb
    ports:
      - "8086:8086"
    environment:
      #DOCKER_INFLUXDB_INIT_MODE: setup
      INFLUXDB_HTTP_AUTH_ENABLED: true
      DOCKER_INFLUXDB_INIT_USERNAME_FILE: /run/secrets/influxdb-admin-username
      DOCKER_INFLUXDB_INIT_PASSWORD_FILE: /run/secrets/influxdb-admin-password
      DOCKER_INFLUXDB_INIT_ADMIN_TOKEN_FILE: /run/secrets/influxdb-admin-token
      DOCKER_INFLUXDB_INIT_ORG: docs
      DOCKER_INFLUXDB_INIT_BUCKET: home
    secrets:
      - influxdb-admin-username
      - influxdb-admin-password
      - influxdb-admin-token
    volumes:
      - ./influxdb/data:/var/lib/influxdb2
      - ./influxdb/config:/etc/influxdb2

  grafana:
    image: grafana/grafana-oss
    container_name: grafana
    ports:
      - "3000:3000"
    volumes:
      - grafana-data:/var/lib/grafana
    depends_on:
      - influxdb

  telegraf:
    image: telegraf:latest
    container_name: telegraf
    depends_on:
      - influxdb
    volumes:
      - ./telegraf-config/telegraf.d:/etc/telegraf/telegraf.d/:ro
      - ./telegraf-config/telegraf.conf:/etc/telegraf.conf:ro

volumes:
  influxdb-data:
  influxdb-config:
  grafana-data:
secrets:
  influxdb-admin-username:
    file: .env.influxdb-admin-username
  influxdb-admin-password:
    file: .env.influxdb-admin-password
  influxdb-admin-token:
    file: .env.influxdb-admin-token
    
networks:
  default:
    name: tig-network
EOF
	fi
}

function create_folder {
	local m_path=$1
	if [ -n "$m_path" ]; then
		if [ ! -d "$m_path" ]; then
			mkdir $m_path
		fi
	fi
}

function gen_telegraf {
	create_folder telegraf-config
	create_folder telegraf-config/telegraf.d
	if [ ! -f telegraf-config/telegraf.conf ]; then
		cat <<EOF | tee telegraf-config/telegraf.conf > /dev/null
[global_tags]
[agent]
  interval = "30s"
  round_interval = true
  metric_batch_size = 1000
  metric_buffer_limit = 10000
  collection_jitter = "0s"
  flush_interval = "10s"
  flush_jitter = "0s"
  precision = "0s"
  hostname = ""
  omit_hostname = false

EOF
	fi
	RDTOKEN=$(cat .env.influxdb-admin-token)
	read -p "Organization Name: " ORG
	read -p "Bucket Name: " BUCKET
	if [[ -n "$ORG" && "$BUCKET" && "$RDTOKEN" ]]; then
		if [ ! -f telegraf-config/telegraf.d/000-influxdb.conf ]; then
			cat <<EOF | tee telegraf-config/telegraf.d/000-influxdb.conf
[[outputs.influxdb_v2]]
  urls = ["http://localhost:8086"]
  token = "$RDTOKEN"
  organization = "$ORG"
  bucket = "$BUCKET"
EOF
		fi
	fi
}
function gen_influxdb {
	create_folder influxdb
	create_folder influxdb/data
	create_folder influxdb/config
}
function generate_envfile {
	INFLUX_TOKEN=$(openssl rand -hex 32)
	read -p "InfluxDB admin username : " admuser
	if [ ! -f .env.influxdb-admin-username ]; then
		echo "$admuser" > .env.influxdb-admin-username
	fi
	while true; do
		read -s -p "InfluxDB admin password (8-72 chars): " admpass
		echo
		len=${#admpass}
		if [ "$len" -ge 8 ] && [ "$len" -le 72 ]; then
			break
		else
			echo "Password length must be between 8 and 72 characters."
		fi
	done
	
	if [ ! -f .env.influxdb-admin-password ]; then
		echo "$admpass" > .env.influxdb-admin-password
	fi
	
	echo "InfluxDB Token = $INFLUX_TOKEN"
	if [ ! -f gentoken ]; then
		cat <<EOF | tee .env.influxdb-admin-token > /dev/null
$INFLUX_TOKEN
EOF
	fi
}

function post_process {
	if [[ "$(check_service snap)" != "not found" ]]; then
		sudo snap stop docker
		sudo snap remove docker
		sudo rm -rf /var/lib/docker
		sudo rm -rf /var/lib/containerd
		sudo rm -rf /etc/systemd/system/multi-user.target.wants/docker.service
		sudo rm -rf /usr/bin/docker
		sudo rm -rf /usr/bin/docker-compose
		sudo rm -rf /usr/lib/docker/cli-plugins/docker-compose
		sudo rm -rf /usr/bin/dockerd
		sudo rm -rf ~/snap/docker/
		installing
	fi
	if [[ "$(check_service docker)" != "not found" ]]; then
		echo "Docker service is running."
		echo "You can reinstall or upgrade docker service."
		read -r -p  "Do you want to reinstall docker service? (y/n) *Default N :" answer
		answer=${answer:-n}

		if [[ $answer =~ ^[Yy]$ ]]; then
			sudo systemctl stop docker
			sudo systemctl disable docker
			sudo $PKG_MGR -y remove docker docker-engine docker.io containerd runc
			sudo rm -rf /var/lib/docker
			sudo rm -rf /var/lib/containerd
			sudo rm -rf /etc/systemd/system/docker.service
			sudo rm -rf /usr/bin/docker
			sudo rm -rf /usr/bin/docker-compose
			sudo rm -rf /usr/lib/docker/cli-plugins/docker-compose
			sudo rm -rf /usr/bin/dockerd
			installing
		else
			echo "Docker service is already running."
		fi
	else
		echo "Docker service is not running"
		installing
	fi
	check-version
	chmod -x $0
	generate_docker_compose
	/usr/bin/newgrp docker <<EONG
id
EONG
}

# Run Docker compose
function rundocker {
	sudo docker compose up -d
}

function checkup_influx {
	INFLUXCNF="./telegraf-config/telegraf.d/000-influxdb.conf"
	local user=$(cat .env.influxdb-admin-username)
	local pass=$(cat .env.influxdb-admin-password)
	local token=$(cat .env.influxdb-admin-token)
	local org=$(grep -E '^\s*organization\s*=' "$INFLUXCNF" | sed -E 's/.*=\s*"(.*)"/\1/')
	local bket=$(grep -E '^\s*bucket\s*=' "$INFLUXCNF" | sed -E 's/.*=\s*"(.*)"/\1/')
	HOST_URL=http://localhost:8086
	until curl -s "$HOST_URL/health" | grep -q '"status":"pass"'; do
    	sleep 2
    	echo -n "."
	done
	sudo docker exec -i influxdb influx setup \
				--username "$user" \
				--password "$pass" \
				--token "$token" \
				--org "$org" \
				--bucket "$bket" \
				--force

}

# Main script execution
precheck
post_process
generate_envfile
gen_telegraf
gen_influxdb
rundocker
checkup_influx

echo "InfluxDB token = $INFLUX_TOKEN"
echo "Please check $HOST_URL and get .env* for credentials"
echo "Installation docker, docker compose, telegraf, influxdb, grafana finished"