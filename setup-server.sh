#!/usr/bin/env bash
# =============================================================================
#  setup-server.sh — Provisioning & hardening Ubuntu Server 22.04+
#  PT Roemah Toedjoeh Indonesia
#
#  Cara pakai (JANGAN pakai "wget ... | bash", karena pop-up butuh keyboard):
#    wget -qO setup-server.sh <URL> && sudo bash setup-server.sh
#  atau
#    sudo bash <(wget -qO- <URL>)
#
#  Isi:
#    1. Repository mirror Indonesia (Kartolo / UI)     6. Hardening SSH (port 1722, key-only)
#    2. Update paket + paket pendukung                 7. Firewall UFW
#    3. Timezone Asia/Jakarta                          8. Fail2ban
#    4. User monday & friday (sudo, auto-root)         9. Docker + Uptime Kuma
#    5. Hostname, search domain & /etc/hosts          10. IP statis (netplan) — dijalankan terakhir
#
#  Semua pertanyaan diajukan di awal. Sistem baru diubah setelah ringkasan disetujui.
#  Aman dijalankan ulang (idempotent). Password TIDAK pernah disimpan di script/log.
# =============================================================================

if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi
set -Eeuo pipefail

# ----------------------------- Konfigurasi tetap -----------------------------
readonly SCRIPT_VERSION="1.0.0"
readonly SSH_PORT=1722
readonly SSH_ALLOW_USERS="monday friday"
readonly TIMEZONE="Asia/Jakarta"
readonly KUMA_PORT=3001
readonly KUMA_IMAGE="louislam/uptime-kuma:2"
readonly KUMA_DIR="/opt/uptime-kuma"
readonly F2B_BANTIME="1d"
readonly F2B_FINDTIME="10m"
readonly F2B_MAXRETRY=3
readonly LOG_FILE="/var/log/server-setup.log"
BACKUP_DIR="/root/server-setup-backup/$(date +%Y%m%d-%H%M%S)"
readonly BACKUP_DIR
readonly SSHD_CONF="/etc/ssh/sshd_config.d/00-setup-server.conf"
readonly NETPLAN_FILE="/etc/netplan/01-setup-server.yaml"

# SSH public key untuk user friday (public key aman untuk dipublikasikan)
readonly FRIDAY_SSH_KEYS=(
  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDr4LDqLME0U6poJWgfDNpzbCTxDvJUaKu+7D7uhTycd satriya.ivanwahyu@gmail.com"
  "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQDfh5z6iemDGtBtLD8dqRjRaN3W6POiv0PRpFSPmcybtL+BOTNu5Z/rVjIuqbyJsOrkNMTYeAIeBJhk73AumGlumeEwr6jxSQkUxQM3QASMeluZnvliZs+izDkU54B3TKGxqso+fVP/UsWBfkheVQU+8t+o6RsJw4c8oF291Ubf/WvzwRzrxL7xhDNoBnwYlDUy1Z/f5g9McufTwU8pJ8DPWiajy4SDAIZGn50iGBSAdJhpJCPAC7ku/RPQGJidvTX3uv6HJBgaCrV112eJcAamWCEMwvKIcbTbVu1kRJBrdXU35fy63gE+EwtPNx0FfHgq4LqrrOGa4e2c9iCp3dasYjmlOpg0gqZgpqtCbzGw+PlgsiwHP/3wqCdN1/jx9H8zhjO87r9GVoIneQRfhz2djDgf1zJMS5SUeDogv1J/kVCb0DYKOaq5D9xk7Ot5WZLY0UEOG5g1ft9VZ+5hrTLhqF6lT98leto2y4Y0y3P6XBo7wJPbR++QkcNHQHkW0eGi5hqxFRhf8kQ1EPoGuNx8uQXJpv1nDZVM9zN5HJjJxsPfLIdtf6quv4D6GA7Jy0wQtXDApgMmW7joYOuNw95heaxwR7qOignU13ai8DIQFT73AU/m5JiCasskNFUEQXaCF3lF14s2+bupTt9wtnyLhWd7Aj06V523BW51eA6nBQ== satriya.ivanwahyu@gmail.com"
)

declare -A MIRROR_URL=(
  [kartolo]="http://kartolo.sby.datautama.net.id/ubuntu/"
  [ui]="http://kambing.ui.ac.id/ubuntu/"
)
declare -A MIRROR_NAME=(
  [kartolo]="Kartolo (Datautama, Surabaya)"
  [ui]="Kambing (Universitas Indonesia)"
)

# ------------------------------ Variabel global ------------------------------
OS_CODENAME="" OS_PRETTY=""
VIA_SSH=0 CLIENT_IP="" SERVER_IP="" SERVER_PORT=""
TEMP_PORT22=0
MONDAY_EXISTS=0 FRIDAY_EXISTS=0 MONDAY_PW="" FRIDAY_PW="" REPLY_PW=""
MIRROR_KEY="" DO_UPGRADE=0
NET_CONFIGURE=0 NET_IF="" NET_ADDR="" NET_GW="" NET_APPLY_MODE="none"
NET_DNS=() SEARCH_DOMAINS=()
NEW_HOSTNAME="" FQDN="" HOST_IP=""
SSH_ALLOW_IPS=() F2B_IGNORE=()
STEP_NO=0
readonly STEP_TOTAL=11

# ------------------------------- Utilitas umum -------------------------------
c_info() { printf '\e[1;34m[INFO]\e[0m %s\n' "$*"; }
c_ok()   { printf '\e[1;32m[ OK ]\e[0m %s\n' "$*"; }
c_warn() { printf '\e[1;33m[WARN]\e[0m %s\n' "$*"; }
c_err()  { printf '\e[1;31m[FAIL]\e[0m %s\n' "$*" >&2; }
die()    { c_err "$*"; exit 1; }
step()   { STEP_NO=$((STEP_NO + 1)); printf '\n\e[1;36m==== [%d/%d] %s ====\e[0m\n' "$STEP_NO" "$STEP_TOTAL" "$*"; }

