#!/usr/bin/env bash
# Nastaveni hostu pres Zabbix API:
#  - mistni Debian 13 (zbx8-fendvit) se sablonou "Linux by Zabbix agent"
#  - import hosta sposdk.cz z Zabbix/export (sablona "Website certificate by Zabbix agent 2")
#  - zmena vychoziho hesla uctu Admin na nahodne (ulozi se jen ve VM)
set -euo pipefail

HOST_NAME="zbx8-fendvit"
API=http://127.0.0.1/zabbix/api_jsonrpc.php
SECRETS=/root/zabbix-secrets
EXPORT=/tmp/sposdk.cz_hosts.yaml
TOKEN=""

# jedno volani API, vrati .result (pri chybe skonci)
api() {
    local method=$1 params=$2 body resp
    body=$(jq -n --arg m "$method" --argjson p "$params" '{jsonrpc:"2.0", method:$m, params:$p, id:1}')
    if [ -n "$TOKEN" ]; then
        resp=$(curl -s -H "Content-Type: application/json-rpc" -H "Authorization: Bearer $TOKEN" -d "$body" "$API")
    else
        resp=$(curl -s -H "Content-Type: application/json-rpc" -d "$body" "$API")
    fi
    if [ "$(echo "$resp" | jq 'has("error")')" = "true" ]; then
        echo "API $method: $(echo "$resp" | jq -c .error)" >&2
        return 1
    fi
    echo "$resp" | jq -c .result
}

echo "==> Prihlaseni do API"
if [ -s "$SECRETS/admin-password" ]; then
    ADMIN_PASS=$(cat "$SECRETS/admin-password")
else
    ADMIN_PASS=zabbix   # vychozi heslo, hned ho zmenim
fi
for i in $(seq 1 30); do
    if TOKEN=$(api user.login "$(jq -n --arg p "$ADMIN_PASS" '{username:"Admin", password:$p}')" 2>/dev/null | jq -r .); then
        break
    fi
    TOKEN=""
    sleep 2
done
[ -n "$TOKEN" ] || { echo "Do API se nepodarilo prihlasit" >&2; exit 1; }

echo "==> Mistni host $HOST_NAME"
GROUP_ID=$(api hostgroup.get '{"filter":{"name":["Linux servers"]},"output":["groupid"]}' | jq -r '.[0].groupid')
TPL_ID=$(api template.get '{"filter":{"host":["Linux by Zabbix agent"]},"output":["templateid"]}' | jq -r '.[0].templateid')
[ "$GROUP_ID" != "null" ] && [ "$TPL_ID" != "null" ] || { echo "Chybi skupina nebo sablona" >&2; exit 1; }

# Ve schematu uz je vychozi host "Zabbix server" (127.0.0.1:10050, sablona Linux by Zabbix agent
# + Zabbix server health). Je to presne tenhle Debian, tak ho prejmenuju na hostname VM.
# Kdyby tam nebyl, vytvorim novy. Sablona "Linux by Zabbix agent" funguje i s agentem 2.
OLD_ID=$(api host.get '{"filter":{"host":["Zabbix server"]},"output":["hostid"]}' | jq -r '.[0].hostid // empty')
if [ "$(api host.get "{\"filter\":{\"host\":[\"$HOST_NAME\"]}}" | jq length)" != "0" ]; then
    echo "Host $HOST_NAME uz existuje."
elif [ -n "$OLD_ID" ]; then
    api host.update "$(jq -n --arg id "$OLD_ID" --arg h "$HOST_NAME" --arg t "$TPL_ID" '{
        hostid:$id, host:$h, name:"Debian 13 (zbx8-fendvit)", status:0,
        tags:[{tag:"OS", value:"Debian 13"}]}')" >/dev/null
    echo "Vychozi host Zabbix server prejmenovan na $HOST_NAME."
else
    api host.create "$(jq -n --arg h "$HOST_NAME" --arg g "$GROUP_ID" --arg t "$TPL_ID" '{
        host:$h, name:"Debian 13 (zbx8-fendvit)",
        groups:[{groupid:$g}], templates:[{templateid:$t}],
        interfaces:[{type:1, main:1, useip:1, ip:"127.0.0.1", dns:"", port:"10050"}],
        tags:[{tag:"OS", value:"Debian 13"}]}')" >/dev/null
    echo "Host $HOST_NAME vytvoren."
fi

echo "==> Import hosta sposdk.cz"
if [ "$(api host.get '{"filter":{"host":["sposdk.cz"]}}' | jq length)" = "0" ]; then
    [ -f "$EXPORT" ] || { echo "Chybi $EXPORT" >&2; exit 1; }
    api configuration.import "$(jq -n --rawfile src "$EXPORT" '{
        format:"yaml", source:$src,
        rules:{
            host_groups:{createMissing:true, updateExisting:false},
            hosts:{createMissing:true, updateExisting:false},
            templateLinkage:{createMissing:true}
        }}')" >/dev/null
    echo "sposdk.cz naimportovan."
else
    echo "sposdk.cz uz existuje."
fi

echo "==> Heslo uctu Admin"
if [ ! -s "$SECRETS/admin-password" ]; then
    NEW_PASS=$(openssl rand -hex 12)
    ADMIN_ID=$(api user.get '{"filter":{"username":["Admin"]},"output":["userid"]}' | jq -r '.[0].userid')
    api user.update "$(jq -n --arg id "$ADMIN_ID" --arg p "$NEW_PASS" '{userid:$id, passwd:$p, current_passwd:"zabbix"}')" >/dev/null
    (umask 077; echo "$NEW_PASS" > "$SECRETS/admin-password")
    echo "Heslo zmeneno, je v $SECRETS/admin-password"
else
    echo "Heslo uz bylo zmenene."
fi

echo "Hotovo. Web: http://127.0.0.1:8080/zabbix/  (uzivatel Admin)"
