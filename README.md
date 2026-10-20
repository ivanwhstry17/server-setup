# server-setup

Script provisioning & hardening Ubuntu Server 22.04+ — PT Roemah Toedjoeh Indonesia.

## Cara pakai

Jalankan di server Ubuntu (console atau SSH):

```bash
wget -qO setup-server.sh https://raw.githubusercontent.com/<USERNAME>/server-setup/main/setup-server.sh
sudo bash setup-server.sh
```

Jangan gunakan `wget ... | bash`, karena pop-up butuh input keyboard.

Versi terkunci (disarankan untuk produksi, isi file dijamin tidak berubah):

```bash
wget -qO setup-server.sh https://raw.githubusercontent.com/<USERNAME>/server-setup/<COMMIT_SHA>/setup-server.sh
sudo bash setup-server.sh
```

## Yang dikerjakan

| No | Langkah | Detail |
|----|---------|--------|
| 1 | Repository | Mirror Kartolo (Surabaya) atau Kambing UI; security update tetap dari server resmi |
| 2 | Paket | apt upgrade (opsional), ufw, fail2ban, curl |
| 3 | Timezone | Asia/Jakarta + NTP |
| 4 | User | `monday` (console) & `friday` (SSH key), sudo NOPASSWD, login langsung root |
| 5 | Hostname | Hostname, search domain, FQDN di `/etc/hosts` |
| 6 | SSH | Port 1722, PermitRootLogin no, AllowUsers monday friday, MaxAuthTries 3, LoginGraceTime 30, PasswordAuthentication no |
| 7 | UFW | Deny incoming; allow 1722/tcp (opsional dibatasi per IP) dan 3001/tcp |
| 8 | Fail2ban | bantime 1d, findtime 10m, maxretry 3, ignoreip dari input |
| 9 | Uptime Kuma | Docker Compose di `/opt/uptime-kuma`, port 3001 |
| 10 | Netplan | IP statis, gateway, DNS, search domain (dijalankan paling akhir) |

Password tidak disimpan di script maupun log; password diminta lewat pop-up saat user dibuat.

## Setelah script selesai

- Buka `http://IP-SERVER:3001` dan segera buat akun admin Uptime Kuma.
- Login SSH: `ssh -p 1722 friday@IP-SERVER`
- Log: `/var/log/server-setup.log`
- Backup konfigurasi lama: `/root/server-setup-backup/<tanggal>/`

## Perintah berguna

```bash
fail2ban-client status sshd             # lihat IP yang di-ban
fail2ban-client set sshd unbanip <IP>   # buka ban
ufw status numbered                     # aturan firewall
cd /opt/uptime-kuma && docker compose pull && docker compose up -d   # update Uptime Kuma
```

## Catatan keamanan

- Port yang dipublikasi Docker (3001) melewati aturan UFW. Port ini memang dibuka, tetapi jangan mempublikasikan port container lain tanpa pertimbangan.
- Jika login sebagai user biasa diperlukan (tanpa auto-root): `ssh -t -p 1722 friday@host 'NO_AUTO_ROOT=1 bash -l'`
