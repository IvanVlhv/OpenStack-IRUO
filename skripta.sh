#!/usr/bin/env bash
set -euo pipefail

# ──────────────────────────────
# Konfiguracija (možeš overrideati preko env varijabli)
# ──────────────────────────────
CSV_FILE="${1:-users.csv}"                     # CSV: ime;prezime;rola
EXT_NET="${EXT_NET:-provider-datacentre}"      # vanjska mreža (RHEL lab: provider-datacentre)
IMAGE="${IMAGE:-}"                              # ako ostaviš prazno, auto-detekcija ispod
FLAVOR="${FLAVOR:-m1.small}"                    # ~1 vCPU / 1GB (prilagodi)
VOL_SIZE_GB="${VOL_SIZE_GB:-5}"                 # veličina dodatnih diskova
ADMIN_USER="${ADMIN_USER:-azureuser}"           # korisnik na VM-ovima
LAB_PASSWORD="${LAB_PASSWORD:-ChangeMe!123}"    # lab password (isti za sve)
KEYPAIR="${KEYPAIR:-}"                          # opcionalno: OpenStack keypair ime
ROUTER_NAME="${ROUTER_NAME:-course-router}"
DNS_NS="${DNS_NS:-8.8.8.8}"                     # npr. 172.25.250.254 u labu

# HUB (instruktorska mreža)
HUB_NET="hub-net"
HUB_SUBNET="hub-subnet"
HUB_CIDR="10.90.1.0/24"

# ──────────────────────────────
# Helpers
# ──────────────────────────────
need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: missing command: $1"; exit 1; }; }
need_cmd openstack
need_cmd awk
need_cmd sed
need_cmd tr
need_cmd mktemp

