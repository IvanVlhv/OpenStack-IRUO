#!/usr/bin/env bash
set -euo pipefail

CSV_FILE="${1:-users.csv}"        
EXT_NET="${EXT_NET:-provider-datacentre}"  
IMAGE="${IMAGE:-rhel8}"                 
FLAVOR="${FLAVOR:-default}"       
VOL_SIZE_GB="${VOL_SIZE_GB:-5}"    
ADMIN_USER="${ADMIN_USER:-admin}"
LAB_PASSWORD="${LAB_PASSWORD:-Lozinka!123}"  
KEYPAIR="${KEYPAIR:-}"             
ROUTER_NAME="${ROUTER_NAME:-course-router}"
BOOT_FROM_VOLUME="${BOOT_FROM_VOLUME:-false}"
BOOT_VOLUME_SIZE_GB="${BOOT_VOLUME_SIZE_GB:-10}"

HUB_NET="hub-net"
HUB_SUBNET="hub-subnet"
HUB_CIDR="10.90.1.0/24"
DNS_NS="${DNS_NS:-8.8.8.8}"


need_cmd(){ command -v "$1" >/dev/null 2>&1 || { echo "ERROR: missing command: $1"; exit 1; }; }
need_cmd openstack; need_cmd awk; need_cmd sed; need_cmd tr; need_cmd mktemp

