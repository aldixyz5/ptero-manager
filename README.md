# Pterodactyl Manager (`ptero.sh`) — Catatan Update & Saran Perbaikan

Script bash untuk install & maintain **Pterodactyl Panel + Wings** di Ubuntu/Debian.
Mendukung 2 mode deploy: `tunnel` (server lokal tanpa IP publik via Cloudflare Tunnel) dan `public` (server dengan IP publik via Let's Encrypt). Antarmuka berbahasa Indonesia.

---

## 1. Yang sudah diperbaiki / ditambahkan di revisi ini

### A. Bug fix kritis
| # | Lokasi | Masalah | Perbaikan |
|---|---|---|---|
| 1 | nginx config | Heredoc tidak di-quote → variabel nginx (`$uri`, `$server_name`, dst.) di-strip oleh bash | Heredoc di-quote (`<<'NGINX'`), variabel di-substitusi via `sed` placeholder |
| 2 | nginx config | Domain `panel.ryucloud.web.id` di-hardcode | Pakai `$PANEL_DOMAIN` dari config |
| 3 | DB setup | Default `DB_PASS="Ryu_zetsu"` | Default kosong, wajib input user |
| 4 | systemd unit | `StartLimitInterval` di section `[Service]` (salah) | Dipindah ke `[Unit]` sesuai systemd modern |
| 5 | nginx php-fpm | `fastcgi_param PHP_VALUE` mengandung literal `\n` | Dipisah jadi 2 baris `fastcgi_param` |
| 6 | docker check | Regex `^/[a-f0-9-]\{36\}$` salah escape | Regex bash diperbaiki |
| 7 | DB password change | `pteroq` tidak di-restart setelah ganti password | `systemctl restart pteroq` ditambahkan |
| 8 | path | `cd $PANEL_DIR` tanpa quoting | Diquote `cd "$PANEL_DIR"` |

### B. Fitur baru
- **Mode deploy `tunnel` vs `public`** — disimpan di `/root/.ptero-manager.conf`, dipilih lewat menu **47**.
- **Generator Nginx mode-aware** (`write_nginx_config`) sebagai single source of truth.
- **HTTPS di kedua mode**:
  - `public`: Let's Encrypt + auto-renew via `certbot.timer` (menu **48**), HSTS-ready, security headers.
  - `tunnel`: self-signed cert otomatis (menu auto saat install) → cloudflared diarahkan ke `https://localhost:443` dengan `noTLSVerify` → bisa pakai Cloudflare SSL **Full / Full (Strict)** end-to-end.
- **Cloudflare Origin Certificate** (menu **51**) — tempel cert+key dari dashboard CF supaya origin di-trust penuh oleh CF.
- **Fail2ban** (menu **49**, status di **50**) — jail `sshd`, `nginx-http-auth`, `nginx-botsearch`.
- **UFW mode-aware** (menu **30**):
  - `public` → buka 80/443 publik.
  - `tunnel` → allow loopback 80/443 + **deny** dari publik.
- **TRUSTED_PROXIES otomatis** ikut mode (`*` untuk tunnel, `127.0.0.1` untuk public) + auto `php artisan config:clear`.
- **Help screen** (menu 43) ditulis ulang dengan dua alur instalasi terpisah.

---

## 2. Yang masih perlu diperbaiki (bug & hardening)

### Status (per rev. ini)
- [x] **#1 Password leak di `ps`** → semua mysql/mysqldump/mysqlcheck pakai helper `mysql_secure` / `mysqldump_secure` / `mysqlcheck_secure` lewat MySQL option file `mktemp` mode 600.
- [x] **#2 Race condition lock file** → `acquire_lock` sekarang pakai `flock -n` di fd 9 (atomik), fallback ke metode lama hanya kalau `flock` tidak tersedia.
- [x] **#3 Permission window `.ptero-manager.conf`** → `save_config` set `umask 077` sebelum tulis file.
- [x] **#4 Password DB plaintext di `ptero-auto-backup.sh`** → kredensial dipindah ke `/etc/ptero-manager/db.cnf` (mode 600). Wrapper script tinggal `--cnf <path>`.
- [x] **#7 `CUSTOM_BANNER` rawan injection** → diganti `printf '%s'` (tidak lagi `echo -e`).
- [x] **#6 Validasi input password DB** → helper `validate_db_password` (whitelist karakter, panjang 8–64, tolak quote/backslash/dollar/whitespace) dipakai di `setup_database`, `change_db_password`, `schedule_auto_backup`. `setup_database` retry 3x sebelum batal.
- [x] **#12 `nginx -t` guard sebelum reload/restart** → semua titik `systemctl restart nginx ...` (install_all, install_panel_only, deep_maintenance, deep_uninstall, menu Provision) sekarang gate dengan `nginx -t`. Jika config invalid, nginx tidak di-restart, service lain tetap jalan, user dapat error jelas. Helper `safe_reload_nginx` tersedia untuk dipakai di tempat baru.

### Prioritas tinggi (sisa)
1. **Password leak di process list** (sekitar L253, L1117, L1220) — ✅ selesai (lihat status di atas)
   `MYSQL_PWD="$DB_PASS" mysql ...` mengekspos password ke `ps auxe`.
   **Fix:** pakai *MySQL option file sementara*:
   ```bash
   tmp=$(mktemp); chmod 600 "$tmp"
   printf '[client]\nuser=%s\npassword=%s\n' "$DB_USER" "$DB_PASS" > "$tmp"
   mysql --defaults-extra-file="$tmp" -e "..."
   rm -f "$tmp"
   ```
2. **Race condition pada lock file** (`acquire_lock`, L142–154)
   Pengecekan `[ -e ]` lalu `echo $$ >` tidak atomik.
   **Fix:** pakai `flock`:
   ```bash
   exec 9>"$LOCK_FILE"
   flock -n 9 || { echo "Sudah ada instance lain"; exit 1; }
   ```
3. **Permission window pada `.ptero-manager.conf`** (L53–72)
   File ditulis dulu baru `chmod 600` → ada celah kebaca user lain.
   **Fix:** `umask 077` di awal `save_config`, atau tulis ke `mktemp` (chmod 600) lalu `mv` atomik.
4. **Password DB di file cron `ptero-auto-backup.sh`** (L1220)
   Disimpan plaintext di script.
   **Fix:** taruh kredensial di `/root/.my.cnf` (mode 600), referensikan via `--defaults-file`.
5. **Restore tidak cek exit code** (L1130, L1135) — `cp`/`tar` bisa gagal silent.
   **Fix:** wrap dengan `if ! cp ...; then fail "..."; return 1; fi` + `set -o pipefail` lokal.
6. **Validasi input password DB** (L260, L604, L1100) — karakter `'`, `"`, `\`, `$` bisa memutus query/shell.
   **Fix:** whitelist regex, atau baca dengan `read -r -s` + escape via `printf '%q'`.

### Prioritas sedang
7. **`CUSTOM_BANNER` dieksekusi via `echo -e`** (L108–109) → escape sequence/subshell bisa muncul.
   **Fix:** `printf '%s\n' "$CUSTOM_BANNER"` (tanpa `-e`).
8. **Redis tanpa password & tanpa `bind 127.0.0.1`** (L665, L2014) — terbuka kalau firewall salah.
   **Fix:** set `requirepass` random + `bind 127.0.0.1 ::1`, sync ke `.env` panel (`REDIS_PASSWORD`).
9. **MariaDB tidak di-`mysql_secure_installation`** — root password kosong default.
   **Fix:** otomatisasi via `mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '...'; DELETE FROM mysql.user WHERE User=''; DROP DATABASE IF EXISTS test; FLUSH PRIVILEGES;"`.
10. **Backup tidak terenkripsi** (L986, L990) — `.tar.gz` polos berisi `.env` + DB.
    **Fix:** `tar ... | gpg --symmetric --cipher-algo AES256 -o file.tar.gz.gpg` (passphrase di `/root/.ptero-backup-key`, mode 600).
11. **Tidak ada IPv6** di `listen` nginx (L412, L420).
    **Fix:** tambah `listen [::]:80;` & `listen [::]:443 ssl http2;`.
12. **Tidak ada `nginx -t` sebelum `reload`** di beberapa tempat — nginx bisa down kalau config salah.
    **Fix:** `nginx -t && systemctl reload nginx || (echo "config invalid"; return 1)`.
13. **`set -e` tidak dipakai** — error di tengah fungsi sering dilewat. Tambah `set -Eeuo pipefail` di top + `trap 'fail "line $LINENO"' ERR`.

### Prioritas rendah
14. **Logrotate untuk `/var/log/ptero-manager.log`** belum ada → file bisa membengkak.
15. **`apt update` tidak di-cache** — lambat di tiap fungsi install. Pakai timestamp guard (skip kalau <1 jam).
16. **Versi panel/wings di-pin lewat `latest`** — kalau Pterodactyl rilis breaking change, bisa pecah. Sediakan opsi pin versi spesifik.
17. **Tidak ada `--dry-run`** untuk operasi destruktif (deep_uninstall, restore).

---

## 3. Fitur baru yang disarankan

### Operasional Pterodactyl
- **SMTP Setup Wizard** — input host/port/user/pass + STARTTLS/SSL, langsung tulis ke `.env` panel + `php artisan p:environment:mail`. Krusial untuk reset password & notifikasi.
- **Node & Location auto-create** via Panel API (Application key) sehingga user tidak perlu klik di web sebelum jalankan menu 10.
- **Multi-node Wings registry** — dukung beberapa node remote di satu manager (table `[nodes]` di config, command bisa target `--node=NAME`).
- **2FA enforcement** — toggle `require_2fa = true` untuk semua admin (lewat `php artisan tinker`).
- **PHP OPcache & JIT tuning** — set `opcache.memory_consumption=256`, `opcache.jit_buffer_size=128M`, `opcache.validate_timestamps=0` (production).

### Backup & DR
- **Backup encryption (GPG)** + key rotation reminder.
- **Integrity check terjadwal** (cron mingguan: hitung sha256 ulang vs manifest, kirim Telegram kalau berbeda).
- **Restore selektif** — pilih hanya DB, hanya `.env`, atau hanya storage.
- **Sinkron backup ke S3/B2/Wasabi/R2** lewat `rclone` (hook setelah backup sukses).
- **Off-site replication test** — sekali sebulan otomatis download backup terakhir & verifikasi.

### Monitoring & Alerting
- **Health check periodik** (cron 5 menit) → kalau service down kirim Telegram/Discord.
- **Resource alert** — CPU > X%, RAM > Y%, disk < Z GB selama N menit → notifikasi.
- **Per-server (game server) alert** — Wings event hook (server crash, OOM kill).
- **Update notifier** — cek release Pterodactyl/Wings dari GitHub API, kasih badge di header.

### Keamanan
- **Auto-update sistem terjadwal** dengan `unattended-upgrades` + reboot window.
- **SSH hardening wizard** — disable root login, force key-only, ubah port, langsung integrasi UFW.
- **Audit log viewer** — gabungan `auth.log`, `nginx access`, `wings`, `panel laravel.log` dengan filter tanggal/IP.
- **Cloudflare WAF rule installer** (mode tunnel) — push managed ruleset minimum.

### UX
- **Wizard mode** — saat pertama kali, jalankan langkah 47 → 1 → (8 atau 48) → 10 → 30 → 49 → 16 secara berurutan.
- **Self-update** dari GitHub raw URL dengan signature check (sha256 dari release).
- **`--non-interactive`** dengan flag CLI untuk semua menu (mendukung CI/IaC).
- **Dark/light banner toggle** + tampilkan info mode (tunnel/public) di header.
- **Localization** — pisahkan string ke file `lang/id.sh` & `lang/en.sh`, pilih via env `PTERO_LANG`.

### Integrasi
- **Cloudflare DNS API** — auto-create A-record, auto-update kalau IP publik berubah (untuk mode public dynamic IP).
- **Discord slash command bot** ringan (Wings restart, status, backup trigger) — opsional.
- **Prometheus exporter** untuk Wings metrics (`wings_*`) supaya bisa scraping dari Grafana.

---

## 4. Saran prioritas eksekusi (urutan rekomendasi)

1. **Hardening password handling** (item 1, 4) — cepat & menutup celah serius.
2. **Lock file atomik + permission window** (item 2, 3).
3. **Validasi input + nginx -t guard + set -Eeuo pipefail** (item 6, 12, 13).
4. **SMTP wizard + Backup encryption** (paling sering diminta user produksi).
5. **Monitoring health check periodik + Update notifier** (paling kelihatan ROI-nya).
6. Sisanya bertahap.

---

## 5. Cara menjalankan validasi cepat
```bash
bash ptero.sh --self-check
```
Output sukses:
```
Sintaks OK. Semua fitur V5.4 tersedia.
```

> Catatan: Replit hanya untuk edit & cek sintaks. Eksekusi sebenarnya wajib di VPS Ubuntu/Debian sebagai `root` (butuh systemd, apt, nginx, mariadb, redis, docker).