safe() { echo "$1" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9' | cut -c1-20; }
addr_block(){ local i="$1"; echo "10.91.${i}.0/24"; }
app_prefix(){ local i="$1"; echo "10.91.${i}.0/25"; }
jump_prefix(){ local i="$1"; echo "10.91.${i}.128/26"; }

os_id() { local type="$1" name="$2"; openstack $type show "$name" -f value -c id 2>/dev/null || true; }

# Odaberi image ako korisnik nije dao ili ako zadani ne postoji
auto_pick_image() {
  local wanted="$1"
  if [[ -n "$wanted" ]]; then
    if openstack image show "$wanted" >/dev/null 2>&1; then echo "$wanted"; return 0; fi
    echo "[!] IMAGE '$wanted' not found — trying auto-detect..." >&2
  fi
  local names; names="$(openstack image list --status active -f value -c Name || true)"
  [[ -z "$names" ]] && { echo "[!] No images found in Glance." >&2; return 1; }

  # preferiraj RHEL, zatim Rocky/Alma, pa Ubuntu
  local try_pats=(
    "rhel.*9|rhel9" "rhel.*8|rhel8"
    "rocky.*9" "almalinux.*9"
    "ubuntu.*22.04|jammy" "ubuntu.*20.04|focal"
    "debian.*12" "fedora"
  )
  local img
  for pat in "${try_pats[@]}"; do
    img="$(echo "$names" | grep -E -i "$pat" | head -n1 || true)"
    [[ -n "$img" ]] && { echo "$img"; return 0; }
  done
  img="$(echo "$names" | head -n1)"
  echo "$img"
}

ensure_router() {
  local rid; rid=$(os_id router "$ROUTER_NAME")
  if [[ -z "$rid" ]]; then
    echo "[i] Creating router $ROUTER_NAME"
    openstack router create "$ROUTER_NAME" >/dev/null
  fi
  echo "[i] Setting router external gateway -> $EXT_NET"
  openstack router set "$ROUTER_NAME" --external-gateway "$EXT_NET"
}

ensure_hub_net() {
  local nid sid
  nid=$(os_id network "$HUB_NET") || true
  if [[ -z "$nid" ]]; then
    echo "[i] Creating hub network $HUB_NET"
    openstack network create "$HUB_NET" >/dev/null
  fi
  sid=$(os_id subnet "$HUB_SUBNET") || true
  if [[ -z "$sid" ]]; then
    echo "[i] Creating hub subnet $HUB_SUBNET ($HUB_CIDR)"
    openstack subnet create "$HUB_SUBNET" --network "$HUB_NET" \
      --subnet-range "$HUB_CIDR" --dns-nameserver "$DNS_NS" >/dev/null
    echo "[i] Attaching $HUB_SUBNET to router $ROUTER_NAME"
    openstack router add subnet "$ROUTER_NAME" "$HUB_SUBNET" >/dev/null || true
  fi
}

make_cloud_init_wp() {
  local studuser="$1" out="$2"
  cat > "$out" <<'CLOUD'
#cloud-config
ssh_pwauth: true
chpasswd:
  list: |
    __ADMIN__:__PASS__
    __STUDUSER__:__PASS__
  expire: false

write_files:
  - path: /etc/nginx/wordpress.conf
    content: |
      server {
        listen 80 default_server;
        listen [::]:80 default_server;
        root /var/www/html;
        index index.php index.html index.htm;
        server_name _;
        location / { try_files $uri $uri/ /index.php?$args; }
        location ~ \.php$ {
          include fastcgi_params;
          include snippets/fastcgi-php.conf;
          fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
          fastcgi_pass unix:/run/php/php-fpm.sock;  # bit će zamijenjeno na /run/php-fpm/www.sock na RHEL-u
        }
        location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg)$ { expires max; log_not_found off; }
      }

runcmd:
  # 1) paketi (apt ili dnf)
  - |
    if command -v apt-get >/dev/null 2>&1; then
      apt-get update -y
      DEBIAN_FRONTEND=noninteractive apt-get install -y nginx php-fpm php-cli php-xml php-curl php-zip php-mbstring php-gd php-sqlite3 unzip
    elif command -v dnf >/dev/null 2>&1; then
      dnf -y module reset php || true
      dnf -y module enable php:8.2 || true
      dnf -y install nginx php php-fpm php-cli php-common php-gd php-mbstring php-xml php-json php-zip php-pdo php-sqlite3 unzip policycoreutils-python-utils || true
    fi

  # 2) ispravan nginx conf lokacija (Ubuntu sites-available vs RHEL conf.d)
  - |
    if [ -d /etc/nginx/sites-available ]; then
      mv -f /etc/nginx/wordpress.conf /etc/nginx/sites-available/default
    else
      mv -f /etc/nginx/wordpress.conf /etc/nginx/conf.d/wordpress.conf
    fi

  # 3) zamijeni fastcgi socket ovisno o distro
  - |
    PHP_SOCK="/run/php/php-fpm.sock"
    [ -e /run/php-fpm/www.sock ] && PHP_SOCK="/run/php-fpm/www.sock"
    sed -ri "s#fastcgi_pass unix:.*sock;#fastcgi_pass unix:${PHP_SOCK};#" /etc/nginx/sites-available/default 2>/dev/null || true
    sed -ri "s#fastcgi_pass unix:.*sock;#fastcgi_pass unix:${PHP_SOCK};#" /etc/nginx/conf.d/wordpress.conf 2>/dev/null || true

  # 4) WordPress + SQLite plugin
  - mkdir -p /var/www/html
  - curl -L https://wordpress.org/latest.tar.gz -o /tmp/wp.tgz
  - tar -xzf /tmp/wp.tgz -C /var/www/html --strip-components=1
  - curl -L https://downloads.wordpress.org/plugin/sqlite-database-integration.latest-stable.zip -o /tmp/sqlite.zip
  - unzip -o /tmp/sqlite.zip -d /var/www/html/wp-content/plugins
  - cp /var/www/html/wp-content/plugins/sqlite-database-integration/db.copy /var/www/html/wp-content/db.php
  - chown -R www-data:www-data /var/www/html || chown -R nginx:nginx /var/www/html || true

  # 5) servisi
  - systemctl enable --now php*-fpm || systemctl enable --now php-fpm || true
  - systemctl enable --now nginx || true
  - systemctl restart nginx || true
CLOUD
  sed -i "s|__ADMIN__|${ADMIN_USER}|g" "$out"
  sed -i "s|__STUDUSER__|${studuser}|g" "$out"
  sed -i "s|__PASS__|${LAB_PASSWORD}|g" "$out"
}

