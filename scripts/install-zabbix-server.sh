#!/usr/bin/env bash
# Instalace Zabbix serveru 8.0 LTS s MariaDB, webem (Apache) a Zabbix Agentem 2 na Debian 13.
# Spousti ho Vagrant jako root. Pri chybe skonci nenulovym kodem (set -e).
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

HOST_NAME="zbx8-fendvit"
SERVER_NAME="Vit Fendrych - OSY 2026"
SECRETS=/root/zabbix-secrets
ZBX_REPO_DEB="zabbix-release_latest_8.0+debian13_all.deb"
ZBX_REPO_URL="https://repo.zabbix.com/zabbix/8.0/release/debian/pool/main/z/zabbix-release/${ZBX_REPO_DEB}"

echo "==> Zakladni balicky"
apt-get update
apt-get install -y wget curl jq openssl ca-certificates

echo "==> Oficialni repozitar Zabbix 8.0 pro Debian 13"
if ! dpkg -s zabbix-release >/dev/null 2>&1 || ! grep -rq "zabbix/8.0" /etc/apt/sources.list.d/; then
    wget -q -O "/tmp/${ZBX_REPO_DEB}" "${ZBX_REPO_URL}"
    dpkg -i "/tmp/${ZBX_REPO_DEB}"
fi
apt-get update

echo "==> Instalace MariaDB, Zabbix serveru, webu, Apache a agenta 2"
apt-get install -y mariadb-server \
    zabbix-server-mysql zabbix-frontend-php zabbix-apache-conf zabbix-sql-scripts zabbix-agent2

# kontrola, ze se Zabbix vzal z repozitare zabbix.com (verze 8.0), ne z Debianu (tam je 7.0)
ZBX_VER=$(dpkg-query -W -f='${Version}' zabbix-server-mysql)
case "$ZBX_VER" in
    *:8.0.*) echo "zabbix-server-mysql $ZBX_VER" ;;
    *) echo "Nainstalovana spatna verze Zabbixu: $ZBX_VER" >&2; exit 1 ;;
esac

systemctl enable --now mariadb

echo "==> Heslo k databazi"
# heslo se vytvori nahodne az ve VM a ulozi jen pro roota, do Gitu se nedostane
install -d -m 700 "$SECRETS"
if [ ! -s "$SECRETS/db-password" ]; then
    (umask 077; openssl rand -hex 16 > "$SECRETS/db-password")
fi
DB_PASS=$(cat "$SECRETS/db-password")

echo "==> Databaze zabbix a uzivatel zabbix"
mysql -uroot <<SQL
CREATE DATABASE IF NOT EXISTS zabbix CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;
CREATE USER IF NOT EXISTS 'zabbix'@'localhost' IDENTIFIED BY '${DB_PASS}';
ALTER USER 'zabbix'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON zabbix.* TO 'zabbix'@'localhost';
FLUSH PRIVILEGES;
SQL

echo "==> Import schematu (jen poprve)"
# kdyz uz v databazi je tabulka dbversion, schema tam je a znovu se neimportuje
HAS_SCHEMA=$(mysql -uroot -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='zabbix' AND table_name='dbversion';")
if [ "$HAS_SCHEMA" = "0" ]; then
    SQL_FILE=/usr/share/zabbix/sql-scripts/mysql/server.sql.gz
    [ -f "$SQL_FILE" ] || { echo "Chybi $SQL_FILE" >&2; exit 1; }
    mysql -uroot -e "SET GLOBAL log_bin_trust_function_creators = 1;"
    zcat "$SQL_FILE" | mysql --default-character-set=utf8mb4 -uzabbix -p"${DB_PASS}" zabbix
    mysql -uroot -e "SET GLOBAL log_bin_trust_function_creators = 0;"
    echo "Schema naimportovano."
else
    echo "Schema uz existuje, preskakuju."
fi

echo "==> Konfigurace Zabbix serveru"
SERVER_CONF=/etc/zabbix/zabbix_server.conf
sed -i -E "s|^#? ?DBPassword=.*|DBPassword=${DB_PASS}|" "$SERVER_CONF"
grep -q "^DBPassword=" "$SERVER_CONF" || echo "DBPassword=${DB_PASS}" >> "$SERVER_CONF"
chown root:zabbix "$SERVER_CONF"
chmod 640 "$SERVER_CONF"

echo "==> Konfigurace agenta 2 (monitoruje mistni server)"
AGENT_CONF=/etc/zabbix/zabbix_agent2.conf
sed -i -E "s|^#? ?Server=.*|Server=127.0.0.1|" "$AGENT_CONF"
sed -i -E "s|^#? ?ServerActive=.*|ServerActive=127.0.0.1|" "$AGENT_CONF"
sed -i -E "s|^#? ?Hostname=.*|Hostname=${HOST_NAME}|" "$AGENT_CONF"

echo "==> Web: zabbix.conf.php (bez PHP wizardu)"
cat > /etc/zabbix/web/zabbix.conf.php <<PHP
<?php
// Vytvoreno skriptem install-zabbix-server.sh, heslo je jen ve VM.
\$DB['TYPE']       = 'MYSQL';
\$DB['SERVER']     = 'localhost';
\$DB['PORT']       = '0';
\$DB['DATABASE']   = 'zabbix';
\$DB['USER']       = 'zabbix';
\$DB['PASSWORD']   = '${DB_PASS}';
\$DB['SCHEMA']     = '';
\$DB['ENCRYPTION'] = false;

\$ZBX_SERVER      = 'localhost';
\$ZBX_SERVER_PORT = '10051';
\$ZBX_SERVER_NAME = '${SERVER_NAME}';

\$IMAGE_FORMAT_DEFAULT = IMAGE_FORMAT_PNG;
PHP
chown www-data:www-data /etc/zabbix/web/zabbix.conf.php
chmod 400 /etc/zabbix/web/zabbix.conf.php

# http://127.0.0.1:8080/ presmeruje rovnou na /zabbix/
cat > /etc/apache2/conf-available/zabbix-redirect.conf <<'EOF'
RedirectMatch ^/$ /zabbix/
EOF
a2enconf -q zabbix-redirect

echo "==> Spusteni a povoleni sluzeb"
systemctl enable mariadb zabbix-server zabbix-agent2 apache2
systemctl restart zabbix-server zabbix-agent2 apache2

for svc in mariadb zabbix-server zabbix-agent2 apache2; do
    systemctl is-active --quiet "$svc" || { echo "Sluzba $svc nebezi" >&2; exit 1; }
    echo "$svc: active"
done

zabbix_server -V | sed -n 1p
zabbix_agent2 -V | sed -n 1p
echo "Hotovo, web: http://127.0.0.1:8080/zabbix/"
