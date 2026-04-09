#!/bin/bash
# ═══════════════════════════════════════════════════════════════════
#  SCRIPT MAÎTRE — TP3 : VM srv-shopnow (IDS Snort)
#  BTS SIO SISR — Module Cybersécurité
#  Réservé à l'enseignant — Ne pas distribuer
# ═══════════════════════════════════════════════════════════════════
# Usage : sudo bash tp3_setup_vm.sh
# Réseau : Host-Only — srv-shopnow: 10.10.10.10 | Kali: 10.10.10.99
# ═══════════════════════════════════════════════════════════════════

set -e
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
info() { echo -e "${CYAN}[*]${NC} $1"; }

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║   BTS SIO SISR — TP3 : Setup VM srv-shopnow          ║"
echo "║   IDS Snort — Cible avec logs pré-générés            ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""

if [ "$EUID" -ne 0 ]; then echo "Erreur : sudo requis"; exit 1; fi

# ─────────────────────────────────────────────────────────────────
# INSTALLATION
# ─────────────────────────────────────────────────────────────────
info "Installation des paquets..."
apt update -qq
DEBIAN_FRONTEND=noninteractive apt install -y -qq \
  apache2 mariadb-server php php-mysql php-curl libapache2-mod-php \
  snort curl wget net-tools vim

# Hostname
hostnamectl set-hostname srv-shopnow
log "Hostname : srv-shopnow"

# ─────────────────────────────────────────────────────────────────
# BASE DE DONNÉES WORDPRESS SIMULÉE
# ─────────────────────────────────────────────────────────────────
info "Configuration MariaDB..."
systemctl start mariadb
mysql << 'SQLEOF'
CREATE DATABASE IF NOT EXISTS shopnow_wp CHARACTER SET utf8mb4;
CREATE USER IF NOT EXISTS 'wp_user'@'localhost' IDENTIFIED BY 'wp_pass_2024';
GRANT ALL ON shopnow_wp.* TO 'wp_user'@'localhost';

USE shopnow_wp;
CREATE TABLE IF NOT EXISTS products (
  id INT AUTO_INCREMENT PRIMARY KEY,
  name VARCHAR(200),
  category VARCHAR(100),
  price DECIMAL(10,2)
);
INSERT INTO products (name,category,price) VALUES
  ('Nike Air Max 2024','shoes',129.99),
  ('Adidas Stan Smith','shoes',89.99),
  ('Polo Ralph Lauren','clothing',75.00),
  ('iPhone 15 Case','accessories',29.99);
SQLEOF
log "Base de données shopnow_wp créée"

# ─────────────────────────────────────────────────────────────────
# APPLICATION WEB VULNÉRABLE
# ─────────────────────────────────────────────────────────────────
info "Déploiement de l'application web..."

# Page produits vulnérable SQLi
cat > /var/www/html/products.php << 'PHPEOF'
<?php
// SHOPNOW — Recherche produits (VOLONTAIREMENT VULNÉRABLE — usage pédagogique)
$conn = new mysqli("localhost","wp_user","wp_pass_2024","shopnow_wp");
$cat = $_GET["category"] ?? "shoes";
echo "<html><head><title>SHOPNOW Products</title></head><body>";
echo "<h1>Produits : $cat</h1>";
$result = $conn->query("SELECT * FROM products WHERE category='$cat'");
if ($result) {
    while($r = $result->fetch_assoc()) {
        echo "<p>" . $r['name'] . " — " . $r['price'] . "€</p>";
    }
} else {
    echo "Erreur: " . $conn->error;
}
echo "</body></html>";
?>
PHPEOF

# Page de login admin (cible bruteforce)
cat > /var/www/html/admin-login.php << 'PHPEOF'
<?php
$user = $_POST["user"] ?? "";
$pass = $_POST["pass"] ?? "";
if ($user === "admin" && $pass === "shopnow@2024") {
    echo json_encode(["status" => "success", "msg" => "Connexion réussie"]);
} else {
    http_response_code(401);
    echo json_encode(["status" => "error", "msg" => "Identifiants incorrects"]);
}
?>
PHPEOF