make_cloud_init_jump() {
  local studuser="$1" out="$2"
  cat > "$out" <<'CLOUD'
#cloud-config
ssh_pwauth: true
chpasswd:
  list: |
    __ADMIN__:__PASS__
    __STUDUSER__:__PASS__
  expire: false
runcmd:
  - '[ -x /usr/bin/apt-get ] && (apt-get update -y; apt-get install -y htop tmux) || true'
  - '[ -x /usr/bin/dnf ] && dnf install -y htop tmux || true'
CLOUD
  sed -i "s|__ADMIN__|${ADMIN_USER}|g" "$out"
  sed -i "s|__STUDUSER__|${studuser}|g" "$out"
  sed -i "s|__PASS__|${LAB_PASSWORD}|g" "$out"
}

create_secgroups_for_student() {
  local student="$1" app_cidr="$2" jump_cidr="$3"
  local sg_jump="sg-jump-${student}"
  local sg_app="sg-app-${student}"

  if [[ -z "$(os_id security group "$sg_jump")" ]]; then
    openstack security group create "$sg_jump" >/dev/null
  fi

  if [[ -z "$(os_id security group "$sg_app")" ]]; then
    openstack security group create "$sg_app" >/dev/null
  fi

  # JUMP: SSH s Interneta + egress
  openstack security group rule create --ingress --protocol tcp --dst-port 22 --remote-ip 0.0.0.0/0 "$sg_jump" >/dev/null || true
  openstack security group rule create --egress "$sg_jump" >/dev/null || true

  # APP: dopušteno samo iz vlastitog JUMP subnet-a i HUB-a (SSH/HTTP) + egress
  openstack security group rule create --ingress --protocol tcp --dst-port 22 --remote-ip "$jump_cidr" "$sg_app" >/dev/null || true
  openstack security group rule create --ingress --protocol tcp --dst-port 80 --remote-ip "$jump_cidr" "$sg_app" >/dev/null || true
  openstack security group rule create --ingress --protocol tcp --dst-port 22 --remote-ip "$HUB_CIDR" "$sg_app" >/dev/null || true
  openstack security group rule create --ingress --protocol tcp --dst-port 80 --remote-ip "$HUB_CIDR" "$sg_app" >/dev/null || true
  openstack security group rule create --egress "$sg_app" >/dev/null || true
}

create_network_for_student() {
  local student="$1" _vnet_cidr="$2" app_cidr="$3" jump_cidr="$4"
  local net="stu-${student}-net"
  local app_sn="app-${student}-subnet"
  local jump_sn="jump-${student}-subnet"

  if [[ -z "$(os_id network "$net")" ]]; then
    echo "[i] Creating network $net"
    openstack network create "$net" >/dev/null
  fi

  if [[ -z "$(os_id subnet "$app_sn")" ]]; then
    echo "[i] Creating subnet $app_sn ($app_cidr)"
    openstack subnet create "$app_sn" --network "$net" \
      --subnet-range "$app_cidr" --dns-nameserver "$DNS_NS" >/dev/null
    openstack router add subnet "$ROUTER_NAME" "$app_sn" >/dev/null || true
  fi

  if [[ -z "$(os_id subnet "$jump_sn")" ]]; then
    echo "[i] Creating subnet $jump_sn ($jump_cidr)"
    openstack subnet create "$jump_sn" --network "$net" \
      --subnet-range "$jump_cidr" --dns-nameserver "$DNS_NS" >/dev/null
    openstack router add subnet "$ROUTER_NAME" "$jump_sn" >/dev/null || true
  fi
}

boot_server() {
  local name="$1" net="$2" subnet="$3" sg="$4" user_data="$5"
  local net_id sub_id
  net_id=$(openstack network show "$net" -f value -c id)
  sub_id=$(openstack subnet show "$subnet" -f value -c id)

  local args=(--image "$IMAGE" --flavor "$FLAVOR" --security-group "$sg" --nic "net-id=${net_id},subnet-id=${sub_id}" --user-data "$user_data")
  [[ -n "$KEYPAIR" ]] && args+=(--key-name "$KEYPAIR")

  echo "[i] Creating server $name (image: $IMAGE)"
  openstack server create "$name" "${args[@]}" >/dev/null

  openstack server wait --active "$name" >/dev/null || true
  for d in 1 2; do
    local vol="${name}-vol${d}"
    openstack volume create --size "$VOL_SIZE_GB" "$vol" >/dev/null
    openstack server add volume "$name" "$vol" >/dev/null
  done
}