safe(){ echo "$1" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9' | cut -c1-20; }
addr_block(){ local i="$1"; echo "10.91.${i}.0/24"; }
app_prefix(){  local i="$1"; echo "10.91.${i}.0/25"; }
jump_prefix(){ local i="$1"; echo "10.91.${i}.128/26"; }

os_id(){ openstack "$1" show "$2" -f value -c id 2>/dev/null || true; }


wait_server_active(){
  local name="$1" timeout="${2:-900}" start=$(date +%s)
  echo "[i] Waiting for server $name to become ACTIVE..."
  while true; do
    local st ts vm
    st=$(openstack server show "$name" -f value -c status 2>/dev/null || echo "")
    ts=$(openstack server show "$name" -f value -c "OS-EXT-STS:task_state" 2>/dev/null | tr -d '\r' || true)
    vm=$(openstack server show "$name" -f value -c "OS-EXT-STS:vm_state" 2>/dev/null | tr -d '\r' || true)
    [[ -z "$st" ]] && st="N/A"; [[ -z "$ts" ]] && ts="None"; [[ -z "$vm" ]] && vm="N/A"
    echo "    -> status=${st} task=${ts} vm_state=${vm}"
    if [[ "$st" == "ACTIVE" && "$ts" == "None" ]]; then return 0; fi
    if [[ "$st" == "ERROR" ]]; then echo "[!] $name ended in ERROR"; return 1; fi
    (( $(date +%s) - start > timeout )) && { echo "[!] timeout waiting $name ACTIVE"; return 1; }
    sleep 5
  done
}

wait_volume_status(){
  local vol="$1" want="${2:-available}" timeout="${3:-300}" start=$(date +%s)
  echo "[i] Waiting volume $vol -> $want ..."
  while openstack volume show "$vol" >/dev/null 2>&1; do
    local st; st=$(openstack volume show "$vol" -f value -c status 2>/dev/null || echo "")
    echo "    -> status=$st"
    [[ "$st" == "$want" ]] && return 0
    [[ "$st" =~ ^error ]] && { echo "[!] volume $vol in error ($st)"; return 1; }
    (( $(date +%s) - start > timeout )) && { echo "[!] timeout waiting $vol -> $want"; return 1; }
    sleep 3
  done
  return 0
}

ensure_sg(){
  local sg="$1"
  if [[ -z "$(os_id 'security group' "$sg")" ]]; then
    openstack security group create "$sg" >/dev/null
  fi
  for i in {1..20}; do
    openstack security group show "$sg" >/dev/null 2>&1 && return 0
    sleep 0.5
  done
  return 0
}

ensure_rule(){
  local sg="$1" dir="$2" proto="$3" port="$4" remote="$5"
  openstack security group rule create --"$dir" --protocol "$proto" \
    ${port:+--dst-port "$port"} ${remote:+--remote-ip "$remote"} "$sg" >/dev/null 2>&1 || true
}

create_secgroups_for_student(){
  local student="$1" app_cidr="$2" jump_cidr="$3"
  local sg_jump="sg-jump-${student}"
  local sg_app="sg-app-${student}"

  ensure_sg "$sg_jump"
  ensure_rule "$sg_jump" ingress tcp 22 "0.0.0.0/0"
  ensure_rule "$sg_jump" egress  ""  ""  ""

  ensure_sg "$sg_app"
  ensure_rule "$sg_app" ingress tcp 22 "$jump_cidr"
  ensure_rule "$sg_app" ingress tcp 80 "$jump_cidr"
  ensure_rule "$sg_app" ingress tcp 22 "$HUB_CIDR"
  ensure_rule "$sg_app" ingress tcp 80 "$HUB_CIDR"
  ensure_rule "$sg_app" egress  ""  ""  ""
}

# mreža
ensure_router() {
  local rid
  rid=$(os_id router "$ROUTER_NAME")
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
    openstack router add subnet "$ROUTER_NAME" "$HUB_SUBNET" >/dev/null
  fi
}

create_network_for_student() {
  local student="$1" vnet_cidr="$2" app_cidr="$3" jump_cidr="$4"
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
    openstack router add subnet "$ROUTER_NAME" "$app_sn" >/dev/null
  fi

  if [[ -z "$(os_id subnet "$jump_sn")" ]]; then
    echo "[i] Creating subnet $jump_sn ($jump_cidr)"
    openstack subnet create "$jump_sn" --network "$net" \
      --subnet-range "$jump_cidr" --dns-nameserver "$DNS_NS" >/dev/null
    openstack router add subnet "$ROUTER_NAME" "$jump_sn" >/dev/null
  fi
}

# cloud-init 
make_cloud_init_jump() {
  local studuser="$1" out="$2"
  cat > "$out" <<'CLOUD'
#cloud-config
ssh_pwauth: true
disable_root: true
package_update: true
packages: [ htop, tmux ]
runcmd:
  # ensure users exist
  - id -u __ADMIN__ >/dev/null 2>&1 || useradd -m -s /bin/bash __ADMIN__
  - id -u __STUDUSER__ >/dev/null 2>&1 || useradd -m -s /bin/bash __STUDUSER__
  # set passwords
  - bash -lc 'echo "__ADMIN__:__PASS__" | chpasswd'
  - bash -lc 'echo "__STUDUSER__:__PASS__" | chpasswd'
  # sudo (wheel na RHEL, sudo na Ubuntu)
  - usermod -aG wheel __ADMIN__  || true
  - usermod -aG wheel __STUDUSER__ || true
  - usermod -aG sudo  __ADMIN__  || true
  - usermod -aG sudo  __STUDUSER__ || true
  # enforce password SSH
  - sed -ri 's/^#?PasswordAuthentication .*/PasswordAuthentication yes/' /etc/ssh/sshd_config
  - systemctl restart sshd || systemctl restart ssh || true
CLOUD
  sed -i "s|__ADMIN__|${ADMIN_USER}|g" "$out"
  sed -i "s|__STUDUSER__|${studuser}|g" "$out"
  sed -i "s|__PASS__|${LAB_PASSWORD}|g" "$out"
}

make_cloud_init_wp() {
  local studuser="$1" out="$2"
  cat > "$out" <<'CLOUD'
#cloud-config
ssh_pwauth: true
disable_root: true
package_update: true
packages:
  - nginx
  - php-fpm
  - php-cli
  - php-xml
  - php-curl
  - php-zip
  - php-mbstring
  - php-gd
  - php-sqlite3
  - unzip
write_files:
  - path: /etc/nginx/conf.d/default.conf
    content: |
      server {
        listen 80 default_server;
        listen [::]:80 default_server;
        root /var/www/html;
        index index.php index.html index.htm;
        server_name _;
        location / { try_files $uri $uri/ /index.php?$args; }
        location ~ \.php$ {
          include /etc/nginx/fastcgi.conf;
          fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
          fastcgi_pass unix:/run/php/php-fpm.sock;
        }
        location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg)$ { expires max; log_not_found off; }
      }
runcmd:
  # ensure users exist
  - id -u __ADMIN__ >/dev/null 2>&1 || useradd -m -s /bin/bash __ADMIN__
  - id -u __STUDUSER__ >/dev/null 2>&1 || useradd -m -s /bin/bash __STUDUSER__
  # set passwords
  - bash -lc 'echo "__ADMIN__:__PASS__" | chpasswd'
  - bash -lc 'echo "__STUDUSER__:__PASS__" | chpasswd'
  # sudo groups
  - usermod -aG wheel __ADMIN__  || true
  - usermod -aG wheel __STUDUSER__ || true
  - usermod -aG sudo  __ADMIN__  || true
  - usermod -aG sudo  __STUDUSER__ || true
  # enforce password SSH
  - sed -ri 's/^#?PasswordAuthentication .*/PasswordAuthentication yes/' /etc/ssh/sshd_config
  - systemctl restart sshd || systemctl restart ssh || true
  # PHP sock path fix (RHEL/Ubuntu agnostic)
  - 'PHP_SOCK=$(ls /run/php/php*-fpm.sock /var/run/php-fpm/www.sock 2>/dev/null | head -n1 || echo /run/php/php8.1-fpm.sock); sed -ri "s#fastcgi_pass unix:.*fpm\.sock;#fastcgi_pass unix:${PHP_SOCK};#" /etc/nginx/conf.d/default.conf || true'
  # WordPress + SQLite plugin
  - mkdir -p /var/www/html
  - curl -L https://wordpress.org/latest.tar.gz -o /tmp/wp.tgz
  - tar -xzf /tmp/wp.tgz -C /var/www/html --strip-components=1
  - curl -L https://downloads.wordpress.org/plugin/sqlite-database-integration.latest-stable.zip -o /tmp/sqlite.zip
  - unzip -o /tmp/sqlite.zip -d /var/www/html/wp-content/plugins
  - cp /var/www/html/wp-content/plugins/sqlite-database-integration/db.copy /var/www/html/wp-content/db.php
  - chown -R nginx:nginx /var/www/html || chown -R www-data:www-data /var/www/html || true
  - systemctl enable --now php*-fpm || systemctl enable --now php-fpm || systemctl enable --now php8.1-fpm || true
  - systemctl restart nginx || systemctl restart nginx.service || true
CLOUD
  sed -i "s|__ADMIN__|${ADMIN_USER}|g" "$out"
  sed -i "s|__STUDUSER__|${studuser}|g" "$out"
  sed -i "s|__PASS__|${LAB_PASSWORD}|g" "$out"
}

