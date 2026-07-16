# claude-ping-vps

Ouvre et maintient les fenêtres de 5h de Claude Code sur un VPS, avec détection
des pannes et des resets de quota.

Deux mécanismes complémentaires :

- **`claude-ping`** — horaires fixes, cale les fenêtres sur la journée de travail.
- **`claude-window-watch`** — watchdog, rouvre une fenêtre si elle a disparu.

## Le piège que ça corrige

La version naïve du wrapper était :

```bash
claude -p "hi" || true
```

Claude Code affiche `API Error: 401` **et sort avec le code 0**. Le `|| true`
achevait le travail : systemd affichait `Finished successfully` à chaque
exécution. Résultat, l'authentification était expirée depuis un mois sans que
rien ne le signale — le timer se croyait en bonne santé.

D'où la double vérification dans `bin/claude-ping.sh` : code de retour **et**
inspection de la sortie.

```bash
if [ $rc -ne 0 ] || grep -qiE 'API Error: 401|authentication_error|...' <<<"$out"; then
```

## Fenêtres de 5h

Une fenêtre s'ouvre au **premier message** quand aucune n'est active ; sinon on
rejoint celle en cours. Les horaires sont donc placés pour qu'une fenêtre neuve
s'ouvre au moment où le travail reprend.

| Ping (Paris) | Couvre        | Pourquoi |
|--------------|---------------|----------|
| 04:30        | 04:30 → 09:30 | Absorbe l'arrivée 8h et la réunion 9h-9h30 |
| 09:30        | 09:30 → 14:30 | Sortie de réunion, déborde après le déjeuner |
| 14:30        | 14:30 → 19:30 | Après-midi, marge après le départ 17h |
| 19:30        | 19:30 → 00:30 | Soirées de rush |

Le ping de 04:30 semble gaspillé (personne ne travaille) mais c'est lui qui
décale la bascule suivante à 09:30. Sans lui, l'arrivée à 8h ouvre une fenêtre
qui expire à 13h, en plein déjeuner.

## Lire le quota

Non documenté, mais `resets_at` et `utilization` sont exposés avec le token
OAuth local :

```bash
curl -fsS https://api.anthropic.com/api/oauth/usage \
  -H "authorization: Bearer $TOKEN" \
  -H "anthropic-beta: oauth-2025-04-20"
```

```json
{"five_hour": {"utilization": 12.0, "resets_at": "2026-07-16T10:40:00Z"}}
```

Les mêmes valeurs arrivent en en-têtes sur `/v1/messages`
(`anthropic-ratelimit-unified-5h-reset`, en epoch).

C'est ce qui rend un reset de quota **détectable** : si `resets_at` recule d'un
run à l'autre, la fenêtre attendue n'existe plus.

## Watchdog

Toutes les 10 min, entre 04:30 et 20:00 (Paris). Il lit le quota — aucun token
consommé — et ne fait rien tant qu'une fenêtre est active. Si elle manque, il en
ouvre une.

La plage de garde est indispensable : sans elle, le watchdog ouvrirait une
fenêtre à 00h05, puis 05h05, alignant tout sur minuit et brûlant le quota 7
jours pendant la nuit.

## Installation

```bash
# 1. Scripts (adapter <user>)
install -o <user> -g <user> -m 755 bin/*.sh /home/<user>/bin/

# 2. Env
cp claude-ping.env.example /etc/claude-ping.env
chmod 640 /etc/claude-ping.env && chown root:<user> /etc/claude-ping.env
$EDITOR /etc/claude-ping.env      # renseigner HC_URL

# 3. Units
cp systemd/* /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now claude-ping.timer claude-window-watch.timer
```

Login initial, obligatoire une fois. Le `cd` n'est pas optionnel : `runuser` ne
change pas le répertoire courant, et Claude lancé depuis `/root` (mode 700) sous
un autre utilisateur échoue avec des erreurs illisibles.

```bash
runuser -u <user> -- bash -lc 'cd /home/<user> && export HOME=/home/<user> && claude'
```

Puis `/login`, aller **au bout du flux**, et vérifier qu'un `hi` reçoit une
réponse avant de quitter. Un CTRL+C prématuré écrit un `.credentials.json`
valide en apparence mais avec des tokens vides.

## Healthchecks.io

Créer un check, mettre son URL dans `HC_URL`, et régler :

- **Period : 10 heures** — le plus grand écart entre deux pings est de 9h
  (19:30 → 04:30). Le défaut d'1 jour retarderait une alerte de 24h ; moins de
  10h déclencherait une fausse alerte chaque nuit.
- **Grace : 1 heure**

Alertes envoyées : échec d'authentification, ping impossible, fenêtre perdue,
VPS injoignable (absence de ping).

## Vérifier

```bash
systemctl list-timers | grep claude
journalctl -u claude-ping.service --since today
journalctl -u claude-window-watch.service -n 20
```

Un run sain :

```
ping OK
quota 5h: 12.0% | reset 10:40 UTC (dans 260 min)
```
