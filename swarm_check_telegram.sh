#!/bin/bash
#
# swarm_check_telegram.sh
# Monitora i services di Docker Swarm e invia notifiche su Telegram
# solo quando cambia lo stato (OK -> FAIL oppure FAIL -> OK), evitando spam.
#
# Requisiti: bash, docker cli (sul manager), curl
# Va eseguito su un nodo MANAGER dello Swarm (o comunque dove gira "docker service ls").

set -euo pipefail

# ============================================================
# CONFIGURAZIONE - modifica questi valori
# ============================================================

TELEGRAM_BOT_TOKEN="123456789:AAExxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
TELEGRAM_CHAT_ID="123456789"

# File dove viene salvato lo stato precedente (per la deduplica)
STATE_DIR="/var/lib/swarm-monitor"
STATE_FILE="${STATE_DIR}/state.db"

# Nome host da includere nei messaggi (utile se monitori più cluster)
CLUSTER_NAME="$(hostname)"

# ============================================================
# FUNZIONE DI NOTIFICA
# ============================================================

send_telegram() {
  local text="$1"
  curl -s -X POST \
    "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d chat_id="${TELEGRAM_CHAT_ID}" \
    -d parse_mode="Markdown" \
    --data-urlencode text="$text" > /dev/null
}

# ============================================================
# GESTIONE STATO (per deduplica)
# ============================================================
# Il file di stato contiene righe tipo:
#   servicename|status
# dove status è OK oppure FAIL (o UPDATE_STUCK)

mkdir -p "$STATE_DIR"
touch "$STATE_FILE"

get_previous_status() {
  local svc="$1"
  grep -F "^${svc}|" "$STATE_FILE" 2>/dev/null | cut -d'|' -f2 || true
}

set_status() {
  local svc="$1"
  local status="$2"
  # rimuove la vecchia riga per quel service e aggiunge quella nuova
  grep -vF "^${svc}|" "$STATE_FILE" > "${STATE_FILE}.tmp" 2>/dev/null || true
  mv "${STATE_FILE}.tmp" "$STATE_FILE"
  echo "${svc}|${status}" >> "$STATE_FILE"
}

# ============================================================
# CHECK PRINCIPALE
# ============================================================

# Recupera tutti i services con formato: nome replicas
# Esempio riga: webapp_frontend 2/3
docker service ls --format '{{.Name}} {{.Replicas}}' | while read -r name replicas; do

  running=$(echo "$replicas" | cut -d'/' -f1)
  desired=$(echo "$replicas" | cut -d'/' -f2)

  prev_status=$(get_previous_status "$name")

  if [ "$running" != "$desired" ]; then
    current_status="FAIL"
    if [ "$prev_status" != "FAIL" ]; then
      msg="🔴 *[${CLUSTER_NAME}]* Service *${name}*: solo ${running}/${desired} repliche attive"
      send_telegram "$msg"
    fi
  else
    current_status="OK"
    if [ "$prev_status" == "FAIL" ]; then
      msg="✅ *[${CLUSTER_NAME}]* Service *${name}* tornato regolare: ${running}/${desired} repliche attive"
      send_telegram "$msg"
    fi
  fi

  set_status "$name" "$current_status"
done

# ============================================================
# CHECK ROLLING UPDATE BLOCCATI
# ============================================================
# Intercetta i service con un update in stato "paused" o "rollback_started"
# (tipicamente sintomo di un deploy fallito che Swarm ha fermato in automatico)

docker service ls --format '{{.ID}} {{.Name}}' | while read -r id name; do

  update_state=$(docker service inspect "$id" --format '{{.UpdateStatus.State}}' 2>/dev/null || echo "none")

  update_key="${name}_update"
  prev_update_status=$(get_previous_status "$update_key")

  if [ "$update_state" == "paused" ] || [ "$update_state" == "rollback_started" ]; then
    if [ "$prev_update_status" != "STUCK" ]; then
      msg="🟠 *[${CLUSTER_NAME}]* Rolling update del service *${name}* in stato: *${update_state}* — verifica manuale necessaria"
      send_telegram "$msg"
    fi
    set_status "$update_key" "STUCK"
  else
    if [ "$prev_update_status" == "STUCK" ]; then
      msg="✅ *[${CLUSTER_NAME}]* Rolling update del service *${name}* risolto (stato: ${update_state})"
      send_telegram "$msg"
    fi
    set_status "$update_key" "OK"
  fi
done