# server boot
boot_server() {
  local name="$1" net="$2" subnet="$3" sg="$4" user_data="$5"

  local net_id sub_id
  net_id=$(openstack network show "$net" -f value -c id)
  sub_id=$(openstack subnet show "$subnet" -f value -c id)

  local port="port-${name}"
  if ! openstack port show "$port" >/dev/null 2>&1; then
    echo "[i] Creating port ${port} on ${net}/${subnet} with SG ${sg}"
    openstack port create "$port" \
      --network "$net_id" \
      --fixed-ip "subnet=${sub_id}" \
      --security-group "$sg" >/dev/null
  fi
  local port_id; port_id=$(openstack port show "$port" -f value -c id)

  local args=( --flavor "$FLAVOR" --user-data "$user_data" --nic "port-id=${port_id}" )
  # odaberi image ako nije zadan
  if [[ -z "$IMAGE" ]]; then
    IMAGE="$(openstack image list -f value -c Name | grep -E '^rhel-?9|rhel9|rhel-?8|rhel8|ubuntu-22\.04' | head -n1 || true)"
    [[ -z "$IMAGE" ]] && IMAGE="$(openstack image list -f value -c Name | head -n1)"
  fi
  args+=( --image "$IMAGE" )
  [[ -n "$KEYPAIR" ]] && args+=( --key-name "$KEYPAIR" )
  if [[ "${BOOT_FROM_VOLUME}" == "true" ]]; then
    args+=( --boot-from-volume "${BOOT_VOLUME_SIZE_GB}" )
  fi

  echo "[i] Creating server $name (image: $IMAGE)"
  openstack server create "$name" "${args[@]}" >/dev/null

  wait_server_active "$name" 900 || { echo "[!] $name not ACTIVE, skipping volumes"; return 1; }

  for d in 1 2; do
    local vol="${name}-vol${d}"
    echo "[i] Creating volume $vol (${VOL_SIZE_GB}GB)"
    openstack volume create --size "$VOL_SIZE_GB" "$vol" >/dev/null
    wait_volume_status "$vol" available 300 || true
    echo "[i] Attaching $vol -> $name"
    openstack server add volume "$name" "$vol" >/dev/null || true
    wait_volume_status "$vol" in-use 300 || true
  done
}