join_by() { local d=$1 out=""; shift; local x; for x in "$@"; do out+="${out:+$d}$x"; done; printf '%s' "$out"; }
split_list() { tr ',; ' '\n\n\n' <<<"$1" | sed '/^$/d'; }

apt_install() {
  apt-get install -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold "$@"
}

# Backup file sebelum diubah (mencatat juga jika file sebelumnya tidak ada)
backup_file() {
  local f=$1 dst="$BACKUP_DIR$1"
  [[ -e "$dst" || -e "$dst.absent" ]] && return 0
  mkdir -p "$(dirname "$dst")"
  if [[ -e "$f" ]]; then cp -a "$f" "$dst"; else touch "$dst.absent"; fi
}
restore_file() {
  local f=$1 src="$BACKUP_DIR$1"
  if [[ -e "$src" ]]; then cp -a "$src" "$f"
  elif [[ -e "$src.absent" ]]; then rm -f "$f"; fi
}

# ------------------------- Validasi (python3 ipaddress) ----------------------
pycheck() {
  python3 - "$@" 2>/dev/null <<'PY'
import ipaddress as ia, sys
m, *a = sys.argv[1:]
try:
    if m == "ip4":
        ia.IPv4Address(a[0])
    elif m == "ip":
        ia.ip_address(a[0])
    elif m == "cidr4":
        assert "/" in a[0]
        i = ia.IPv4Interface(a[0])
        assert 8 <= i.network.prefixlen <= 32 and i.ip != i.network.network_address
    elif m == "net":
        ia.ip_network(a[0], strict=False)
    elif m == "insub":
        assert ia.ip_address(a[1]) in ia.IPv4Interface(a[0]).network
    elif m == "covers":
        assert any(ia.ip_address(a[0]) in ia.ip_network(n, strict=False) for n in a[1:])
    else:
        sys.exit(2)
except Exception:
    sys.exit(1)
PY
}
valid_domain()   { [[ $1 =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$ ]]; }
valid_hostname() { [[ $1 =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]; }

# ------------------------------ Dialog whiptail ------------------------------
# Semua dialog langsung ke /dev/tty, sehingga tetap tampil walau output di-log.
wt() {
  whiptail --backtitle "Server Setup v${SCRIPT_VERSION} - PT Roemah Toedjoeh Indonesia" "$@" \
    3>&1 1>/dev/tty 2>&3 </dev/tty
}
cancel_exit() { clear >/dev/tty 2>&1 || true; die "Dibatalkan oleh pengguna. Belum ada perubahan pada sistem."; }
msg()   { wt --title "$1" --msgbox "$2" "${3:-14}" 76 || true; }
yesno() { local t=$1 m=$2; shift 2; wt --title "$t" "$@" --yesno "$m" 15 76; }
input() {
  local out
  out=$(wt --title "$1" --inputbox "$2" 14 76 "${3:-}") || cancel_exit
  printf '%s' "$out"
}
ask_password() {
  local p1 p2
  while true; do
    p1=$(wt --title "Password user $1" --passwordbox "Masukkan password untuk user '$1' (minimal 8 karakter):" 10 76) || cancel_exit
    p2=$(wt --title "Password user $1" --passwordbox "Ulangi password untuk user '$1':" 10 76) || cancel_exit
    if (( ${#p1} < 8 )); then
      msg "Password terlalu pendek" "Password minimal 8 karakter. Silakan ulangi." 8
    elif [[ "$p1" != "$p2" ]]; then
      msg "Password tidak sama" "Kedua password tidak sama. Silakan ulangi." 8
    else
      REPLY_PW=$p1; return 0
    fi
  done
}

# ------------------------------ Info jaringan --------------------------------
list_ifaces() {
  local p n
  for p in /sys/class/net/*; do
    n=${p##*/}
    [[ -e "$p/device" ]] || continue   # hanya NIC fisik/virtio (bukan bridge, docker, veth)
    printf '%s\n' "$n"
  done
}
iface_addr() { ip -4 -o addr show dev "$1" scope global 2>/dev/null | awk '{print $4; exit}'; }
iface_gw()   { ip -4 route show default dev "$1" 2>/dev/null | awk '{print $3; exit}'; }
iface_dns()  { resolvectl dns "$1" 2>/dev/null | sed 's/^[^:]*: *//' | tr ' ' '\n' | grep -E '^[0-9a-fA-F.:]+$' | paste -sd, - | sed 's/,/, /g' || true; }
primary_ip() { ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}'; }

# Cari SSH_CONNECTION dari proses induk (sudo membersihkan environment)
find_ssh_connection() {
  local pid=$$ v
  while [[ -n "$pid" && "$pid" -gt 1 ]]; do
    v=$(tr '\0' '\n' <"/proc/$pid/environ" 2>/dev/null | sed -n 's/^SSH_CONNECTION=//p' | head -n1 || true)
    if [[ -n "$v" ]]; then printf '%s' "$v"; return 0; fi
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ' || true)
  done
  return 0
}

# =============================================================================
#  FASE 0 — Pemeriksaan awal
# =============================================================================
preflight() {
  if [[ $EUID -ne 0 ]]; then echo "Jalankan sebagai root: sudo bash $0"; exit 1; fi
  ( : </dev/tty ) 2>/dev/null || die "Script ini interaktif dan membutuhkan terminal (TTY)."
  # shellcheck disable=SC1091
  . /etc/os-release
  [[ "${ID:-}" == "ubuntu" ]] || die "Script ini hanya untuk Ubuntu (terdeteksi: ${PRETTY_NAME:-tidak diketahui})."
  dpkg --compare-versions "${VERSION_ID:-0}" ge 22.04 || die "Butuh Ubuntu 22.04 atau lebih baru (terdeteksi: $PRETTY_NAME)."
  OS_CODENAME=$VERSION_CODENAME
  OS_PRETTY=$PRETTY_NAME

  local need=()
  command -v whiptail >/dev/null || need+=(whiptail)
  command -v python3  >/dev/null || need+=(python3-minimal)
  if (( ${#need[@]} )); then
    echo "Memasang paket yang dibutuhkan script: ${need[*]} ..."
    apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${need[@]}"
  fi
}

detect_session() {
  local conn
  conn=$(find_ssh_connection)
  if [[ -n "$conn" ]]; then
    read -r CLIENT_IP _ SERVER_IP SERVER_PORT <<<"$conn"
  else
    CLIENT_IP=$(who -m 2>/dev/null | sed -n 's/.*(\([^)]*\)).*/\1/p' | head -n1 || true)
  fi
  CLIENT_IP=${CLIENT_IP%%\%*}
  if [[ -n "$CLIENT_IP" ]] && pycheck ip "$CLIENT_IP"; then
    VIA_SSH=1
    # Port 22 sementara hanya perlu jika sesi saat ini BELUM lewat port baru
    [[ "$SERVER_PORT" == "$SSH_PORT" ]] || TEMP_PORT22=1
  else
    CLIENT_IP=""
  fi
  [[ -n "$SERVER_IP" ]] || SERVER_IP=$(primary_ip)
}

# =============================================================================
#  FASE 1 — Kumpulkan semua input (belum ada perubahan sistem)
# =============================================================================
collect_inputs() {
  local mode="Console (lokal)"
  [[ $VIA_SSH -eq 1 ]] && mode="SSH dari $CLIENT_IP"

  msg "Selamat datang" "Script ini akan mengatur server:

  1. Repository mirror Indonesia + update paket
  2. Timezone $TIMEZONE
  3. User monday (console) & friday (SSH key), keduanya auto-root
  4. Hostname, search domain, /etc/hosts
  5. Hardening SSH: port $SSH_PORT, key-only, root login ditolak
  6. Firewall UFW + Fail2ban
  7. Docker + Uptime Kuma (port $KUMA_PORT)
  8. IP statis via netplan (dijalankan paling akhir)

Sistem : $OS_PRETTY
Mode   : $mode

Semua pertanyaan diajukan sekarang. Perubahan baru dijalankan
setelah Anda menyetujui ringkasan." 24

  # --- User ---
  if id monday &>/dev/null; then MONDAY_EXISTS=1; else ask_password monday; MONDAY_PW=$REPLY_PW; fi
  if id friday &>/dev/null; then FRIDAY_EXISTS=1; else ask_password friday; FRIDAY_PW=$REPLY_PW; fi
  REPLY_PW=""

  # --- Mirror ---
  local arch; arch=$(dpkg --print-architecture)
  if [[ "$arch" == "amd64" || "$arch" == "i386" ]]; then
    MIRROR_KEY=$(wt --title "Repository Indonesia" --menu "Pilih mirror repository Ubuntu:" 14 76 2 \
      kartolo "${MIRROR_NAME[kartolo]} - disarankan untuk Jawa Timur" \
      ui      "${MIRROR_NAME[ui]}") || cancel_exit
  else
    msg "Repository" "Arsitektur $arch memakai ports.ubuntu.com yang tidak tersedia di mirror lokal. Repository tidak diubah." 9
  fi
  if yesno "Update sistem" "Jalankan apt upgrade (memperbarui semua paket) setelah repository diganti?

Disarankan untuk server baru."; then DO_UPGRADE=1; fi

  # --- Jaringan ---
  local raw x ok
  if yesno "Konfigurasi jaringan" "Atur IP statis dengan netplan?

Pilih No jika jaringan sudah benar (misalnya saat menjalankan ulang script)."; then
    NET_CONFIGURE=1
    local ifs=() items=() n
    mapfile -t ifs < <(list_ifaces)
    (( ${#ifs[@]} )) || die "Tidak ada interface jaringan yang terdeteksi."
    for n in "${ifs[@]}"; do x=$(iface_addr "$n"); items+=("$n" "${x:-belum ada IP}"); done
    NET_IF=$(wt --title "Interface jaringan" --menu "Pilih interface yang akan diberi IP statis:" 16 76 6 "${items[@]}") || cancel_exit

    while true; do
      NET_ADDR=$(input "IP Address" "IP Address + prefix (CIDR) untuk $NET_IF.
Contoh: 192.168.10.20/24" "$(iface_addr "$NET_IF")")
      pycheck cidr4 "$NET_ADDR" && break
      msg "Format salah" "Format tidak valid. Gunakan IP/prefix, contoh: 192.168.10.20/24" 8
    done

    while true; do
      NET_GW=$(input "Gateway" "IP Gateway untuk $NET_IF.
Contoh: 192.168.10.1" "$(iface_gw "$NET_IF")")
      if ! pycheck ip4 "$NET_GW"; then msg "Format salah" "IP gateway tidak valid." 8; continue; fi
      if [[ "$NET_GW" == "${NET_ADDR%/*}" ]]; then msg "Gateway salah" "Gateway tidak boleh sama dengan IP server." 8; continue; fi
      if pycheck insub "$NET_ADDR" "$NET_GW" || yesno "Peringatan" "Gateway $NET_GW tidak berada dalam subnet $NET_ADDR.
Tetap gunakan?" --defaultno; then break; fi
    done

    while true; do
      x=$(iface_dns "$NET_IF")
      raw=$(input "DNS Server" "DNS server, pisahkan dengan koma.
Contoh: 192.168.10.1, 1.1.1.1, 8.8.8.8" "${x:-1.1.1.1, 8.8.8.8}")
      mapfile -t NET_DNS < <(split_list "$raw")
      ok=1; (( ${#NET_DNS[@]} )) || ok=0
      for x in "${NET_DNS[@]}"; do pycheck ip "$x" || ok=0; done
      [[ $ok -eq 1 ]] && break
      msg "Format salah" "Masukkan minimal satu IP DNS yang valid." 8
    done
  fi

  # --- Search domain ---
  while true; do
    x=$(awk '/^search /{ $1=""; sub(/^ /,""); print; exit }' /etc/resolv.conf 2>/dev/null | tr ' ' ',' || true)
    raw=$(input "Search domain" "Search domain (dipakai untuk netplan dan FQDN di /etc/hosts).
Bisa lebih dari satu, pisahkan dengan koma. Domain pertama dipakai untuk FQDN.
Contoh: roemah7.local" "${x:-}")
    mapfile -t SEARCH_DOMAINS < <(split_list "${raw,,}")
    ok=1; (( ${#SEARCH_DOMAINS[@]} )) || ok=0
    for x in "${SEARCH_DOMAINS[@]}"; do valid_domain "$x" || ok=0; done
    [[ $ok -eq 1 ]] && break
    msg "Format salah" "Search domain tidak valid. Contoh: roemah7.local" 8
  done

  # --- Hostname ---
  while true; do
    NEW_HOSTNAME=$(input "Hostname" "Hostname server (huruf kecil, angka, tanda minus).
FQDN otomatis menjadi: <hostname>.${SEARCH_DOMAINS[0]}" "$(hostname -s)")
    NEW_HOSTNAME=${NEW_HOSTNAME,,}
    valid_hostname "$NEW_HOSTNAME" && break
    msg "Format salah" "Hostname tidak valid. Contoh: srv-monitor01" 8
  done
  FQDN="$NEW_HOSTNAME.${SEARCH_DOMAINS[0]}"
  if [[ $NET_CONFIGURE -eq 1 ]]; then HOST_IP=${NET_ADDR%/*}; else HOST_IP=$(primary_ip); fi
  [[ -n "$HOST_IP" ]] || HOST_IP="127.0.1.1"

  # --- Pembatasan IP SSH ---
  if yesno "Pembatasan akses SSH" "Batasi akses SSH (port $SSH_PORT) hanya dari IP/subnet tertentu?

Yes : hanya IP/subnet yang Anda masukkan yang bisa SSH
No  : SSH terbuka dari semua IP (tetap terlindungi key-only + fail2ban)"; then
    while true; do
      raw=$(input "IP yang diizinkan SSH" "IP atau subnet yang boleh mengakses SSH, pisahkan dengan koma.
Contoh: 192.168.10.0/24, 10.8.0.0/24, 203.0.113.5" "$CLIENT_IP")
      mapfile -t SSH_ALLOW_IPS < <(split_list "$raw")
      ok=1; (( ${#SSH_ALLOW_IPS[@]} )) || ok=0
      for x in "${SSH_ALLOW_IPS[@]}"; do pycheck net "$x" || ok=0; done
      if [[ $ok -eq 0 ]]; then msg "Format salah" "Masukkan minimal satu IP/subnet yang valid." 8; continue; fi
      if [[ $VIA_SSH -eq 1 ]] && ! pycheck covers "$CLIENT_IP" "${SSH_ALLOW_IPS[@]}"; then
        if yesno "Risiko terkunci" "IP Anda saat ini ($CLIENT_IP) TIDAK termasuk dalam daftar.
Anda bisa kehilangan akses SSH.

Tambahkan $CLIENT_IP ke daftar secara otomatis?"; then SSH_ALLOW_IPS+=("$CLIENT_IP"); fi
      fi
      break
    done
  fi

  # --- Fail2ban ignoreip ---
  while true; do
    raw=$(input "Fail2ban - ignore IP" "IP/subnet yang TIDAK akan pernah di-ban oleh fail2ban, pisahkan dengan koma.
Kosongkan jika tidak ada. (127.0.0.1 dan ::1 otomatis ditambahkan)
Contoh: 192.168.10.5, 10.8.0.0/24" "$CLIENT_IP")
    mapfile -t F2B_IGNORE < <(split_list "$raw")
    ok=1
    for x in "${F2B_IGNORE[@]}"; do pycheck net "$x" || ok=0; done
    [[ $ok -eq 1 ]] && break
    msg "Format salah" "Ada IP/subnet yang tidak valid." 8
  done

  # --- Mode penerapan netplan ---
  if [[ $NET_CONFIGURE -eq 1 ]]; then
    if [[ $VIA_SSH -eq 1 && "${NET_ADDR%/*}" != "$SERVER_IP" ]]; then NET_APPLY_MODE="deferred"; else NET_APPLY_MODE="apply"; fi
  fi

  show_summary
}

show_summary() {
  local s u_m u_f mir net ssh_from ign notes=""
  [[ $MONDAY_EXISTS -eq 1 ]] && u_m="sudah ada - pembuatan & password dilewati" || u_m="dibuat baru (login console)"
  [[ $FRIDAY_EXISTS -eq 1 ]] && u_f="sudah ada - password dilewati, key & sudo diperbarui" || u_f="dibuat baru (login SSH key)"
  if [[ -n "$MIRROR_KEY" ]]; then mir="${MIRROR_NAME[$MIRROR_KEY]}"; else mir="tidak diubah"; fi
  if [[ $NET_CONFIGURE -eq 1 ]]; then
    net="$NET_IF -> $NET_ADDR, gw $NET_GW
                DNS $(join_by ', ' "${NET_DNS[@]}")"
  else net="tidak diubah"; fi
  if (( ${#SSH_ALLOW_IPS[@]} )); then ssh_from=$(join_by ', ' "${SSH_ALLOW_IPS[@]}"); else ssh_from="semua IP"; fi
  if (( ${#F2B_IGNORE[@]} )); then ign=$(join_by ', ' "${F2B_IGNORE[@]}"); else ign="-"; fi

  notes+="- Aturan UFW lama akan di-reset dan diganti aturan baru."$'\n'
  [[ $TEMP_PORT22 -eq 1 ]] && notes+="- Port 22 dibuka sementara sampai login port $SSH_PORT terverifikasi."$'\n'
  [[ "$NET_APPLY_MODE" == "deferred" ]] && notes+="- IP berubah: sesi SSH akan TERPUTUS di akhir. Login ulang ke ${NET_ADDR%/*}:$SSH_PORT."$'\n'
  notes+="- Backup konfigurasi lama: $BACKUP_DIR"

  s="Sistem        : $OS_PRETTY
User monday   : $u_m
User friday   : $u_f
Timezone      : $TIMEZONE
Mirror        : $mir
apt upgrade   : $([[ $DO_UPGRADE -eq 1 ]] && echo Ya || echo Tidak)
Jaringan      : $net
Search domain : $(join_by ', ' "${SEARCH_DOMAINS[@]}")
Hostname/FQDN : $NEW_HOSTNAME / $FQDN
/etc/hosts    : $HOST_IP $FQDN $NEW_HOSTNAME
SSH           : port $SSH_PORT, key-only, PermitRootLogin no
                AllowUsers $SSH_ALLOW_USERS
SSH dari      : $ssh_from
Fail2ban      : bantime $F2B_BANTIME, findtime $F2B_FINDTIME, maxretry $F2B_MAXRETRY
                ignore: $ign
Uptime Kuma   : Docker $KUMA_IMAGE, port $KUMA_PORT

Catatan:
$notes

Lanjutkan eksekusi?"
  wt --title "Ringkasan - periksa sebelum eksekusi" --scrolltext --yesno "$s" 30 80 || cancel_exit
  clear >/dev/tty 2>&1 || true
}

# =============================================================================
#  FASE 2 — Eksekusi
# =============================================================================
do_sources() {
  step "Repository mirror Indonesia"
  if [[ -z "$MIRROR_KEY" ]]; then c_info "Dilewati."; return 0; fi
  local url=${MIRROR_URL[$MIRROR_KEY]} c=$OS_CODENAME
  local deb822=/etc/apt/sources.list.d/ubuntu.sources
  backup_file /etc/apt/sources.list
  backup_file "$deb822"

  if [[ -f "$deb822" ]]; then
    cat >"$deb822" <<EOF
# Dikelola oleh setup-server.sh - mirror: ${MIRROR_NAME[$MIRROR_KEY]}
Types: deb
URIs: $url
Suites: $c $c-updates $c-backports
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

# Security update tetap dari server resmi agar patch keamanan tidak tertunda sinkronisasi mirror
Types: deb
URIs: http://security.ubuntu.com/ubuntu/
Suites: $c-security
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF
    echo "# Repository diatur di $deb822 (setup-server.sh)" >/etc/apt/sources.list
  else
    cat >/etc/apt/sources.list <<EOF
# Dikelola oleh setup-server.sh - mirror: ${MIRROR_NAME[$MIRROR_KEY]}
deb $url $c main restricted universe multiverse
deb $url $c-updates main restricted universe multiverse
deb $url $c-backports main restricted universe multiverse
# Security update tetap dari server resmi
deb http://security.ubuntu.com/ubuntu/ $c-security main restricted universe multiverse
EOF
  fi

  if apt-get update; then
    c_ok "Repository diganti ke ${MIRROR_NAME[$MIRROR_KEY]}."
  else
    c_warn "Mirror gagal diakses. Repository dikembalikan ke konfigurasi semula."
    restore_file /etc/apt/sources.list
    restore_file "$deb822"
    apt-get update || true
  fi
}

do_packages() {
  step "Update sistem & paket pendukung"
  if [[ $DO_UPGRADE -eq 1 ]]; then
    apt-get upgrade -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold
  fi
  apt_install ufw fail2ban ca-certificates curl gnupg openssh-server
  c_ok "Paket terpasang."
}

do_timezone() {
  step "Timezone"
  timedatectl set-timezone "$TIMEZONE"
  timedatectl set-ntp true || c_warn "NTP tidak dapat diaktifkan."
  c_ok "Timezone: $(timedatectl show -p Timezone --value), waktu sekarang $(date '+%F %T %Z')."
}

install_autoroot() {
  local u=$1 home grp prof
  home=$(getent passwd "$u" | cut -d: -f6)
  grp=$(id -gn "$u")
  prof="$home/.profile"
  [[ -f "$prof" ]] || cp /etc/skel/.profile "$prof" 2>/dev/null || touch "$prof"
  sed -i '/# >>> auto-root (setup-server) >>>/,/# <<< auto-root (setup-server) <<</d' "$prof"
  cat >>"$prof" <<'EOF'
# >>> auto-root (setup-server) >>>
# Login interaktif langsung menjadi root.
# Bypass (jika perlu masuk sebagai user biasa): ssh -t user@host 'NO_AUTO_ROOT=1 bash -l'
if [ "$(id -u)" -ne 0 ] && [ -t 0 ] && [ -t 1 ] && [ -z "${NO_AUTO_ROOT:-}" ] && sudo -n true 2>/dev/null; then
    exec sudo -i
fi
# <<< auto-root (setup-server) <<<
EOF
  chown "$u:$grp" "$prof"
}

ensure_user() {
  local u=$1 pw=$2 comment=$3
  if id "$u" &>/dev/null; then
    c_info "User $u sudah ada - pembuatan & password dilewati."
  else
    useradd -m -s /bin/bash -c "$comment" "$u"
    printf '%s:%s\n' "$u" "$pw" | chpasswd
    c_ok "User $u dibuat."
  fi
  usermod -aG sudo "$u"
  install_autoroot "$u"
}

do_users() {
  step "User monday & friday"
  ensure_user monday "$MONDAY_PW" "Admin console"
  ensure_user friday "$FRIDAY_PW" "Admin SSH"
  MONDAY_PW="" FRIDAY_PW=""

  local tmp f=/etc/sudoers.d/90-setup-server
  tmp=$(mktemp)
  {
    echo "# Dikelola oleh setup-server.sh"
    echo "monday ALL=(ALL:ALL) NOPASSWD: ALL"
    echo "friday ALL=(ALL:ALL) NOPASSWD: ALL"
  } >"$tmp"
  if visudo -cf "$tmp" >/dev/null; then
    install -m 0440 -o root -g root "$tmp" "$f"
    rm -f "$tmp"
  else
    rm -f "$tmp"; die "File sudoers tidak valid, dibatalkan."
  fi
  c_ok "sudo NOPASSWD + auto-root saat login aktif untuk monday & friday."

  local home grp k
  home=$(getent passwd friday | cut -d: -f6)
  grp=$(id -gn friday)
  install -d -m 700 -o friday -g "$grp" "$home/.ssh"
  touch "$home/.ssh/authorized_keys"
  for k in "${FRIDAY_SSH_KEYS[@]}"; do
    grep -qxF "$k" "$home/.ssh/authorized_keys" || echo "$k" >>"$home/.ssh/authorized_keys"
  done
  chmod 600 "$home/.ssh/authorized_keys"
  chown friday:"$grp" "$home/.ssh/authorized_keys"
  c_ok "SSH key (ed25519 + rsa) terpasang untuk friday."
}

do_hosts() {
  step "Hostname, search domain & /etc/hosts"
  hostnamectl set-hostname "$NEW_HOSTNAME"
  backup_file /etc/hosts
  local line="$HOST_IP $FQDN $NEW_HOSTNAME  # setup-server"
  sed -i -E '/^127\.0\.1\.1[[:space:]]/d; /# setup-server$/d' /etc/hosts
  if grep -qE '^127\.0\.0\.1[[:space:]]' /etc/hosts; then
    sed -i -E "0,/^127\.0\.0\.1[[:space:]].*/s//&\n${line}/" /etc/hosts
  else
    echo "$line" >>/etc/hosts
  fi

  # Cegah cloud-init menimpa hostname, /etc/hosts, dan konfigurasi jaringan
  if [[ -d /etc/cloud/cloud.cfg.d ]]; then
    {
      echo "# Dikelola oleh setup-server.sh"
      echo "preserve_hostname: true"
      echo "manage_etc_hosts: false"
      if [[ $NET_CONFIGURE -eq 1 ]]; then echo "network: {config: disabled}"; fi
    } >/etc/cloud/cloud.cfg.d/99-setup-server.cfg
  fi

  # Jika netplan tidak diubah, search domain dipasang lewat systemd-resolved
  if [[ $NET_CONFIGURE -eq 0 ]]; then
    install -d /etc/systemd/resolved.conf.d
    printf '[Resolve]\nDomains=%s\n' "${SEARCH_DOMAINS[*]}" >/etc/systemd/resolved.conf.d/90-setup-server.conf
    systemctl restart systemd-resolved 2>/dev/null || true
  fi
  c_ok "Hostname $NEW_HOSTNAME, FQDN $FQDN ($(hostname -f 2>/dev/null || echo '-'))."
}

write_sshd_conf() {
  local with22=$1
  {
    echo "# Dikelola oleh setup-server.sh - $(date '+%F %T')"
    echo "Port $SSH_PORT"
    if [[ $with22 -eq 1 ]]; then echo "Port 22"; fi
    cat <<EOF
PermitRootLogin no
AllowUsers $SSH_ALLOW_USERS
MaxAuthTries 3
LoginGraceTime 30
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
PubkeyAuthentication yes
X11Forwarding no
EOF
  } >"$SSHD_CONF"
  chmod 644 "$SSHD_CONF"
}

restart_ssh() {
  mkdir -p /run/sshd
  sshd -t || return 1
  # Ubuntu 22.10+ memakai socket activation; matikan agar port dibaca dari sshd_config
  if systemctl is-enabled --quiet ssh.socket 2>/dev/null || systemctl is-active --quiet ssh.socket 2>/dev/null; then
    c_info "Menonaktifkan ssh.socket (socket activation) agar port kustom berlaku."
    systemctl disable --now ssh.socket
    rm -f /etc/systemd/system/ssh.service.d/00-socket.conf /etc/systemd/system/ssh.socket.d/addresses.conf
    systemctl daemon-reload
    systemctl enable ssh.service
  fi
  systemctl restart ssh.service
  sleep 2
  ss -Htln "sport = :$SSH_PORT" | grep -q .
}

do_ssh() {
  step "Hardening SSH"
  install -d -m 755 /etc/ssh/sshd_config.d
  backup_file /etc/ssh/sshd_config
  backup_file "$SSHD_CONF"
  if ! grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' /etc/ssh/sshd_config; then
    sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config
  fi
  # Port & AllowUsers bersifat kumulatif, jadi definisi di file lain dinonaktifkan
  local f
  for f in /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf; do
    [[ -f "$f" && "$f" != "$SSHD_CONF" ]] || continue
    if grep -qiE '^[[:space:]]*(Port|AllowUsers)[[:space:]]' "$f"; then
      backup_file "$f"
      sed -i -E 's/^[[:space:]]*(Port|AllowUsers)[[:space:]]/# [setup-server] &/I' "$f"
    fi
  done

  write_sshd_conf "$TEMP_PORT22"
  if restart_ssh; then
    c_ok "SSH aktif di port $SSH_PORT$([[ $TEMP_PORT22 -eq 1 ]] && echo ' (+ port 22 sementara)')."
  else
    c_err "Konfigurasi SSH gagal. Mengembalikan konfigurasi lama..."
    restore_file "$SSHD_CONF"
    restore_file /etc/ssh/sshd_config
    for f in "$BACKUP_DIR"/etc/ssh/sshd_config.d/*.conf; do [[ -f "$f" ]] && cp -a "$f" "/etc/ssh/sshd_config.d/${f##*/}"; done
    systemctl restart ssh.service || true
    die "Hardening SSH dibatalkan. Periksa: sshd -t"
  fi
}

do_ufw() {
  step "Firewall UFW"
  ufw --force reset >/dev/null
  ufw default deny incoming
  ufw default allow outgoing
  local ip
  if (( ${#SSH_ALLOW_IPS[@]} )); then
    for ip in "${SSH_ALLOW_IPS[@]}"; do
      ufw allow from "$ip" to any port "$SSH_PORT" proto tcp comment 'SSH'
    done
  else
    ufw allow "$SSH_PORT/tcp" comment 'SSH'
  fi
  if [[ $TEMP_PORT22 -eq 1 ]]; then
    if [[ -n "$CLIENT_IP" ]]; then
      ufw allow from "$CLIENT_IP" to any port 22 proto tcp comment 'SSH-sementara'
    else
      ufw allow 22/tcp comment 'SSH-sementara'
    fi
  fi
  ufw allow "$KUMA_PORT/tcp" comment 'Uptime Kuma'
  ufw --force enable
  ufw status verbose
  c_ok "UFW aktif."
}

do_fail2ban() {
  step "Fail2ban"
  local backend ports="$SSH_PORT"
  if [[ $TEMP_PORT22 -eq 1 ]]; then ports="$SSH_PORT,22"; fi
  if [[ -f /var/log/auth.log ]]; then
    backend="auto"
  else
    backend="systemd"
    apt_install python3-systemd
  fi
  backup_file /etc/fail2ban/jail.local
  cat >/etc/fail2ban/jail.local <<EOF
# Dikelola oleh setup-server.sh
[DEFAULT]
bantime   = $F2B_BANTIME
findtime  = $F2B_FINDTIME
maxretry  = $F2B_MAXRETRY
ignoreip  = 127.0.0.1/8 ::1 ${F2B_IGNORE[*]}
banaction = ufw
banaction_allports = ufw

[sshd]
enabled = true
port    = $ports
backend = $backend
EOF
  fail2ban-client -t >/dev/null || die "Konfigurasi fail2ban tidak valid (cek: fail2ban-client -t)."
  systemctl enable fail2ban >/dev/null 2>&1
  systemctl restart fail2ban
  sleep 3
  fail2ban-client status sshd || c_warn "Jail sshd belum aktif, cek: systemctl status fail2ban"
  c_ok "Fail2ban aktif (bantime $F2B_BANTIME, findtime $F2B_FINDTIME, maxretry $F2B_MAXRETRY)."
}

install_docker_ubuntu_pkg() {
  c_warn "Repository resmi Docker tidak tersedia, memakai paket Docker dari Ubuntu."
  rm -f /etc/apt/sources.list.d/docker.list
  apt-get update
  apt_install docker.io
  apt_install docker-compose-v2 || apt_install docker-compose-plugin
}

do_docker_kuma() {
  step "Docker & Uptime Kuma"
  if ! command -v docker >/dev/null; then
    install -m 0755 -d /etc/apt/keyrings
    if curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc; then
      chmod a+r /etc/apt/keyrings/docker.asc
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $OS_CODENAME stable" \
        >/etc/apt/sources.list.d/docker.list
      if apt-get update && apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; then
        c_ok "Docker CE terpasang dari repository resmi."
      else
        install_docker_ubuntu_pkg
      fi
    else
      install_docker_ubuntu_pkg
    fi
  else
    c_info "Docker sudah terpasang: $(docker --version)"
  fi
  docker compose version >/dev/null 2>&1 || apt_install docker-compose-plugin || apt_install docker-compose-v2

  # Rotasi log container agar disk tidak penuh
  if [[ ! -f /etc/docker/daemon.json ]]; then
    install -d /etc/docker
    cat >/etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
EOF
  fi
  systemctl enable docker >/dev/null 2>&1
  systemctl restart docker

  install -d -m 755 "$KUMA_DIR"
  cat >"$KUMA_DIR/compose.yaml" <<EOF
# Dikelola oleh setup-server.sh
# Update: cd $KUMA_DIR && docker compose pull && docker compose up -d
services:
  uptime-kuma:
    image: $KUMA_IMAGE
    container_name: uptime-kuma
    restart: unless-stopped
    ports:
      - "$KUMA_PORT:3001"
    volumes:
      - ./data:/app/data
    environment:
      - TZ=$TIMEZONE
EOF
  docker compose -f "$KUMA_DIR/compose.yaml" up -d

  local _
  for _ in $(seq 1 40); do
    if curl -fsS -o /dev/null "http://127.0.0.1:$KUMA_PORT"; then
      c_ok "Uptime Kuma berjalan di port $KUMA_PORT."; return 0
    fi
    sleep 3
  done
  c_warn "Uptime Kuma belum merespons. Cek: docker logs uptime-kuma"
}

remove_temp_ufw_rules() {
  local n
  while true; do
    n=$(ufw status numbered | awk -F'[][]' '/SSH-sementara/ {gsub(/ /, "", $2); print $2; exit}')
    [[ -n "$n" ]] || break
    ufw --force delete "$n" >/dev/null
  done
}

confirm_new_ssh_port() {
  step "Verifikasi login SSH port $SSH_PORT"
  if [[ $TEMP_PORT22 -eq 0 ]]; then c_info "Tidak diperlukan (mode console / sesi sudah di port $SSH_PORT)."; return 0; fi

  msg "Uji login SSH" "JANGAN tutup sesi ini.

Buka terminal BARU di komputer Anda, lalu jalankan:

    ssh -p $SSH_PORT friday@$SERVER_IP

Pastikan Anda bisa masuk dan otomatis menjadi root.
Setelah itu kembali ke jendela ini." 16

  if yesno "Hasil uji" "Apakah login SSH via port $SSH_PORT BERHASIL?"; then
    write_sshd_conf 0
    if restart_ssh; then
      remove_temp_ufw_rules
      sed -i -E "s/^port[[:space:]]*=.*/port    = $SSH_PORT/" /etc/fail2ban/jail.local
      systemctl restart fail2ban
      TEMP_PORT22=0
      c_ok "Port 22 ditutup. SSH hanya melalui port $SSH_PORT."
    else
      write_sshd_conf 1; restart_ssh || true
      c_warn "Gagal menutup port 22; konfigurasi dikembalikan (port 22 tetap terbuka sementara)."
    fi
  else
    c_warn "Port 22 TETAP terbuka sementara. Perbaiki masalah login, lalu jalankan ulang script ini via port $SSH_PORT."
  fi
}

rollback_netplan() {
  rm -f "$NETPLAN_FILE"
  cp -a "$BACKUP_DIR"/netplan/* /etc/netplan/ 2>/dev/null || true
  rm -f /etc/cloud/cloud.cfg.d/99-setup-server.cfg
  netplan apply || true
  c_warn "Konfigurasi netplan dikembalikan ke semula."
}

do_netplan() {
  step "IP statis (netplan)"
  if [[ $NET_CONFIGURE -eq 0 ]]; then c_info "Dilewati sesuai pilihan."; return 0; fi

  local y q_dns=() q_dom=() x
  install -d "$BACKUP_DIR/netplan"
  for y in /etc/netplan/*.yaml /etc/netplan/*.yml; do
    [[ -f "$y" ]] || continue
    # Pindahkan file lama yang mengatur interface yang sama (termasuk file buatan script ini)
    if [[ "$y" == "$NETPLAN_FILE" ]] || grep -qE "^[[:space:]]*${NET_IF}:" "$y"; then
      mv "$y" "$BACKUP_DIR/netplan/"
    fi
  done
  for x in "${NET_DNS[@]}"; do q_dns+=("\"$x\""); done
  for x in "${SEARCH_DOMAINS[@]}"; do q_dom+=("\"$x\""); done

  cat >"$NETPLAN_FILE" <<EOF
# Dikelola oleh setup-server.sh
network:
  version: 2
  renderer: networkd
  ethernets:
    $NET_IF:
      dhcp4: false
      dhcp6: false
      addresses:
        - $NET_ADDR
      routes:
        - to: default
          via: $NET_GW
      nameservers:
        addresses: [$(join_by ', ' "${q_dns[@]}")]
        search: [$(join_by ', ' "${q_dom[@]}")]
EOF
  chmod 600 "$NETPLAN_FILE"

  if ! netplan generate; then
    c_err "Konfigurasi netplan tidak valid."
    rollback_netplan
    return 0
  fi

  if [[ "$NET_APPLY_MODE" == "deferred" ]]; then
    print_summary
    msg "Koneksi akan terputus" "IP server berubah ke ${NET_ADDR%/*}.
Sesi SSH ini akan TERPUTUS sekitar 5 detik setelah Anda menekan OK.

Login kembali dengan:
    ssh -p $SSH_PORT friday@${NET_ADDR%/*}

Jika tidak bisa terhubung, masuk lewat console dan pulihkan:
    cp $BACKUP_DIR/netplan/* /etc/netplan/
    rm $NETPLAN_FILE && netplan apply" 18
    systemd-run --unit="setup-server-netplan-$(date +%s)" --on-active=5 /usr/sbin/netplan apply >/dev/null
    c_info "netplan apply dijadwalkan 5 detik lagi."
    exit 0
  fi

  netplan apply
  sleep 4
  if ping -c 2 -W 2 "$NET_GW" >/dev/null 2>&1; then
    c_ok "IP $NET_ADDR aktif, gateway $NET_GW merespons."
  else
    c_warn "Gateway $NET_GW tidak merespons ping."
    if yesno "Gateway tidak merespons" "Gateway $NET_GW tidak merespons ping (bisa jadi gateway memang memblokir ICMP).

Kembalikan konfigurasi jaringan sebelumnya?" --defaultno; then
      rollback_netplan
    fi
  fi
}

print_summary() {
  local ip=${HOST_IP}
  if [[ $NET_CONFIGURE -eq 1 ]]; then ip=${NET_ADDR%/*}; fi
  cat <<EOF

=====================================================================
  SELESAI - $(date '+%F %T %Z')
=====================================================================
  Hostname    : $NEW_HOSTNAME  ($FQDN)
  IP          : $ip
  SSH         : ssh -p $SSH_PORT friday@$ip
  Port 22     : $([[ $TEMP_PORT22 -eq 1 ]] && echo 'MASIH TERBUKA (sementara)' || echo 'tertutup')
  Uptime Kuma : http://$ip:$KUMA_PORT
                >> Segera buka dan buat akun admin. Siapa pun yang membuka
                   halaman ini pertama kali bisa membuat akun admin.
  Fail2ban    : fail2ban-client status sshd
  Firewall    : ufw status numbered
  Backup      : $BACKUP_DIR
  Log         : $LOG_FILE
=====================================================================
EOF
}

main() {
  preflight
  detect_session
  collect_inputs

  mkdir -p "$BACKUP_DIR"
  chmod 700 /root/server-setup-backup
  touch "$LOG_FILE"; chmod 600 "$LOG_FILE"
  exec > >(tee -a "$LOG_FILE") 2>&1
  trap 'c_err "Gagal pada baris $LINENO: $BASH_COMMAND (lihat $LOG_FILE)"' ERR
  export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a

  echo "=== setup-server.sh v$SCRIPT_VERSION dimulai $(date '+%F %T') ==="
  do_sources
  do_packages
  do_timezone
  do_users
  do_hosts
  do_ssh
  do_ufw
  do_fail2ban
  do_docker_kuma
  confirm_new_ssh_port
  do_netplan
  print_summary
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
