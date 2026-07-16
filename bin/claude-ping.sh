#!/usr/bin/env bash
set -uo pipefail

export PATH="$HOME/.npm-global/bin:$PATH"

# URL de ping Healthchecks.io. Vide = monitoring desactive.
HC_URL="${HC_URL:-}"

CREDS="$HOME/.claude/.credentials.json"
STATE="$HOME/.claude-ping.state"

# Envoie un ping a Healthchecks.io. $1 = suffixe (/start, /fail ou vide).
# $2 = corps du message (visible dans le dashboard et les alertes).
hc() {
  [ -n "$HC_URL" ] || return 0
  curl -fsS -m 10 --retry 3 -o /dev/null --data-raw "${2-}" "${HC_URL}${1}" || true
}

# Interroge l'endpoint de quota OAuth. Sortie: "<utilization> <resets_at_epoch>"
# ou vide si indisponible. La fenetre de 5h est la seule qui nous interesse.
fetch_quota() {
  local tok
  tok=$(python3 -c "
import json,sys
try:
    print(json.load(open('$CREDS'))['claudeAiOauth']['accessToken'])
except Exception:
    sys.exit(1)
" 2>/dev/null) || return 1
  [ -n "$tok" ] || return 1

  curl -fsS -m 15 https://api.anthropic.com/api/oauth/usage \
    -H "authorization: Bearer $tok" \
    -H "anthropic-beta: oauth-2025-04-20" 2>/dev/null | python3 -c "
import json,sys,datetime
try:
    d=json.load(sys.stdin)['five_hour']
    r=d.get('resets_at')
    ts=int(datetime.datetime.fromisoformat(r.replace('Z','+00:00')).timestamp()) if r else 0
    print(f\"{d.get('utilization',0)} {ts}\")
except Exception:
    sys.exit(1)
" 2>/dev/null
}

hc "/start"

# --- 1. Le ping lui-meme ---
out="$(claude -p "hi" 2>&1)"
rc=$?

# Claude sort parfois en 0 malgre une erreur d'auth : on inspecte aussi la sortie.
if [ $rc -ne 0 ] || grep -qiE 'API Error: 401|authentication_error|Failed to authenticate|Invalid API key|Please run /login' <<<"$out"; then
  echo "PING FAILED (rc=${rc})" >&2
  echo "$out" >&2
  hc "/fail" "AUTH/PING KO (rc=${rc})
${out}"
  exit 1
fi

echo "ping OK"
echo "$out"

# --- 2. Verification de la fenetre de 5h ---
now=$(date +%s)
quota=$(fetch_quota) || quota=""

if [ -z "$quota" ]; then
  # Non bloquant : le ping a reussi, seule la verif quota est indisponible.
  echo "WARN: quota indisponible (endpoint injoignable)" >&2
  hc "" "ping OK (quota non verifiable)
${out}"
  exit 0
fi

util=$(awk '{print $1}' <<<"$quota")
reset=$(awk '{print $2}' <<<"$quota")
reset_h=$(date -d "@${reset}" "+%H:%M %Z" 2>/dev/null || echo "?")
mins_left=$(( (reset - now) / 60 ))

# Une fenetre fraiche ouverte par CE ping expire dans ~300 min (5h).
# Nettement moins = on a rejoint une fenetre deja ouverte (normal en journee).
# Le cas anormal : le reset precedent a saute (reset Anthropic, fenetre perdue).
prev_reset=$(cat "$STATE" 2>/dev/null || echo 0)
echo "quota 5h: ${util}% | reset ${reset_h} (dans ${mins_left} min)"

msg="ping OK
quota 5h: ${util}% utilise
reset: ${reset_h} (dans ${mins_left} min)"

if [ "$prev_reset" -gt 0 ] && [ "$reset" -lt "$prev_reset" ] && [ $((prev_reset - reset)) -gt 600 ]; then
  # Le reset a recule de >10 min par rapport au run precedent :
  # la fenetre attendue n'existe plus (reset cote Anthropic).
  echo "WARN: fenetre perdue (reset recule de $(( (prev_reset - reset) / 60 )) min)" >&2
  hc "/fail" "FENETRE PERDUE - reset Anthropic probable
attendu: $(date -d "@${prev_reset}" '+%H:%M %Z' 2>/dev/null)
actuel : ${reset_h}
${msg}"
  echo "$reset" > "$STATE"
  exit 1
fi

echo "$reset" > "$STATE"
hc "" "$msg"