assign_fip() {
  local server="$1"
  local fip
  fip=$(openstack floating ip create "$EXT_NET" -f value -c floating_ip_address)
  openstack server add floating ip "$server" "$fip" >/dev/null
  echo "$fip"
}

#-----
if [[ ! -f "$CSV_FILE" ]]; then
  echo "Usage: $0 users.csv    (CSV: ime;prezime;rola)"; exit 1
fi

echo "[i] Using external network: $EXT_NET"
ensure_router
ensure_hub_net

#wait_lb_active() {
#  local lb="$1"
#  while :; do
#    st=$(openstack loadbalancer show "$lb" -f value -c provisioning_status 2>/dev/null || echo ERROR)
#    [[ "$st" == "ACTIVE" ]] && break
#    sleep 3
#  done
#}

#create_lb_for_student() {
#  local student="$1"
#  local app_sn="app-${student}-subnet"
#  local lb="lb-${student}" ls="http-${student}" pool="pool-${student}" hm="hm-${student}"
#  local app_subnet_id
#  app_subnet_id=$(openstack subnet show "$app_sn" -f value -c id)
#  echo "[i] Creating LB for $student"

#  openstack loadbalancer create --name "$lb" --vip-subnet-id "$app_subnet_id" >/dev/null
#  wait_lb_active "$lb"
#  openstack loadbalancer listener create --name "$ls" --protocol HTTP --protocol-port 80 "$lb" >/dev/null
#  openstack loadbalancer pool create --name "$pool" --lb-algorithm ROUND_ROBIN --listener "$ls" --protocol HTTP >/dev/null
#  openstack loadbalancer healthmonitor create --name "$hm" --delay 5 --timeout 3 --max-retries 3 --type HTTP --url-path / "$pool" >/dev/null
# for vm in $(openstack server list -f value -c Name | grep "^wp-${student}-"); do
#    ip=$(openstack server show "$vm" -f value -c addresses | sed -E 's/.*=([0-9.]+).*/\1/')
#    openstack loadbalancer member create --subnet-id "$app_subnet_id" \
#      --address "$ip" --protocol-port 80 "$pool" >/dev/null
#  done
#  wait_lb_active "$lb"
#  vip=$(openstack loadbalancer show "$lb" -f value -c vip_address)
#  echo "[i] LB VIP for ${student}: $vip"
#}


#INSTRUKTOR
ensure_sg "sg-instructor"
ensure_rule "sg-instructor" egress "" "" ""


while IFS=';' read -r ime prezime rola; do
  [[ -z "${ime:-}" ]] && continue
  [[ "${ime,,}" == "ime" ]] && continue
  role_lc="$(echo "${rola:-}" | tr '[:upper:]' '[:lower:]')"
  [[ "$role_lc" != "instruktor" ]] && continue

  localname="$(safe "${ime}${prezime}")"
  ci=$(mktemp); make_cloud_init_jump "instr_${localname}" "$ci"
  boot_server "instructor-${localname}" "$HUB_NET" "$HUB_SUBNET" "sg-instructor" "$ci"
  rm -f "$ci"
done < "$CSV_FILE"

#S+TUDENTI
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

  echo "[i] Student ${ime} ${prezime} -> ${student} | VNet:${vnet_cidr} app:${app_cidr} jump:${jump_cidr}"

  create_network_for_student "$student" "$vnet_cidr" "$app_cidr" "$jump_cidr"
  create_secgroups_for_student "$student" "$app_cidr" "$jump_cidr"

  # Jump host s FIP
  jci=$(mktemp); make_cloud_init_jump "stud_${student}" "$jci"
  boot_server "jump-${student}" "stu-${student}-net" "jump-${student}-subnet" "sg-jump-${student}" "$jci"
  fip=$(assign_fip "jump-${student}")
  echo "[i] jump-${student} FIP: $fip"
  rm -f "$jci"

  # WordPress VM (privatan)
  wci=$(mktemp); make_cloud_init_wp "stud_${student}" "$wci"
  boot_server "wp-${student}-1" "stu-${student}-net" "app-${student}-subnet" "sg-app-${student}" "$wci"
  rm -f "$wci"

done < "$CSV_FILE"

echo "[✓] Done."
echo
echo "Korisno:"
echo "  openstack server list"
echo "  openstack floating ip list"
echo "  # SSH na jump: ssh ${ADMIN_USER}@<FIP> (pass: ${LAB_PASSWORD})"
echo "  # sa jump-a na WP: ssh ${ADMIN_USER}@<privatni-IP>"