# Faux dossier wp-admin pour le contexte WordPress
mkdir -p /var/www/html/wp-admin
cat > /var/www/html/wp-admin/index.php << 'PHPEOF'
<?php
echo "<html><body><h1>WordPress Admin</h1><p>Interface d'administration SHOPNOW.FR</p></body></html>";
?>
PHPEOF

# Simuler WordPress login pour les règles Snort
cat > /var/www/html/wp-login.php << 'PHPEOF'
<?php
$user = $_POST["log"] ?? "";
$pass = $_POST["pwd"] ?? "";
if ($user === "admin" && $pass === "shopnow@2024") {
    echo "WordPress Admin — Connexion réussie";
} else {
    echo "Erreur d'authentification WordPress";
}
?>
PHPEOF

chown -R www-data:www-data /var/www/html
systemctl restart apache2
log "Application web déployée"

# ─────────────────────────────────────────────────────────────────
# CONFIGURATION SNORT — PRÊTE POUR LES ÉTUDIANTS
# ─────────────────────────────────────────────────────────────────
info "Configuration Snort..."

mkdir -p /etc/snort/rules /var/log/snort
touch /var/log/snort/alert

# Fichier de règles vide — les étudiants le rempliront
cat > /etc/snort/rules/local.rules << 'EOF'
# ═══════════════════════════════════════════════════════
# Règles Snort SHOPNOW.FR — TP3 BTS SIO SISR
# Complétez ce fichier avec vos règles personnalisées
# ═══════════════════════════════════════════════════════
# Exemple de syntaxe :
# alert tcp $EXTERNAL_NET any -> $HTTP_SERVERS $HTTP_PORTS \
#   (msg:"Description"; content:"pattern"; sid:1000001; rev:1;)
# ═══════════════════════════════════════════════════════

EOF

# Configuration snort.conf de base
IFACE=$(ip route | grep default | awk '{print $5}' | head -1)
cat >> /etc/snort/snort.conf << EOF

# ─── Configuration SHOPNOW ───────────────────────────
ipvar HOME_NET 10.10.10.0/24
ipvar EXTERNAL_NET !\$HOME_NET
ipvar HTTP_SERVERS \$HOME_NET
portvar HTTP_PORTS [80,443,8080]

var RULE_PATH /etc/snort/rules

# Output
output alert_fast: /var/log/snort/alert
output log_tcpdump: /var/log/snort/snort.log

# Règles
include \$RULE_PATH/local.rules
EOF

chmod 755 /var/log/snort
log "Snort configuré (interface: $IFACE)"

# ─────────────────────────────────────────────────────────────────
# GÉNÉRATION DES LOGS APACHE PRÉ-EXISTANTS
# ─────────────────────────────────────────────────────────────────
info "Génération des logs Apache réalistes (attaques passées)..."

LOG=/var/log/apache2/access.log
TODAY=$(date "+%d/%b/%Y")
YESTERDAY=$(date -d "-24hours" "+%d/%b/%Y")

ATK1="185.220.101.47"   # Attaquant SQLi (sqlmap)
ATK2="91.108.4.201"     # Attaquant bruteforce
ATK3="45.142.212.100"   # Scanner (nikto)
LEGIT="10.10.10.50"     # Trafic légitime

# Trafic légitime (fond de trafic crédible)
for i in $(seq 1 300); do
  TS="$YESTERDAY:$(printf "%02d:%02d:%02d" $((RANDOM%23)) $((RANDOM%59)) $((RANDOM%59)))"
  echo "$LEGIT - - [$TS +0000] \"GET /products.php?category=shoes HTTP/1.1\" 200 $(( RANDOM % 2000 + 500)) \"-\" \"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36\"" >> $LOG
  echo "$LEGIT - - [$TS +0000] \"GET / HTTP/1.1\" 200 4523 \"-\" \"Mozilla/5.0\"" >> $LOG
done

# Scan de répertoires avec nikto (avant-hier)
NIKTO_TARGETS=("/.env" "/.git/config" "/wp-config.php.bak" "/admin/" "/phpmyadmin/" "/.htpasswd" "/backup.zip" "/config.php" "/debug.php" "/.DS_Store" "/robots.txt" "/sitemap.xml")
for path in "${NIKTO_TARGETS[@]}"; do
  for j in 1 2 3; do
    TS="$YESTERDAY:02:$(printf "%02d:%02d" $((j*3)) $((RANDOM%59)))"
    CODE=$([ "$path" = "/robots.txt" ] && echo 200 || echo 404)
    echo "$ATK3 - - [$TS +0000] \"GET $path HTTP/1.1\" $CODE 196 \"-\" \"Nikto/2.1.6\"" >> $LOG
  done
