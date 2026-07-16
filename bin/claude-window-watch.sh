#!/usr/bin/env bash
# Watchdog : rouvre une fenetre de 5h si celle en cours a disparu
# (reset Anthropic, expiration non rattrapee par les horaires fixes).
# Ne fait rien tant qu'une fenetre est active -> zero conso la plupart du temps.
set -uo pipefail

export PATH="$HOME/.npm-global/bin:$PATH"

HC_URL="${HC_URL:-}"
CREDS="$HOME/.claude/.credentials.json"
LOCK="$HOME/.claude-window-watch.lock"

# Plage de garde (heure locale du serveur = UTC ; 04:30-20:00 Paris = 02:30-18:00 UTC)
GUARD_START_MIN="${GUARD_START_MIN:-150}"   # 02:30 UTC
GUARD_END_MIN="${GUARD_END_MIN:-1080}"      # 18:00 UTC

# Marge : si la fenetre expire dans moins de X minutes, on considere qu'il faut
# la renouveler plutot que d'attendre le trou.
MIN_REMAINING="${MIN_REMAINING:-10}"

hc_fail() {
  [ -n "$HC_URL" ] || return 0
  curl -fsS -m 10 --retry 3 -o /dev/null --data-raw "${1-}" "${HC_URL}/fail" || true
}

# Un seul watchdog a la fois (le ping peut durer quelques secondes)
exec 9>"$LOCK"
flock -n 9 || { echo "deja en cours, skip"; exit 0; }

# --- Plage de garde ---
now_min=$(( 10#$(date +%H) * 60 + 10#$(date +%M) ))
if [ "$now_min" -lt "$GUARD_START_MIN" ] || [ "$now_min" -ge "$GUARD_END_MIN" ]; then
  echo "hors plage de garde ($(date +%H:%M) UTC), skip"
  exit 0
fi

# --- Lecture du quota ---
tok=$(python3 -c "
import json,sys
try:
    print(json.load(open('$CREDS'))['claudeAiOauth']['accessToken'])
except Exception:
    sys.exit(1)
" 2>/dev/null)

if [ -z "${tok:-}" ]; then
  echo "WARN: credentials illisibles" >&2
  exit 0   # le ping principal alertera sur l'auth, pas la peine de doubler
fi

quota=$(curl -fsS -m 15 https://api.anthropic.com/api/oauth/usage \
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
" 2>/dev/null)

if [ -z "${quota:-}" ]; then
  echo "WARN: endpoint quota injoignable, skip"
  exit 0
fi

util=$(awk '{print $1}' <<<"$quota")
reset=$(awk '{print $2}' <<<"$quota")
now=$(date +%s)
mins_left=$(( (reset - now) / 60 ))

# --- Decision ---
# Fenetre active et confortable -> rien a faire (cas nominal)
if [ "$reset" -gt 0 ] && [ "$mins_left" -gt "$MIN_REMAINING" ]; then
  echo "fenetre active: ${util}% | reste ${mins_left} min -> rien a faire"
  exit 0
fi

# Pas de fenetre (ou elle expire dans <10 min) : on en ouvre une.
echo "AUCUNE FENETRE ACTIVE (reste ${mins_left} min) -> ouverture"
out="$(claude -p "hi" 2>&1)"
rc=$?

if [ $rc -ne 0 ] || grep -qiE 'API Error: 401|authentication_error|Failed to authenticate|Not logged in|Please run /login' <<<"$out"; then
  echo "ECHEC ouverture (rc=${rc})" >&2
  echo "$out" >&2
  hc_fail "WATCHDOG: echec ouverture fenetre (rc=${rc})
${out}"
  exit 1
fi

# Verification : la fenetre s'est-elle vraiment ouverte ?
sleep 3
new=$(curl -fsS -m 15 https://api.anthropic.com/api/oauth/usage \
  -H "authorization: Bearer $tok" \
  -H "anthropic-beta: oauth-2025-04-20" 2>/dev/null | python3 -c "
import json,sys,datetime
try:
    r=json.load(sys.stdin)['five_hour'].get('resets_at')
    print(int(datetime.datetime.fromisoformat(r.replace('Z','+00:00')).timestamp()) if r else 0)
except Exception:
    print(0)
" 2>/dev/null)

new_h=$(date -d "@${new}" "+%H:%M %Z" 2>/dev/null || echo "?")
echo "fenetre ouverte -> reset ${new_h}"