assign_fip() {
  local server="$1"
  local fip; fip=$(openstack floating ip create "$EXT_NET" -f value -c floating_ip_address)
  openstack server add floating ip "$server" "$fip" >/dev/null
  echo "$fip"
}

# ──────────────────────────────
# Početak
# ──────────────────────────────
if [[ ! -f "$CSV_FILE" ]]; then
  echo "Usage: $0 users.csv    (CSV: ime;prezime;rola)"
  exit 1
fi

echo "[i] Using external network: $EXT_NET"
ensure_router
ensure_hub_net

# Odaberi image (auto ako nije zadan ili ne postoji)
IMAGE="$(auto_pick_image "$IMAGE")"
[[ -z "$IMAGE" ]] && { echo "[!] No suitable image found. Set IMAGE env var."; exit 1; }
echo "[i] Selected image: $IMAGE"

# Instruktorski SG
if [[ -z "$(os_id security group sg-instructor)" ]]; then
  openstack security group create sg-instructor >/dev/null
  openstack security group rule create --egress sg-instructor >/dev/null || true
fi

# 1) Instruktorski VM-ovi (bez FIP-a)
while IFS=';' read -r ime prezime rola; do
  [[ -z "${ime:-}" ]] && continue
  [[ "${ime,,}" == "ime" ]] && continue
  localname="$(safe "${ime}${prezime}")"
  role_lc="$(echo "${rola:-}" | tr '[:upper:]' '[:lower:]')"
  if [[ "$role_lc" == "instruktor" ]]; then
    ci=$(mktemp); make_cloud_init_jump "instr_${localname}" "$ci"
    boot_server "instructor-${localname}" "$HUB_NET" "$HUB_SUBNET" "sg-instructor" "$ci"
    rm -f "$ci"
  fi
done < "$CSV_FILE"

# 2) Po studentu: mreža + SG + jump(FIP) + 1x WP (⇒ ukupno 2 VM-a po studentu)
idx=1
while IFS=';' read -r ime prezime rola; do
  [[ -z "${ime:-}" ]] && continue
  [[ "${ime,,}" == "ime" ]] && continue
  role_lc="$(echo "${rola:-}" | tr '[:upper:]' '[:lower:]')"
  [[ "$role_lc" != "student" ]] && continue

  student="$(safe "${ime}${prezime}")"
  vnet_cidr=$(addr_block "$idx")
  app_cidr=$(app_prefix "$idx")
  jump_cidr=$(jump_prefix "$idx")
  idx=$((idx+1))

  echo "[i] Student ${ime} ${prezime} -> ${student} | app:${app_cidr} jump:${jump_cidr}"
  create_network_for_student "$student" "$vnet_cidr" "$app_cidr" "$jump_cidr"
  create_secgroups_for_student "$student" "$app_cidr" "$jump_cidr"

  # Jump + FIP
  jci=$(mktemp); make_cloud_init_jump "stud_${student}" "$jci"
  boot_server "jump-${student}" "stu-${student}-net" "jump-${student}-subnet" "sg-jump-${student}" "$jci"
  fip=$(assign_fip "jump-${student}")
  echo "[i] jump-${student} FIP: $fip"
  rm -f "$jci"

  # Jedan WordPress VM (privatan)
  wci=$(mktemp); make_cloud_init_wp "stud_${student}" "$wci"
  boot_server "wp-${student}-1" "stu-${student}-net" "app-${student}-subnet" "sg-app-${student}" "$wci"
  rm -f "$wci"

done < "$CSV_FILE"

echo "[✓] Done."
echo
echo "Korisno:"
echo "  openstack server list"
echo "  openstack floating ip list"
echo "  # SSH na jump: ssh ${ADMIN_USER}@<FIP>"
echo "  # sa jump-a na WP: ssh ${ADMIN_USER}@<privatni-IP>"