done
log "30 requêtes Nikto injectées"

# SQLi avec sqlmap (hier soir)
SQLI_PAYLOADS=(
  "products.php?category=shoes%27+UNION+SELECT+1%2C2%2C3--"
  "products.php?category=1%27+OR+1%3D1--"
  "products.php?category=1%27+AND+SLEEP%285%29--"
  "products.php?category=1%27+UNION+SELECT+table_name%2CNULL+FROM+information_schema.tables--"
  "products.php?category=%27+UNION+SELECT+user%28%29%2Cpassword%2C3+FROM+mysql.user--"
  "products.php?category=1%27+ORDER+BY+10--"
  "products.php?category=1%27+AND+1%3D2+UNION+SELECT+1%2Cdatabase%28%29%2C3--"
)
for payload in "${SQLI_PAYLOADS[@]}"; do
  for j in $(seq 1 8); do
    TS="$YESTERDAY:21:$(printf "%02d:%02d" $j $((RANDOM%59)))"
    echo "$ATK1 - - [$TS +0000] \"GET /$payload HTTP/1.1\" 200 287 \"-\" \"sqlmap/1.7.9#stable (https://sqlmap.org)\"" >> $LOG
  done
done
log "56 requêtes SQLi (sqlmap) injectées"

# Bruteforce WordPress (cette nuit)
for i in $(seq 1 847); do
  H=2; M=$(( 34 + i/60 )); S=$(( i % 60 ))
  if [ $M -ge 60 ]; then H=3; M=$(( M-60 )); fi
  TS="$TODAY:$(printf "%02d:%02d:%02d" $H $M $S)"
  echo "$ATK2 - - [$TS +0000] \"POST /wp-login.php HTTP/1.1\" 200 24 \"/wp-login.php\" \"python-requests/2.28.2\"" >> $LOG
done
# Connexion réussie après bruteforce
echo "$ATK2 - - [$TODAY:04:15:03 +0000] \"POST /wp-login.php HTTP/1.1\" 302 0 \"/wp-login.php\" \"python-requests/2.28.2\"" >> $LOG
log "847 requêtes bruteforce WordPress injectées (1 réussie)"

# Path traversal
for lfi in "../../etc/passwd" "../../../etc/shadow" "../../proc/self/environ"; do
  echo "$ATK1 - - [$TODAY:05:22:11 +0000] \"GET /view.php?file=$lfi HTTP/1.1\" 200 1423 \"-\" \"curl/7.88.1\"" >> $LOG
done
log "3 tentatives Path Traversal injectées"

# ─────────────────────────────────────────────────────────────────
# RÉSUMÉ FINAL
# ─────────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║          SETUP TERMINÉ — srv-shopnow                  ║"
echo "╠══════════════════════════════════════════════════════╣"
echo "║  ✓ Apache2 + PHP + MariaDB                            ║"
echo "║  ✓ Application web vulnérable                         ║"
echo "║  ✓ Snort configuré + rules/local.rules vide           ║"
echo "║  ✓ Logs Apache pré-générés :                          ║"
echo "║    - 300 requêtes légitimes                           ║"
echo "║    - 30 requêtes scan Nikto                           ║"
echo "║    - 56 requêtes SQLi (sqlmap)                        ║"
echo "║    - 847 bruteforce WordPress (1 succès)              ║"
echo "║    - 3 tentatives Path Traversal                      ║"
echo "╠══════════════════════════════════════════════════════╣"
echo "║  DISTRIBUER AUX ÉTUDIANTS :                           ║"
echo "║  IP : 10.10.10.10 (ou relever ci-dessous)            ║"
echo "║  Accès : root ou via Kali (10.10.10.99)              ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
echo "IP de cette VM :"
ip addr show | grep "inet " | grep -v 127 | awk '{print "  →  " $2}'
echo ""
warn "NE PAS DISTRIBUER CE SCRIPT AUX ÉTUDIANTS"
