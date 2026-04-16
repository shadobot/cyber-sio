#!/bin/bash
# ═══════════════════════════════════════════════════════════════════
#  SCRIPT DE PRÉPARATION — TP3 : VM srv-shopnow (IDS Suricata)
#  BTS SIO SISR — Module Cybersécurité
#  OS cible : Debian 12 (Bookworm) — installation minimale
#  Réservé à l'enseignant — Ne pas distribuer aux étudiants
# ═══════════════════════════════════════════════════════════════════
# Usage :
#   1. Installer Debian 12 en mode minimal (sans bureau graphique)
#   2. sudo bash tp3_setup_suricata.sh
#   3. Attendre ~10 min
#   4. Prendre un snapshot "etat_initial_tp3_suricata"
#   5. Distribuer l'IP + instructions
#
# Architecture réseau :
#   srv-shopnow  : 10.10.10.10/24  (cette VM)
#   kali-attaquant: 10.10.10.99/24 (VM Kali officielle, aucun setup)
#   Réseau : Host-Only ou réseau interne VirtualBox/VMware
# ═══════════════════════════════════════════════════════════════════

set -e

# ─── Couleurs ────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
log()   { echo -e "${GREEN}[+]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
info()  { echo -e "${CYAN}[*]${NC} $1"; }
err()   { echo -e "${RED}[✗]${NC} $1"; }
title() { echo -e "\n${BOLD}${CYAN}━━━ $1 ━━━${NC}\n"; }

# ─── Vérification root ───────────────────────────────────────────
if [ "$EUID" -ne 0 ]; then
    err "Ce script doit être exécuté en tant que root : sudo bash $0"
    exit 1
fi

# ─── Vérification OS ─────────────────────────────────────────────
if ! grep -q "Debian GNU/Linux 12" /etc/os-release 2>/dev/null; then
    warn "Ce script est optimisé pour Debian 12. OS détecté :"
    grep PRETTY_NAME /etc/os-release
    read -p "Continuer quand même ? [o/N] " -n 1 -r; echo
    [[ ! $REPLY =~ ^[Oo]$ ]] && exit 1
fi

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║   BTS SIO SISR — TP3 : Setup VM srv-shopnow              ║"
echo "║   IDS Suricata — Debian 12                               ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

# ═══════════════════════════════════════════════════════════════════
# PHASE 1 — CONFIGURATION RÉSEAU
# ═══════════════════════════════════════════════════════════════════
title "Phase 1/6 — Configuration réseau"

# Hostname
hostnamectl set-hostname srv-shopnow
log "Hostname défini : srv-shopnow"

# Identifier l'interface réseau principale
IFACE=$(ip route 2>/dev/null | grep default | awk '{print $5}' | head -1)
if [ -z "$IFACE" ]; then
    # Fallback : première interface non-lo
    IFACE=$(ip link show | awk -F': ' '/^[0-9]+: [^lo]/{print $2; exit}')
fi

if [ -z "$IFACE" ]; then
    err "Impossible de détecter l'interface réseau."
    err "Vérifier avec 'ip addr show' et relancer."
    exit 1
fi

log "Interface réseau détectée : $IFACE"

# Configurer l'IP fixe
IP_CURRENT=$(ip addr show "$IFACE" 2>/dev/null | grep "inet " | awk '{print $2}' | cut -d/ -f1)
log "IP actuelle : ${IP_CURRENT:-non configurée}"

# Configurer /etc/network/interfaces pour IP fixe
cat > /etc/network/interfaces << EOF
# Fichier généré par tp3_setup_suricata.sh
auto lo
iface lo inet loopback

auto ${IFACE}
iface ${IFACE} inet static
    address 10.10.10.10
    netmask 255.255.255.0
    gateway 10.10.10.1
    dns-nameservers 8.8.8.8 1.1.1.1
EOF

# Appliquer sans perdre la connexion (si on est déjà en SSH)
ip addr add 10.10.10.10/24 dev "$IFACE" 2>/dev/null || true
ip link set "$IFACE" up 2>/dev/null || true
log "IP 10.10.10.10/24 configurée sur $IFACE"

# Mettre à jour /etc/hosts
grep -q "srv-shopnow" /etc/hosts || echo "10.10.10.10 srv-shopnow srv-shopnow.shopnow.fr" >> /etc/hosts
log "/etc/hosts mis à jour"

# ═══════════════════════════════════════════════════════════════════
# PHASE 2 — INSTALLATION DES PAQUETS
# ═══════════════════════════════════════════════════════════════════
title "Phase 2/6 — Installation des paquets"

info "Mise à jour des dépôts Debian..."
apt update -qq

info "Installation de Suricata et outils..."
# suricata : IDS principal (dépôts officiels Debian 12)
# suricata-update : gestionnaire de règles Emerging Threats
# jq : traitement des logs EVE JSON (indispensable pour le TP)
DEBIAN_FRONTEND=noninteractive apt install -y -qq \
    suricata \
    suricata-update \
    jq \
    apache2 \
    mariadb-server \
    php \
    php-mysql \
    libapache2-mod-php \
    curl \
    wget \
    net-tools \
    vim \
    git

log "Suricata installé : $(suricata --version 2>&1 | head -1)"
log "jq installé : $(jq --version)"
log "Apache installé : $(apache2 -v 2>&1 | head -1)"

# Essayer de mettre à jour les règles (facultatif si pas d'internet)
info "Mise à jour des règles Suricata (peut échouer sans internet)..."
suricata-update 2>&1 | tail -3 || warn "Mise à jour règles échouée — pas d'internet. Règles locales suffisantes pour le TP."

# ═══════════════════════════════════════════════════════════════════
# PHASE 3 — CONFIGURATION SURICATA
# ═══════════════════════════════════════════════════════════════════
title "Phase 3/6 — Configuration Suricata"

SURICATA_CONF="/etc/suricata/suricata.yaml"

# Sauvegarder la config originale
cp "$SURICATA_CONF" "${SURICATA_CONF}.orig"
log "Config originale sauvegardée : ${SURICATA_CONF}.orig"

# Patcher HOME_NET
info "Configuration de HOME_NET → 10.10.10.0/24"
# La ligne HOME_NET dans Debian 12 a plusieurs formats possibles
if grep -q 'HOME_NET:' "$SURICATA_CONF"; then
    sed -i 's|HOME_NET:.*|HOME_NET: "[10.10.10.0/24]"|' "$SURICATA_CONF"
else
    warn "Ligne HOME_NET non trouvée dans la configuration — édition manuelle requise"
fi

# Patcher l'interface af-packet
info "Configuration de l'interface af-packet → $IFACE"
if grep -q "interface: eth0" "$SURICATA_CONF"; then
    sed -i "s/interface: eth0/interface: $IFACE/g" "$SURICATA_CONF"
    log "Interface patchée : eth0 → $IFACE"
elif grep -q "interface: default" "$SURICATA_CONF"; then
    sed -i "s/interface: default/interface: $IFACE/g" "$SURICATA_CONF"
    log "Interface patchée : default → $IFACE"
else
    # Chercher la section af-packet et insérer
    warn "Interface non patchée automatiquement. Vérifier manuellement."
    warn "Chercher 'af-packet:' dans $SURICATA_CONF et mettre : interface: $IFACE"
fi

# Créer le répertoire et le fichier de règles
mkdir -p /etc/suricata/rules

cat > /etc/suricata/rules/shopnow.rules << 'RULES_EOF'
# ═══════════════════════════════════════════════════════════════════
# Fichier de règles Suricata — SHOPNOW.FR
# TP3 BTS SIO SISR — Module Cybersécurité
# ═══════════════════════════════════════════════════════════════════
#
# CONSIGNE : Rédiger 6 règles de détection dans ce fichier.
# Syntaxe générale :
#   action proto src src_port -> dst dst_port (options)
#
# Options essentielles :
#   msg:"description"          Message affiché dans l'alerte
#   content:"chaine"           Contenu à chercher dans le payload
#   nocase                     Insensible à la casse
#   http.uri                   Inspecter l'URI HTTP (sticky buffer)
#   http.user_agent            Inspecter le User-Agent HTTP
#   flow:to_server,established Trafic établi vers le serveur
#   threshold:type both, track by_src, count N, seconds T
#   classtype:web-application-attack
#   sid:XXXXXXX                Identifiant unique (1000001 à 1000006)
#   rev:1                      Révision (toujours 1 pour la première version)
#
# EXEMPLE (règle commentée — ne pas décommenter) :
# alert http $EXTERNAL_NET any -> $HTTP_SERVERS $HTTP_PORTS \
#     (msg:"Exemple detection"; content:"test"; http.uri; \
#      classtype:web-application-attack; sid:9999999; rev:1;)
#
# ═══════════════════════════════════════════════════════════════════
# Règle 1 — Scan de ports SYN (nmap)      → SID 1000001
# Règle 2 — Bruteforce SSH                → SID 1000002
# Règle 3 — SQL Injection UNION SELECT    → SID 1000003
# Règle 4 — Outil sqlmap                  → SID 1000004
# Règle 5 — Path Traversal ../            → SID 1000005
# Règle 6 — Scanner web Nikto             → SID 1000006
# ═══════════════════════════════════════════════════════════════════

RULES_EOF

log "Fichier de règles créé : /etc/suricata/rules/shopnow.rules"

# Ajouter shopnow.rules dans la configuration suricata.yaml
# En utilisant python3 (disponible sur Debian 12)
python3 << 'PYEOF'
import re

conf_path = "/etc/suricata/suricata.yaml"
with open(conf_path, "r") as f:
    content = f.read()

# Chercher la section rule-files et ajouter shopnow.rules en premier
rule_section = "rule-files:"
shopnow_rule = "  - /etc/suricata/rules/shopnow.rules"

if shopnow_rule in content:
    print("shopnow.rules déjà présent dans suricata.yaml")
elif rule_section in content:
    # Insérer après "rule-files:"
    content = content.replace(
        rule_section,
        rule_section + "\n" + shopnow_rule
    )
    with open(conf_path, "w") as f:
        f.write(content)
    print("shopnow.rules ajouté à suricata.yaml")
else:
    print("ATTENTION : section rule-files non trouvée — ajout en fin de fichier")
    with open(conf_path, "a") as f:
        f.write(f"\nrule-files:\n{shopnow_rule}\n")
PYEOF

# Vérifier que la configuration est valide
info "Vérification de la configuration Suricata..."
if suricata -T -c "$SURICATA_CONF" -v 2>&1 | grep -q "loaded successfully\|successfully loaded"; then
    log "Configuration Suricata valide ✓"
else
    warn "Avertissement lors de la vérification — contrôler manuellement :"
    suricata -T -c "$SURICATA_CONF" -v 2>&1 | tail -5
fi

# Configurer Suricata pour démarrer avec la bonne interface
info "Configuration du service systemd Suricata..."
mkdir -p /etc/systemd/system/suricata.service.d/
cat > /etc/systemd/system/suricata.service.d/override.conf << EOF
[Service]
ExecStart=
ExecStart=/usr/bin/suricata -c /etc/suricata/suricata.yaml --af-packet=${IFACE} -D --pidfile /run/suricata.pid
EOF

systemctl daemon-reload
systemctl enable suricata
log "Service Suricata configuré pour démarrer sur $IFACE"

# ═══════════════════════════════════════════════════════════════════
# PHASE 4 — APPLICATION WEB VULNÉRABLE
# ═══════════════════════════════════════════════════════════════════
title "Phase 4/6 — Déploiement de l'application web"

# Base de données
systemctl start mariadb
mysql << 'SQLEOF'
CREATE DATABASE IF NOT EXISTS shopnow CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'wp_user'@'localhost' IDENTIFIED BY 'wp_pass_2024';
GRANT ALL PRIVILEGES ON shopnow.* TO 'wp_user'@'localhost';
FLUSH PRIVILEGES;

USE shopnow;
CREATE TABLE IF NOT EXISTS products (
    id INT AUTO_INCREMENT PRIMARY KEY,
    name VARCHAR(200) NOT NULL,
    category VARCHAR(100),
    price DECIMAL(10,2),
    stock INT DEFAULT 0
);

INSERT IGNORE INTO products (name, category, price, stock) VALUES
    ('Nike Air Max 2024', 'shoes', 129.99, 45),
    ('Adidas Stan Smith', 'shoes', 89.99, 120),
    ('Polo Ralph Lauren Blue', 'clothing', 75.00, 30),
    ('Tommy Hilfiger Tee', 'clothing', 45.00, 80),
    ('iPhone 15 Case', 'accessories', 29.99, 200),
    ('Samsung Galaxy S24 Coque', 'accessories', 24.99, 150);
SQLEOF

log "Base de données MariaDB configurée"

# Répertoire des fichiers statiques (pour LFI)
mkdir -p /var/www/files
echo "Bienvenue sur SHOPNOW.FR — Votre boutique en ligne" > /var/www/files/index.html
echo "Catalogue été 2024 disponible" > /var/www/files/catalogue.html

# Page d'accueil
cat > /var/www/html/index.html << 'EOF'
<!DOCTYPE html>
<html lang="fr">
<head><meta charset="UTF-8"><title>SHOPNOW.FR</title></head>
<body>
<h1>SHOPNOW.FR — Boutique en ligne</h1>
<ul>
  <li><a href="/products.php?category=shoes">Chaussures</a></li>
  <li><a href="/products.php?category=clothing">Vêtements</a></li>
  <li><a href="/products.php?category=accessories">Accessoires</a></li>
</ul>
</body>
</html>
EOF

# Page produits — VOLONTAIREMENT VULNÉRABLE (SQL Injection)
cat > /var/www/html/products.php << 'PHPEOF'
<?php
/**
 * Page produits SHOPNOW.FR
 * VOLONTAIREMENT VULNÉRABLE à l'injection SQL — usage pédagogique TP3
 * Aucune requête préparée, concaténation directe de $_GET dans la requête
 */
$conn = new mysqli("localhost", "wp_user", "wp_pass_2024", "shopnow");
if ($conn->connect_error) {
    die("Erreur connexion: " . $conn->connect_error);
}
$category = $_GET["category"] ?? "shoes";
echo "<!DOCTYPE html><html lang='fr'><head><meta charset='UTF-8'>";
echo "<title>Produits — SHOPNOW</title></head><body>";
echo "<h1>Catégorie : " . htmlspecialchars($category) . "</h1>";

// VULNÉRABLE : injection directe de $category sans échappement
$sql = "SELECT * FROM products WHERE category='" . $category . "'";
$result = $conn->query($sql);

if ($result && $result->num_rows > 0) {
    echo "<ul>";
    while ($row = $result->fetch_assoc()) {
        echo "<li><strong>" . htmlspecialchars($row['name']) . "</strong>";
        echo " — " . number_format($row['price'], 2) . " €</li>";
    }
    echo "</ul>";
} elseif ($conn->error) {
    // Erreur SQL visible (mauvaise pratique intentionnelle)
    echo "<p>Erreur SQL : " . $conn->error . "</p>";
} else {
    echo "<p>Aucun produit trouvé.</p>";
}
echo "</body></html>";
$conn->close();
?>
PHPEOF

# Page visionneuse — VOLONTAIREMENT VULNÉRABLE (Path Traversal / LFI)
cat > /var/www/html/view.php << 'PHPEOF'
<?php
/**
 * Visionneuse de pages SHOPNOW.FR
 * VOLONTAIREMENT VULNÉRABLE au Path Traversal (LFI) — usage pédagogique TP3
 * Pas de validation ni de normalisation du paramètre "file"
 */
$file = $_GET["file"] ?? "index.html";
$path = "/var/www/files/" . $file;  // PAS de basename() ni de realpath()

echo "<!DOCTYPE html><html><head><meta charset='UTF-8'><title>Page SHOPNOW</title></head><body>";
echo "<pre>";
if (file_exists($path)) {
    echo htmlspecialchars(file_get_contents($path));
} else {
    echo "Fichier non trouvé : " . htmlspecialchars($file);
}
echo "</pre>";
echo "</body></html>";
?>
PHPEOF

# Page de connexion admin simulée (cible bruteforce)
mkdir -p /var/www/html/wp-admin
cat > /var/www/html/wp-login.php << 'PHPEOF'
<?php
/**
 * Simulation page login WordPress — cible bruteforce
 * Usage pédagogique TP3
 */
header('Content-Type: application/json');
$user = $_POST["log"] ?? $_GET["log"] ?? "";
$pass = $_POST["pwd"] ?? $_GET["pwd"] ?? "";
if ($user === "admin" && $pass === "shopnow@2024") {
    http_response_code(302);
    header('Location: /wp-admin/');
    echo json_encode(["status" => "success"]);
} else {
    http_response_code(200);
    echo json_encode(["status" => "error", "message" => "Identifiants incorrects"]);
}
?>
PHPEOF

cat > /var/www/html/wp-admin/index.php << 'PHPEOF'
<?php echo "<h1>WordPress Admin — SHOPNOW.FR</h1><p>Tableau de bord</p>"; ?>
PHPEOF

chown -R www-data:www-data /var/www/html /var/www/files
systemctl enable apache2
systemctl restart apache2
log "Application web déployée (SQLi + LFI + login admin)"

# ═══════════════════════════════════════════════════════════════════
# PHASE 5 — GÉNÉRATION DES LOGS APACHE PRÉ-EXISTANTS
# ═══════════════════════════════════════════════════════════════════
title "Phase 5/6 — Génération des logs Apache réalistes"

LOG_FILE="/var/log/apache2/access.log"

# IPs simulées (espaces adresses non routables)
IP_SQLI="185.220.101.47"     # Serveur TOR exit node — SQLi avec sqlmap
IP_BRUTE="91.108.4.201"      # IP Telegram — bruteforce WordPress
IP_SCAN="45.142.212.100"     # Scanner Nikto
IP_LFI="79.137.196.21"       # Attaquant LFI
IP_LEGIT="10.10.10.50"       # Utilisateur interne légitime

TODAY=$(date "+%d/%b/%Y")
YESTERDAY=$(date -d "-24hours" "+%d/%b/%Y")
D2=$(date -d "-48hours" "+%d/%b/%Y")

info "Génération du trafic légitime (fond de bruit)..."
for i in $(seq 1 280); do
    H=$(printf "%02d" $((RANDOM % 23)))
    M=$(printf "%02d" $((RANDOM % 59)))
    S=$(printf "%02d" $((RANDOM % 59)))
    TS="$YESTERDAY:$H:$M:$S"
    CATS=("shoes" "clothing" "accessories")
    CAT=${CATS[$((RANDOM % 3))]}
    UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120.0"
    echo "$IP_LEGIT - - [$TS +0000] \"GET /products.php?category=$CAT HTTP/1.1\" 200 $((RANDOM % 2000 + 400)) \"-\" \"$UA\"" >> "$LOG_FILE"
done
log "280 requêtes légitimes générées"

info "Génération du scan Nikto (avant-hier J-2)..."
NIKTO_PATHS=(
    "/.env"
    "/.git/config"
    "/.git/HEAD"
    "/wp-config.php.bak"
    "/wp-config.php~"
    "/admin/"
    "/administrator/"
    "/phpmyadmin/"
    "/.htpasswd"
    "/backup.zip"
    "/backup.sql"
    "/config.php"
    "/config.inc.php"
    "/test.php"
    "/info.php"
    "/phpinfo.php"
    "/.DS_Store"
    "/robots.txt"
    "/sitemap.xml"
    "/.htaccess"
)
NIKTO_UA="Nikto/2.1.6 (Evasions:None) Web Server Scanner"
for path in "${NIKTO_PATHS[@]}"; do
    for j in 1 2 3; do
        M=$(printf "%02d" $((j * 2 + RANDOM % 3)))
        S=$(printf "%02d" $((RANDOM % 59)))
        # robots.txt et sitemap.xml retournent 200, le reste 404
        CODE=404
        [ "$path" = "/robots.txt" ] || [ "$path" = "/sitemap.xml" ] && CODE=200
        echo "$IP_SCAN - - [$D2:02:$M:$S +0000] \"GET $path HTTP/1.1\" $CODE 196 \"-\" \"$NIKTO_UA\"" >> "$LOG_FILE"
    done
done
log "${#NIKTO_PATHS[@]} chemins scannés par Nikto (×3 = $((${#NIKTO_PATHS[@]}*3)) requêtes)"

info "Génération des injections SQL avec sqlmap (hier J-1)..."
SQLI_PAYLOADS=(
    "products.php?category=1%27+UNION+SELECT+1%2C2%2C3--"
    "products.php?category=1+AND+1%3D1--"
    "products.php?category=1+AND+1%3D2--"
    "products.php?category=1%27+AND+SLEEP%285%29--"
    "products.php?category=%27+UNION+SELECT+table_name%2CNULL%2CNULL+FROM+information_schema.tables--"
    "products.php?category=%27+UNION+SELECT+column_name%2CNULL%2CNULL+FROM+information_schema.columns+WHERE+table_name%3D%27products%27--"
    "products.php?category=1+ORDER+BY+10--"
    "products.php?category=1+ORDER+BY+3--"
    "products.php?category=%27+UNION+SELECT+user%28%29%2Cpassword%2C3+FROM+mysql.user--"
    "products.php?category=1%27+AND+%28SELECT+SUBSTRING%28username%2C1%2C1%29+FROM+mysql.user+WHERE+username%3D%27root%27%29%3D%27r%27--"
)
SQLMAP_UA="sqlmap/1.7.9#stable (https://sqlmap.org)"
for payload in "${SQLI_PAYLOADS[@]}"; do
    for j in $(seq 1 6); do
        M=$(printf "%02d" $((j + RANDOM % 5)))
        S=$(printf "%02d" $((RANDOM % 59)))
        echo "$IP_SQLI - - [$YESTERDAY:21:$M:$S +0000] \"GET /$payload HTTP/1.1\" 200 287 \"-\" \"$SQLMAP_UA\"" >> "$LOG_FILE"
    done
done
log "$((${#SQLI_PAYLOADS[@]} * 6)) requêtes SQLi (sqlmap) générées"

info "Génération du bruteforce WordPress (cette nuit)..."
BRUTE_UA="python-requests/2.28.2"
for i in $(seq 1 847); do
    H=2
    M=$(( 34 + i / 60 ))
    S=$(( i % 60 ))
    [ $M -ge 60 ] && { H=3; M=$(( M - 60 )); }
    TS="$TODAY:$(printf "%02d:%02d:%02d" $H $M $S)"
    echo "$IP_BRUTE - - [$TS +0000] \"POST /wp-login.php HTTP/1.1\" 200 24 \"/wp-login.php\" \"$BRUTE_UA\"" >> "$LOG_FILE"
done
# Connexion réussie (code 302 = redirection après auth OK)
echo "$IP_BRUTE - - [$TODAY:04:15:03 +0000] \"POST /wp-login.php HTTP/1.1\" 302 0 \"/wp-login.php\" \"$BRUTE_UA\"" >> "$LOG_FILE"
log "847 tentatives bruteforce WordPress + 1 connexion réussie (302) générées"

info "Génération des tentatives Path Traversal / LFI..."
LFI_TARGETS=(
    "../../etc/passwd"
    "../../../etc/passwd"
    "../../../../etc/passwd"
    "../../etc/shadow"
    "../../../etc/shadow"
    "../../proc/self/environ"
    "../../var/www/html/wp-config.php"
    "../../../var/log/apache2/access.log"
)
for target in "${LFI_TARGETS[@]}"; do
    echo "$IP_LFI - - [$TODAY:05:22:$(printf "%02d" $((RANDOM % 59))) +0000] \"GET /view.php?file=$target HTTP/1.1\" 200 $((RANDOM % 1500 + 200)) \"-\" \"curl/7.88.1\"" >> "$LOG_FILE"
done
log "${#LFI_TARGETS[@]} tentatives Path Traversal générées"

# Résumé des logs générés
TOTAL=$(wc -l < "$LOG_FILE")
log "Total : $TOTAL lignes dans $LOG_FILE"

# ═══════════════════════════════════════════════════════════════════
# PHASE 6 — VÉRIFICATIONS FINALES
# ═══════════════════════════════════════════════════════════════════
title "Phase 6/6 — Vérifications finales"

ERRORS=0

# Test 1 : Suricata binaire
if command -v suricata &>/dev/null; then
    log "✓ Suricata installé : $(suricata --version 2>&1 | head -1)"
else
    err "✗ Suricata non installé"
    ERRORS=$((ERRORS+1))
fi

# Test 2 : Configuration valide
if suricata -T -c /etc/suricata/suricata.yaml -v 2>&1 | grep -qi "loaded successfully\|successfully loaded\|complete"; then
    log "✓ Configuration Suricata valide"
else
    warn "⚠ Vérification config Suricata — résultat incertain"
    warn "  Lancer manuellement : sudo suricata -T -c /etc/suricata/suricata.yaml -v"
fi

# Test 3 : Fichier de règles
if [ -f /etc/suricata/rules/shopnow.rules ]; then
    log "✓ Fichier de règles : /etc/suricata/rules/shopnow.rules"
else
    err "✗ Fichier de règles manquant"
    ERRORS=$((ERRORS+1))
fi

# Test 4 : Apache répond
if curl -s --connect-timeout 3 http://127.0.0.1/ | grep -qi "shopnow\|html"; then
    log "✓ Apache répond sur http://10.10.10.10/"
else
    warn "⚠ Apache ne répond pas — vérifier : systemctl status apache2"
fi

# Test 5 : Page SQLi accessible
if curl -s --connect-timeout 3 "http://127.0.0.1/products.php?category=shoes" | grep -qi "Nike\|Adidas\|produit"; then
    log "✓ Page produits accessible (SQLi target)"
else
    warn "⚠ Page products.php non accessible"
fi

# Test 6 : Logs générés
LOG_LINES=$(wc -l < /var/log/apache2/access.log 2>/dev/null || echo 0)
if [ "$LOG_LINES" -gt 1000 ]; then
    log "✓ Logs Apache pré-générés : $LOG_LINES lignes"
else
    warn "⚠ Logs Apache : seulement $LOG_LINES lignes (attendu > 1000)"
fi

# Test 7 : jq disponible
if command -v jq &>/dev/null; then
    log "✓ jq installé : $(jq --version)"
else
    err "✗ jq non installé"
    ERRORS=$((ERRORS+1))
fi

# Résumé
echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║          SETUP TERMINÉ — srv-shopnow                     ║"
echo "╠══════════════════════════════════════════════════════════╣"
if [ $ERRORS -eq 0 ]; then
echo "║  ✓ Aucune erreur détectée                                 ║"
else
echo "║  ✗ $ERRORS erreur(s) détectée(s) — vérifier ci-dessus    ║"
fi
echo "╠══════════════════════════════════════════════════════════╣"
echo "║  RÉCAPITULATIF POUR LE TP :                              ║"
echo "║                                                            ║"
echo "║  Suricata IDS :                                           ║"
echo "║    Démarrer : sudo systemctl start suricata               ║"
echo "║    OU manuellement :                                       ║"
printf "║    sudo suricata -c /etc/suricata/suricata.yaml -i %-6s ║\n" "$IFACE"
echo "║                                                            ║"
echo "║  Logs en temps réel :                                     ║"
echo "║    sudo tail -f /var/log/suricata/fast.log                ║"
echo "║    sudo tail -f /var/log/suricata/eve.json | jq ...       ║"
echo "║                                                            ║"
echo "║  Règles étudiants : /etc/suricata/rules/shopnow.rules     ║"
echo "║  Config principale : /etc/suricata/suricata.yaml          ║"
echo "║  Logs Apache : /var/log/apache2/access.log                ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║  DISTRIBUER AUX ÉTUDIANTS :                               ║"
echo "║    IP serveur cible  : 10.10.10.10                        ║"
echo "║    IP Kali attaquant : 10.10.10.99 (VM Kali officielle)   ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║  → PRENDRE UN SNAPSHOT : etat_initial_tp3_suricata        ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "IP actuelle de cette VM :"
ip addr show "$IFACE" | grep "inet " | awk '{print "  → " $2}'
echo ""
warn "NE PAS DISTRIBUER CE SCRIPT AUX ÉTUDIANTS"
warn "Il contient les explications des vulnérabilités et les logs pré-générés"
