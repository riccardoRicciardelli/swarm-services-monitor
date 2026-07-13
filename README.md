# Monitoraggio Swarm con notifiche — Istruzioni

## 1. Dove mettere lo script

Copia `swarm_check.sh` su un nodo **manager** dello Swarm (deve avere accesso a `docker service ls`):

```bash
sudo mkdir -p /opt/swarm-monitor
sudo cp swarm_check.sh /opt/swarm-monitor/
sudo chmod +x /opt/swarm-monitor/swarm_check.sh
```

Lo script crea da solo `/var/lib/swarm-monitor/state.db` per ricordare lo stato precedente di ogni service (serve a non mandarti lo stesso alert ogni minuto).

---

## 2. Configurare Slack

### Creare il webhook

1. Vai su https://api.slack.com/apps → **Create New App** → **From scratch**
2. Dai un nome all'app (es. "Swarm Monitor") e scegli il workspace
3. Nel menu laterale: **Incoming Webhooks** → attiva il toggle **Activate Incoming Webhooks**
4. Scorri in basso → **Add New Webhook to Workspace**
5. Scegli il canale dove vuoi ricevere gli alert (es. `#alert-infra`) → **Allow**
6. Copia l'URL generato, avrà questa forma:
   ```
   https://hooks.slack.com/services/T000000/B000000/XXXXXXXXXXXXXXXXXXXXXXXX
   ```

### Configurarlo nello script

Apri `swarm_check.sh` e imposta:

```bash
SLACK_WEBHOOK_URL="https://hooks.slack.com/services/T000000/B000000/XXXXXXXXXXXXXXXXXXXXXXXX"
```

Fatto. Non serve altro, il webhook posta direttamente nel canale scelto.

---

## 3. Configurare Telegram

### Creare il bot

1. Apri Telegram, cerca **@BotFather**
2. Manda `/newbot`, segui le istruzioni (nome e username del bot)
3. BotFather ti restituisce un **token**, tipo:
   ```
   123456789:AAExxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
   ```

### Trovare il chat_id

Hai due casi comuni:

**A) Vuoi ricevere i messaggi in privato (tu solo)**
1. Cerca il tuo bot su Telegram (con l'username scelto) e manda `/start`
2. Apri nel browser:
   ```
   https://api.telegram.org/bot<TOKEN>/getUpdates
   ```
   (sostituisci `<TOKEN>` col token vero)
3. Nel JSON di risposta cerca `"chat":{"id":123456789,...}` → quel numero è il tuo `chat_id`

**B) Vuoi ricevere i messaggi in un gruppo Telegram**
1. Crea un gruppo, aggiungi il bot come membro
2. Manda un qualsiasi messaggio nel gruppo
3. Richiama lo stesso URL `getUpdates` come sopra
4. Il `chat_id` di un gruppo è un numero **negativo** (es. `-1001234567890`)

### Configurarlo nello script

```bash
TELEGRAM_BOT_TOKEN="123456789:AAExxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
TELEGRAM_CHAT_ID="123456789"
```

Puoi lasciare **sia Slack che Telegram configurati insieme**: lo script manda la notifica su entrambi i canali se entrambe le variabili sono valorizzate. Se vuoi usarne uno solo, lascia l'altro con stringa vuota `""`.

---

## 4. Programmare l'esecuzione

### Opzione A — Cron (più semplice)

```bash
sudo crontab -e
```

Aggiungi (esegue ogni minuto):

```
* * * * * /opt/swarm-monitor/swarm_check.sh >> /var/log/swarm-monitor.log 2>&1
```

### Opzione B — systemd timer (più robusto, log su journalctl)

Crea `/etc/systemd/system/swarm-monitor.service`:

```ini
[Unit]
Description=Swarm services health check

[Service]
Type=oneshot
ExecStart=/opt/swarm-monitor/swarm_check.sh
```

Crea `/etc/systemd/system/swarm-monitor.timer`:

```ini
[Unit]
Description=Esegue swarm-monitor ogni minuto

[Timer]
OnBootSec=30s
OnUnitActiveSec=60s
Unit=swarm-monitor.service

[Install]
WantedBy=timers.target
```

Attiva:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now swarm-monitor.timer
```

Verifica esecuzioni e log:

```bash
systemctl list-timers | grep swarm-monitor
journalctl -u swarm-monitor.service -f
```

---

## 5. Test rapido

Per verificare che le notifiche funzionino, forza temporaneamente un fallimento, ad esempio scalando un service a un numero di repliche irraggiungibile (es. più nodi di quanti ne hai disponibili), oppure semplicemente testa i webhook a mano:

**Test Slack:**
```bash
curl -X POST -H 'Content-type: application/json' \
  --data '{"text":"Test da swarm-monitor"}' \
  "$SLACK_WEBHOOK_URL"
```

**Test Telegram:**
```bash
curl -X POST "https://api.telegram.org/bot<TOKEN>/sendMessage" \
  -d chat_id="<CHAT_ID>" \
  -d text="Test da swarm-monitor"
```

Se ricevi il messaggio, il canale è configurato correttamente e lo script funzionerà appena rileva uno stato FAIL reale.

---

## 6. Cosa fa esattamente lo script

- Controlla ogni service Swarm confrontando repliche attive vs desiderate
- Notifica **solo al cambio di stato**: quando un service passa da OK a FAIL, e quando torna da FAIL a OK (nessuno spam ripetuto)
- Controlla anche lo stato dei rolling update (`UpdateStatus.State`): se un deploy resta bloccato in `paused` o `rollback_started`, ricevi un alert dedicato
- Lo stato viene salvato in `/var/lib/swarm-monitor/state.db`, un file di testo semplice, nessun database richiesto

## 7. Se hai più manager (alta affidabilità)

Esegui lo script solo su **un** manager alla volta per evitare doppie notifiche. Puoi:
- Usarne uno fisso come "monitor node", oppure
- Wrappare l'esecuzione con un check tipo `docker node inspect self --format '{{.ManagerStatus.Leader}}'` per farlo girare solo sul leader corrente
