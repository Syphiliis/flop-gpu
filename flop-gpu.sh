#!/usr/bin/env bash
# flop-gpu.sh — links the GPU the reader rented themselves to their FLOP worker, in one command run on the VPS
# (lot K45 of easynode-dev).
#
# Replaces steps 6 and 7 of the FLOP GPU node guide (BreizhNode on Medium). After steps 1 to 5 (as root,
# /opt/flop-miner ready, miner.env filled in):
#   bash flop-gpu.sh            asks for the GPU provider (RunPod for now), says what to do in its console, asks
#                               for the pod's ID, waits until it serves the right model and the right policy,
#                               writes miner.env and starts the worker
#   bash flop-gpu.sh --dry-run  shows the instructions and, if an ID is given, reads the pod's /health once, then
#                               stops: nothing is written or started
#
# What the command guarantees:
# - it asks for no API key and no access to the provider's account: the reader creates, stops and deletes their pod
#   in the console; the command only reaches the pod's /health, through RunPod's HTTPS proxy;
# - INFERENCE_API_KEY (miner.env) is shown once, and once more if the pod refuses it, alone on its line, on request,
#   after the instructions that say where to paste it; the screen and its scrollback are cleared as soon as it is
#   pasted, or on any exit while it is shown; it never appears in a process's command line and is written only to
#   miner.env; nothing typed is echoed; SESSION_AUTH_TOKEN and the signer's key are never shown;
# - safe to run again: flop-gpu.etat keeps the provider, the pod's ID and the language (no secret), offered on the
#   next run; once the instructions are shown, any exit other than 0 reminds you that the pod, if it was created, is
#   billed until Stop, then Terminate in the console.
# Language: English by default; FLOP_GPU_LANG=fr switches to French and is remembered in flop-gpu.etat
#   (FLOP_GPU_LANG=en switches back).
# Colors: NO_COLOR=1 turns colors off; there are none either when the output is not a terminal.
# Overrides: FLOP_MINER_DIR (/opt/flop-miner), FLOP_RUNPOD_TEMPLATE (tipfc9vtff), FLOP_GPU_ATTENTE_MIN (40).
# Exit codes: 0 done; 2 VPS not ready or usage; 3 policy; 6 pod (ID, model, key or policy not fixed);
#             7 time limit; 8 worker or public name; 130 interrupted.
#
# flop-gpu.sh — relie à son worker FLOP le GPU que le lecteur a loué lui-même, en une commande lancée sur le VPS
# (lot K45 d'easynode-dev).
#
# Remplace les étapes 6 et 7 du guide du nœud GPU FLOP (Medium de BreizhNode). Après les étapes 1 à 5 (en root,
# /opt/flop-miner prêt, miner.env rempli) :
#   bash flop-gpu.sh            demande le fournisseur du GPU (RunPod pour l'instant), dit quoi faire dans sa console,
#                               demande l'identifiant du pod, attend qu'il serve le bon modèle et la bonne politique,
#                               écrit miner.env et démarre le worker
#   bash flop-gpu.sh --a-vide   montre la consigne et, si un identifiant est donné, lit une fois le /health du pod,
#                               puis s'arrête : rien n'est écrit ni démarré
#
# Ce que la commande garantit :
# - aucune clé API ni aucun accès au compte du fournisseur n'est demandé : le lecteur crée, arrête et supprime son pod
#   dans la console ; la commande ne joint que le /health du pod, par le proxy HTTPS de RunPod ;
# - INFERENCE_API_KEY (miner.env) s'affiche une fois, et une autre si le pod la refuse, seule sur sa ligne, sur
#   demande, après la consigne qui dit où la coller ; écran et historique s'effacent dès qu'elle est collée, ou à toute
#   sortie pendant son affichage ; elle ne passe dans la ligne de commande d'aucun processus, ne s'écrit que dans
#   miner.env ; rien de ce qui se tape ne s'affiche ; SESSION_AUTH_TOKEN et la clé du signataire ne s'affichent jamais ;
# - rejouable : flop-gpu.etat garde le fournisseur et l'identifiant du pod (aucun secret), proposés au passage suivant ;
#   dès la consigne montrée, toute sortie autre que 0 rappelle que le pod, s'il a été créé, se paie jusqu'à Stop, puis
#   Terminate dans la console.
# Langue : anglais par défaut ; FLOP_GPU_LANG=fr passe au français, retenu dans flop-gpu.etat
#   (FLOP_GPU_LANG=en revient à l'anglais).
# Couleurs : NO_COLOR=1 coupe les couleurs ; il n'y en a pas non plus quand la sortie n'est pas un terminal.
# Dérogations : FLOP_MINER_DIR (/opt/flop-miner), FLOP_RUNPOD_TEMPLATE (tipfc9vtff), FLOP_GPU_ATTENTE_MIN (40).
# Sorties : 0 fait ; 2 VPS pas prêt ou usage ; 3 politique ; 6 pod (identifiant, modèle, clé ou politique non
#           corrigée) ; 7 délai dépassé ; 8 worker ou nom public ; 130 interrompu.
# shellcheck disable=SC1112,SC2059 # apostrophes typographiques voulues ; PROXY et les formats choisis par tx sont printf
{ set +xv; } 2>/dev/null # bash -x imprimerait la clé : la trace est coupée d'office
unset BASH_XTRACEFD
set -Eeuo pipefail
umask 077
export LC_ALL=C

VERSION=0.3.4
DIR=${FLOP_MINER_DIR:-/opt/flop-miner}
ENVF=$DIR/miner.env
ETAT=$DIR/flop-gpu.etat # FOURNISSEUR=, POD= et FLOP_GPU_LANG= : aucun secret
TEMPLATE_ID=${FLOP_RUNPOD_TEMPLATE:-tipfc9vtff} # template public « FLOP GPU devnet » (lot K44)
ATTENTE_MIN=${FLOP_GPU_ATTENTE_MIN:-40}
[[ $ATTENTE_MIN =~ ^[0-9]{1,3}$ ]] && [ "$((10#$ATTENTE_MIN))" -ge 1 ] || ATTENTE_MIN=40
ATTENTE_MIN=$((10#$ATTENTE_MIN)) # 08 resterait de l'octal pour $(( ))
PROXY=https://%s-8000.proxy.runpod.net
PAS=20
IP_FORCEE=""
NL=$'\n'

# Couleurs : codes SGR seuls (gras, atténué, vert, jaune, rouge, cyan, retour à la normale), et seulement si NO_COLOR
# est vide ou absente, si TERM n'est ni vide ni dumb, et si la sortie standard comme la sortie d'erreur sont des terminaux ;
# sinon toutes vides : l'écran est le même texte, sans codes. La clé, la politique et son empreinte n'en portent jamais.
GRAS="" ATT="" VERT="" JAUNE="" ROUGE="" CYAN="" RAZ=""
if [ -z "${NO_COLOR:-}" ] && [ -n "${TERM:-}" ] && [ "${TERM:-}" != dumb ] && [ -t 1 ] && [ -t 2 ]; then
  GRAS=$'\033[1m' ATT=$'\033[2m' VERT=$'\033[32m' JAUNE=$'\033[33m' ROUGE=$'\033[31m' CYAN=$'\033[36m' RAZ=$'\033[0m'
fi

lire() { # valeur de la ligne CLE= de miner.env, ou du fichier donné
  awk -v k="$1" 'index($0, k "=") == 1 { v = substr($0, length(k) + 2) } END { printf "%s", v }' "${2:-$ENVF}"
}

# La langue, avant tout message (aide et usage compris) : FLOP_GPU_LANG (en ou fr), sinon celle que flop-gpu.etat a
# retenue, sinon l'anglais. Toute autre valeur de FLOP_GPU_LANG arrête la commande (sortie 2), sans rien faire d'autre.
LANGUE=${FLOP_GPU_LANG:-}
case $LANGUE in
  en | fr) ;;
  "")
    if [ -f "$ETAT" ] && [ -r "$ETAT" ]; then LANGUE=$(lire FLOP_GPU_LANG "$ETAT" 2>/dev/null) || LANGUE=""; fi
    case $LANGUE in en | fr) ;; *) LANGUE=en ;; esac
    ;;
  *)
    printf '%s✗%s FLOP_GPU_LANG must be en or fr / FLOP_GPU_LANG doit valoir en ou fr\n' "$ROUGE" "$RAZ" >&2
    exit 2
    ;;
esac
tx() { # le texte dans la langue du passage : l'anglais d'abord, le français ensuite (invites, formats printf) ; sans
  # français, l'anglais
  if [ "$LANGUE" = fr ]; then printf '%s' "${2:-$1}"; else printf '%s' "$1"; fi
}
msg() { # une ligne à l'écran dans la langue du passage : l'anglais d'abord, le français ensuite ; sans français,
  # l'anglais
  if [ "$LANGUE" = fr ]; then printf '%s\n' "${2:-$1}"; else printf '%s\n' "$1"; fi
}
M_CLE=$(tx '[key masked]' '[clé masquée]')
M_POL=$(tx '[policy masked]' '[politique masquée]')
M_EMP=$(tx '[hash masked]' '[empreinte masquée]')
M_EMP_ERR=$(tx '[hash]' '[empreinte]') # dans le message de decode-policy.sh
M_ERR=${ROUGE}✗${RAZ}' '$(tx 'Unexpected error (line %s).' 'Erreur inattendue (ligne %s).')

A_VIDE=0
case "${1:-}" in
  "") ;;
  --a-vide | --dry-run) A_VIDE=1 ;;
  -h | --aide | --help)
    if [ "$LANGUE" = fr ]; then
      sed -n '30,56p' "$0" 2>/dev/null || true
    else
      sed -n '2,28p' "$0" 2>/dev/null || true
    fi
    exit 0
    ;;
  *)
    msg "usage: bash flop-gpu.sh [--dry-run]" "usage : bash flop-gpu.sh [--a-vide]" >&2
    exit 2
    ;;
esac

INF="" POL="" PH="" MH="" NOM_HTTPS="" FOURNISSEUR="" POD="" POD_CONNU="" SANTE="" ENV_TMP="" ETAT_TMP=""
CODE_S=000 RAPPEL=0 CLE_ECRAN=0

# L'écran : chaque texte passe par tx, msg ou l'une de ces aides, l'anglais d'abord, le français ensuite ; un texte de
# plusieurs lignes garde ses suites en retrait sous sa première ligne. Les données (dire, la clé) ne passent par aucune.
dire() { printf '%s\n' "$*"; } # une donnée telle quelle (politique, empreinte, ligne vide)
titre() { # titre <n> <anglais> <français> : ligne vide, puis « [n/4] Titre » en gras
  printf '\n%s[%s/4] %s%s\n' "$GRAS" "$1" "$(tx "$2" "$3")" "$RAZ"
}
ligne() { # ligne <anglais> [français] : du texte en retrait de 2
  local t
  t=$(tx "$1" "${2:-}")
  printf '  %s\n' "${t//$NL/$NL  }"
}
attenue() { # attenue <anglais> [français] : du texte atténué, en retrait de 2
  local t
  t=$(tx "$1" "${2:-}")
  printf '  %s%s%s\n' "$ATT" "${t//$NL/$NL  }" "$RAZ"
}
action() { # action <n> <anglais> <français> : une action numérotée, ses suites de ligne sous son texte
  local t
  t=$(tx "$2" "$3")
  printf '  %s. %s\n' "$1" "${t//$NL/$NL     }"
}
fait() { # fait <anglais> [français] : « ✓ » vert, ce qui est fait
  local t
  t=$(tx "$1" "${2:-}")
  printf '  %s✓%s %s\n' "$VERT" "$RAZ" "${t//$NL/$NL    }"
}
attention() { # attention <anglais> [français] : « ! » jaune, ce qui coûte ou ce qui bloque
  local t
  t=$(tx "$1" "${2:-}")
  printf '  %s!%s %s\n' "$JAUNE" "$RAZ" "${t//$NL/$NL    }"
}
lien() { printf '    %s%s%s\n' "$CYAN" "$1" "$RAZ"; } # une adresse ou une ligne à copier (donnée), en retrait de 4
masque() { # aucun secret ne sort, même dans un message d'erreur de FLOP
  local l
  while IFS= read -r l || [ -n "$l" ]; do
    [ -z "$INF" ] || l=${l//"$INF"/"$M_CLE"}
    [ -z "$POL" ] || l=${l//"$POL"/"$M_POL"}
    if [ -n "$PH" ]; then
      l=${l//"$PH"/"$M_EMP"}
      l=${l//"${PH#0x}"/"$M_EMP"}
    fi
    printf '%s\n' "$l"
  done
}
rappel() { # armé dès la consigne montrée (le lecteur a pu créer un pod) : toute sortie autre que 0 le dit
  [ "$RAPPEL" = 1 ] || return 0
  printf "%s!%s $(tx 'If it was created, your RunPod pod%s is billed by the hour\n  until you Stop then Terminate it in the RunPod console (Pods).' \
    'S’il a été créé, votre pod RunPod%s se paie à l’heure\n  jusqu’à Stop puis Terminate dans la console RunPod (Pods).')\n" \
    "$JAUNE" "$RAZ" "${POD:+ $POD}" >&2
}
effacer_cle() { # si la clé est à l'écran : écran puis historique effacés, dans cet ordre ; le drapeau ne tombe
  # qu'après, pour qu'un signal reçu entre les deux efface encore (deux effacements ne gênent pas)
  if [ "$CLE_ECRAN" = 1 ]; then
    { printf '\033[H\033[2J\033[3J' >/dev/tty; } 2>/dev/null || true
    CLE_ECRAN=0
  fi
}
die() { # die <code> <message anglais> <message français> ; sans français, l'anglais (jamais « unbound variable ») ;
  # « ✗ » rouge, puis le message ; ses lignes suivantes (le remède) en retrait de 2
  local c=$1 t
  effacer_cle
  t=$(tx "$2" "${3:-}")
  printf '%s✗%s %s\n' "$ROUGE" "$RAZ" "${t//$NL/$NL  }" | masque >&2
  rappel
  exit "$c"
}
vider_tty() { # jette ce qui a été tapé d'avance (une Entrée en trop, une clé collée dans le terminal)
  while IFS= read -r -s -t 0.2 -n 4096 _ 2>/dev/null </dev/tty; do :; done
}
fin() {
  effacer_cle
  if [ -n "$ENV_TMP" ]; then rm -f -- "$ENV_TMP"; fi
  if [ -n "$ETAT_TMP" ]; then rm -f -- "$ETAT_TMP"; fi
  vider_tty || true
  stty echo 2>/dev/null </dev/tty || true
}
interrompu() {
  trap - INT TERM HUP
  effacer_cle
  stty echo 2>/dev/null </dev/tty || true
  printf '\n%s✗%s %s\n' "$ROUGE" "$RAZ" "$(tx 'Interrupted.' 'Interrompu.')" >&2
  rappel
  exit 130
}
trap fin EXIT
trap interrompu INT TERM HUP
trap 'trap - ERR; effacer_cle; printf "$M_ERR\n" "$LINENO" >&2; rappel' ERR

preparer() {
  local o
  [ "$(id -u)" = 0 ] || die 2 "Run the command as root: type sudo -i first." \
    "Lancez la commande en root : tapez d’abord sudo -i."
  for o in curl jq awk flock timeout docker stty; do
    command -v "$o" >/dev/null 2>&1 || die 2 "Missing tool: $o (step 2 of the guide)." \
      "Outil absent : $o (étape 2 du guide)."
  done
  docker compose version >/dev/null 2>&1 || die 2 "docker compose is missing (step 2 of the guide)." \
    "docker compose est absent (étape 2 du guide)."
  [ -f "$ENVF" ] && [ -x "$DIR/decode-policy.sh" ] && [ -f "$DIR/docker-compose.miner.yml" ] &&
    [ -f "$DIR/docker-compose.tls.yml" ] || die 2 "$DIR is not ready: do steps 3 to 5 of the guide first." \
    "$DIR n’est pas prêt : faites d’abord les étapes 3 à 5 du guide."
  [[ $TEMPLATE_ID =~ ^[A-Za-z0-9_-]{1,64}$ ]] || die 2 "Invalid RunPod template ID: $TEMPLATE_ID." \
    "Identifiant de template RunPod invalide : $TEMPLATE_ID."
  { : </dev/tty; } 2>/dev/null || die 2 "No terminal: run the command in a terminal, to answer its questions." \
    "Aucun terminal : lancez la commande dans un terminal, pour y répondre."
  if [ "$A_VIDE" = 0 ]; then
    exec 9>"$DIR/.flop-gpu.verrou"
    flock -n 9 || die 2 "The command is already running in another terminal." \
      "La commande tourne déjà dans un autre terminal."
  fi
  MH=$(lire MODEL_HASH | tr 'A-F' 'a-f')
  [[ $MH =~ ^0x[0-9a-f]{64}$ ]] || die 2 "MODEL_HASH is unreadable in miner.env (step 3 of the guide)." \
    "MODEL_HASH est illisible dans miner.env (étape 3 du guide)."
  INF=$(lire INFERENCE_API_KEY)
  if ! [[ $INF =~ ^[A-Za-z0-9._~+/=-]{16,256}$ ]]; then
    INF=""
    die 2 "INFERENCE_API_KEY is empty or invalid in miner.env (step 4 of the guide)." \
      "INFERENCE_API_KEY est vide ou invalide dans miner.env (étape 4 du guide)."
  fi
  lire_politique
}

lire_politique() { # POL et PH, tels que miner.env les porte (vides s'il n'y en a pas encore)
  POL=$(lire DECODE_POLICY)
  POL=${POL#\'}
  POL=${POL%\'}
  PH=$(lire DECODE_POLICY_HASH | tr 'A-F' 'a-f')
}

ip_publique() {
  local ip=$IP_FORCEE
  [ -n "$ip" ] || ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{ for (i = 1; i < NF; i++) if ($i == "src") { print $(i + 1); exit } }')
  [ -n "$ip" ] || ip=$(hostname -I 2>/dev/null | awk '{ print $1 }')
  [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  case $ip in
    10.* | 127.* | 169.254.* | 192.168.* | 172.1[6-9].* | 172.2[0-9].* | 172.3[01].* | 100.6[4-9].* | 100.[7-9][0-9].* | \
      100.1[01][0-9].* | 100.12[0-7].*) return 1 ;;
  esac
  printf '%s' "$ip"
}

nom_https() { # NOM_HTTPS, le nom public du worker : connu avant la première question
  local ip garde=0
  NOM_HTTPS=$(lire SESSION_PUBLIC_HOST)
  if [ -n "$NOM_HTTPS" ] && [[ $NOM_HTTPS != *.sslip.io ]]; then
    garde=1
  else
    ip=$(ip_publique) || die 8 "No public IPv4 address found.
Write SESSION_PUBLIC_HOST=<DNS name of this VPS> in miner.env,
then run the command again. Nothing else is done." "Aucune adresse IPv4 publique trouvée.
Écrivez SESSION_PUBLIC_HOST=<nom DNS de ce VPS> dans miner.env,
puis relancez la commande. Rien d’autre n’est fait."
    NOM_HTTPS=${ip//./-}.sslip.io
  fi
  printf '  %s  %s%s%s\n' "$(tx 'Worker address' 'Adresse du worker')" "$CYAN" "$NOM_HTTPS" "$RAZ"
  if [ "$garde" = 1 ]; then
    attenue "Already in miner.env, kept." "Déjà dans miner.env, gardée."
  else
    attenue "These numbers must be your VPS's IP address." "Ces chiffres doivent être l’adresse IP de votre VPS."
  fi
  [[ $NOM_HTTPS =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]] ||
    die 8 "SESSION_PUBLIC_HOST is not a lowercase DNS name: $NOM_HTTPS.
Nothing else is done." "SESSION_PUBLIC_HOST n’est pas un nom DNS en minuscules : $NOM_HTTPS.
Rien d’autre n’est fait."
}

politique() {
  local v=() err
  if [ "$A_VIDE" = 1 ]; then
    ligne "Dry run: nothing will be written or started." "Passage à vide : rien ne sera écrit ni démarré."
  else
    ligne "Reading the decoding policy from FLOP…" "Lecture de la politique de décodage chez FLOP…"
    [ -z "$(lire FLOP_CLI)" ] || v+=("FLOP_CLI=$(lire FLOP_CLI)")
    [ -z "$(lire FLOP_RPC)" ] || v+=("FLOP_RPC=$(lire FLOP_RPC)")
    if ! err=$(decode_policy "${v[@]+"${v[@]}"}"); then
      if [ -n "$POL" ]; then # la chaîne a pu retirer la politique écrite : on reprend celle que FLOP publie
        attention "FLOP refuses the policy in miner.env: taking the one it publishes." \
          "FLOP refuse la politique de miner.env : reprise de celle qu’il publie."
        vider_politique
        err=$(decode_policy "${v[@]+"${v[@]}"}") || {
          printf '%s\n' "$err" | sed -E "s/(0x)?[0-9a-fA-F]{64}/$M_EMP_ERR/g; s/[{].*\$/$M_POL/" | masque >&2
          die 3 "decode-policy.sh refused the policy, or the FLOP network did not answer
within 5 min. Nothing else is done." "decode-policy.sh a refusé la politique, ou le réseau FLOP n’a pas répondu
en 5 min. Rien d’autre n’est fait."
        }
      else
        printf '%s\n' "$err" | sed -E "s/(0x)?[0-9a-fA-F]{64}/$M_EMP_ERR/g; s/[{].*\$/$M_POL/" | masque >&2
        die 3 "decode-policy.sh refused the policy, or the FLOP network did not answer
within 5 min. Nothing else is done." "decode-policy.sh a refusé la politique, ou le réseau FLOP n’a pas répondu
en 5 min. Rien d’autre n’est fait."
      fi
    fi
  fi
  lire_politique
  if ! { [[ $PH =~ ^0x[0-9a-f]{64}$ ]] && printf '%s' "$POL" | jq -e 'type == "object"' >/dev/null 2>&1; }; then
    if [ "$A_VIDE" = 1 ]; then
      attenue "No policy in miner.env yet: the real command reads it from FLOP." \
        "Pas encore de politique dans miner.env : la vraie commande la lit chez FLOP."
    else
      die 3 "No decoding policy in miner.env after decode-policy.sh.
Nothing else is done." "Pas de politique de décodage dans miner.env après decode-policy.sh.
Rien d’autre n’est fait."
    fi
  elif [ "$A_VIDE" = 0 ]; then
    fait "Decoding policy read from FLOP" "Politique de décodage lue chez FLOP"
  fi
}
decode_policy() { # stdout jeté, stderr rendu (pour un message masqué) ; Ctrl+C l'interrompt (--foreground)
  # shellcheck disable=SC2069 # voulu : stderr vers la capture, stdout jeté
  (cd "$DIR" && env "$@" timeout --foreground -k 10 300 ./decode-policy.sh miner.env 2>&1 >/dev/null)
}
vider_politique() { # DECODE_POLICY= et DECODE_POLICY_HASH= vides, d'un seul coup, mode 600
  ENV_TMP=$(mktemp "$ENVF.XXXXXX")
  awk '/^DECODE_POLICY=/ { print "DECODE_POLICY="; next } /^DECODE_POLICY_HASH=/ { print "DECODE_POLICY_HASH="; next }
    { print }' "$ENVF" >"$ENV_TMP"
  chmod 600 "$ENV_TMP"
  mv -f "$ENV_TMP" "$ENVF"
  ENV_TMP=""
}

choisir_fournisseur() { # FOURNISSEUR ; QuickPod et Vast viendront dans une version suivante
  local r=""
  titre 1 "GPU provider" "Fournisseur du GPU"
  dire "  1) RunPod"
  for _ in 1 2 3; do
    vider_tty
    printf '%s' "$(tx '  Press Enter for RunPod: ' '  Appuyez sur Entrée pour RunPod : ')" >/dev/tty
    IFS= read -r -s r </dev/tty || r=""
    printf '\n' >/dev/tty
    case ${r//[[:space:]]/} in
      "" | 1 | "&") # & : la touche 1 d'un clavier AZERTY, sans Maj (recette réelle du 18/11)
        FOURNISSEUR=runpod
        fait "RunPod" "RunPod"
        return 0
        ;;
    esac
    attention "Press Enter: only RunPod is offered for now.
QuickPod and Vast will come later." "Appuyez sur Entrée : seul RunPod est proposé pour l’instant.
QuickPod et Vast viendront ensuite."
  done
  die 2 "No provider chosen." "Aucun fournisseur choisi."
}

lire_etat() { # POD_CONNU : le pod que flop-gpu.etat garde pour ce fournisseur, s'il est bien formé
  local p
  [ -f "$ETAT" ] || return 0
  [ "$(lire FOURNISSEUR "$ETAT")" = "$FOURNISSEUR" ] || return 0
  p=$(lire POD "$ETAT")
  if [[ $p =~ ^[a-z0-9]{6,40}$ ]]; then POD_CONNU=$p; fi
}

garder_pod() { # vrai si le lecteur garde le pod connu de ce VPS (Entrée, o, oui, y, yes), faux s'il en donne un
  # nouveau (n, non, no) ; dans les deux langues, casse indifférente
  local r=""
  RAPPEL=1 # ce pod a existé : il peut se payer encore
  printf '  %s  %s%s%s\n' "$(tx 'Pod from a previous run' 'Pod d’un passage précédent')" "$CYAN" "$POD_CONNU" "$RAZ"
  for _ in 1 2 3; do
    vider_tty
    printf '%s' "$(tx '  Press Enter to keep this pod, n to enter a new one: ' \
      '  Appuyez sur Entrée pour garder ce pod, n pour en donner un nouveau : ')" >/dev/tty
    IFS= read -r -s r </dev/tty || r=""
    printf '\n' >/dev/tty
    r=${r//[[:space:]]/}
    case ${r,,} in
      "" | o | oui | y | yes)
        POD=$POD_CONNU
        fait "Pod kept: $POD" "Pod gardé : $POD"
        return 0
        ;;
      n | non | no)
        attention "Pod $POD_CONNU is billed while it runs.
If you no longer need it: Stop, then Terminate (Pods)." "Le pod $POD_CONNU se paie tant qu’il tourne.
S’il ne sert plus : Stop, puis Terminate (Pods)."
        return 1
        ;;
    esac
    attention "Answer with Enter (keep this pod) or n (enter a new one)." \
      "Répondez par Entrée (garder ce pod) ou par n (en donner un nouveau)."
  done
  die 2 "Answer not understood. Run the command again." "Réponse non comprise. Relancez la commande."
}

consigne_runpod() { # 1 : le lien, puis où coller la clé ; 2 : le GPU, Deploy Pod et où lire l'identifiant (après la
  # clé, l'écran effacé)
  RAPPEL=1 # dès ici, le lecteur a pu créer un pod
  if [ "$1" = 1 ]; then
    ligne "Open this link in your browser:" "Ouvrez ce lien dans votre navigateur :"
    lien "https://console.runpod.io/hub/template/$TEMPLATE_ID"
    ligne 'The public template "FLOP GPU devnet" has everything but your key.' \
      "Le template public « FLOP GPU devnet » contient tout, sauf votre clé."
    action 1 "Click ${GRAS}Configure Pod${RAZ}, then ${GRAS}Set overrides${RAZ}." \
      "Cliquez sur ${GRAS}Configure Pod${RAZ}, puis sur ${GRAS}Set overrides${RAZ}."
    action 2 "Open ${GRAS}Environment variables${RAZ}, without touching the lines already there." \
      "Ouvrez ${GRAS}Environment variables${RAZ}, sans toucher aux lignes déjà présentes."
    action 3 "Click ${GRAS}Add Environment variable${RAZ} and name it INFERENCE_API_KEY." \
      "Cliquez sur ${GRAS}Add Environment variable${RAZ} et nommez-la INFERENCE_API_KEY."
    action 4 "Paste the key below as its value, then click ${GRAS}Set overrides${RAZ} at the bottom." \
      "Collez la clé ci-dessous en valeur, puis cliquez sur ${GRAS}Set overrides${RAZ} en bas."
    attention "Without this key, the pod restarts in a loop
and you pay until you delete it." "Sans cette clé, le pod redémarre en boucle
et se paie jusqu’à ce que vous le supprimiez."
  else
    ligne "Then, on the same RunPod page:" "Puis, dans la même page RunPod :"
    action 5 "Pick an available GPU: NVIDIA, RTX 30 series or newer, or the A40,
with 16 GB or more (24 GB is plenty). CUDA is already set to 13.0 to 13.4.
Choosing Community in Filter resets CUDA to Any: tick 13.0 to 13.4 again." \
      "Choisissez un GPU disponible : NVIDIA, RTX 30 ou plus récente, ou l’A40,
avec 16 Go ou plus (24 Go suffisent). CUDA est déjà réglé sur 13.0 à 13.4.
Passer à Community dans Filter remet CUDA à Any : recochez 13.0 à 13.4."
    action 6 "Click ${GRAS}Deploy Pod${RAZ}. If it says Deploy when available, pick another GPU." \
      "Cliquez sur ${GRAS}Deploy Pod${RAZ}. S’il affiche Deploy when available,
prenez un autre GPU."
    attention "From now on the pod is billed by the hour,
until Stop, then Terminate (Pods)." "Dès lors, le pod se paie à l’heure,
jusqu’à Stop, puis Terminate (Pods)."
    ligne "Copy the pod's ID from the RunPod console (Pods)." \
      "Copiez l’identifiant du pod dans la console RunPod (Pods)."
  fi
}

montrer_cle() { # INFERENCE_API_KEY seule sur sa ligne, sur Entrée ; écran et historique effacés une fois collée
  dire ""
  attention "This key is the password between your worker and your GPU.
Show it to no one. The screen is cleared as soon as you paste it." \
    "Cette clé est le mot de passe entre votre worker et votre GPU.
Ne la montrez à personne. L’écran s’efface dès qu’elle est collée."
  vider_tty
  printf '%s' "$(tx '  Press Enter to show the key: ' '  Appuyez sur Entrée pour afficher la clé : ')" >/dev/tty
  IFS= read -r -s _ </dev/tty || die 2 "Terminal closed: the key is not shown." "Terminal fermé : la clé n’est pas affichée."
  printf '\n' >/dev/tty
  CLE_ECRAN=1 # dès ici, toute sortie efface l'écran (effacer_cle : die, interrompu, piège ERR, fin)
  printf '%s\n' "$INF" >/dev/tty
  vider_tty
  printf '%s' "$(tx '  Press Enter once the key is pasted and saved in RunPod: ' \
    '  Appuyez sur Entrée une fois la clé collée et enregistrée dans RunPod : ')" >/dev/tty
  IFS= read -r -s _ </dev/tty || :
  effacer_cle
  fait "Key pasted. Screen and scrollback cleared." "Clé collée. Écran et historique effacés."
}

demander_pod() { # POD : l'identifiant tapé, ou tiré de l'adresse du proxy ; lu sans écho, réaffiché une fois validé
  local saisie="" adresse='^(https?://)?([a-z0-9]{6,40})-[0-9]{2,5}\.proxy\.runpod\.net(/[^[:space:]]*)?$'
  POD=""
  for _ in 1 2 3; do
    vider_tty
    if [ "$A_VIDE" = 0 ]; then
      printf '%s' "$(tx '  Pod ID (or its address https://…-8000.proxy.runpod.net): ' \
        '  Identifiant du pod (ou son adresse https://…-8000.proxy.runpod.net) : ')" >/dev/tty
    elif [ -n "$POD_CONNU" ]; then
      printf "$(tx '  Pod ID to check once (Enter: %s): ' '  Identifiant du pod à sonder une fois (Entrée : %s) : ')" \
        "$POD_CONNU" >/dev/tty
    else
      printf '%s' "$(tx '  Pod ID to check once (Enter to skip): ' \
        '  Identifiant du pod à sonder une fois (Entrée pour passer) : ')" >/dev/tty
    fi
    IFS= read -r -s saisie </dev/tty || saisie=""
    printf '\n' >/dev/tty
    saisie=${saisie//[[:space:]]/}
    if [ -z "$saisie" ] && [ "$A_VIDE" = 1 ]; then
      POD=$POD_CONNU
      return 0
    fi
    # la clé d'inférence collée ici, entière ou en partie, n'est ni acceptée ni réaffichée
    if [ -n "$saisie" ] && { [[ $saisie == *"$INF"* ]] || { [ "${#saisie}" -ge 6 ] && [[ $INF == *"$saisie"* ]]; }; }; then
      attention "This is your inference key: it goes in INFERENCE_API_KEY, in RunPod,
and is not shown here. Type your pod's ID instead." \
        "C’est votre clé d’inférence : elle va dans INFERENCE_API_KEY, chez RunPod,
et ne s’affiche pas ici. Tapez plutôt l’identifiant de votre pod."
      continue
    fi
    if [[ $saisie =~ ^[a-z0-9]{6,40}$ ]]; then
      POD=$saisie
    elif [[ $saisie =~ $adresse ]]; then
      POD=${BASH_REMATCH[2]}
    fi
    if [ -n "$POD" ]; then
      fait "Pod $POD" "Pod $POD"
      return 0
    fi
    if [ -z "$saisie" ]; then
      attention "Nothing was typed." "Rien n’a été tapé."
    else
      attention "This is not a RunPod pod ID (lowercase letters and digits).
What you typed is not shown." "Ce n’est pas un identifiant de pod RunPod (minuscules et chiffres).
La saisie n’est pas réaffichée."
    fi
  done
  die 6 "No valid pod ID in three tries.
Run the command again once the pod is deployed." "Aucun identifiant de pod valide en trois essais.
Relancez la commande une fois le pod déployé."
}

garder_etat() { # flop-gpu.etat : FOURNISSEUR=, POD= et FLOP_GPU_LANG= (la langue du passage), écrits d'un seul
  # coup, mode 600 ; aucun secret
  ETAT_TMP=$(mktemp "$ETAT.XXXXXX")
  printf 'FOURNISSEUR=%s\nPOD=%s\nFLOP_GPU_LANG=%s\n' "$FOURNISSEUR" "$POD" "$LANGUE" >"$ETAT_TMP"
  chmod 600 "$ETAT_TMP"
  mv -f "$ETAT_TMP" "$ETAT"
  ETAT_TMP=""
}

etat_sante() { # $1 code HTTP de /health, $2 model_identity : l'état du pod en mots, le code HTTP atténué
  case $1 in
    200)
      if [ "$2" = measured ]; then tx 'Model measured' 'Modèle mesuré'; else tx 'Model being measured…' 'Modèle en cours de mesure…'; fi
      ;;
    000) tx 'Not reachable yet' 'Pas encore joignable' ;;
    401) printf '%s %s(HTTP 401)%s' "$(tx 'Key refused' 'Clé refusée')" "$ATT" "$RAZ" ;;
    404 | 502 | 503 | 504 | 520 | 521 | 522 | 523 | 524)
      printf '%s %s(HTTP %s)%s' "$(tx 'Starting' 'Démarrage')" "$ATT" "$1" "$RAZ"
      ;;
    *) printf '%s %s(HTTP %s)%s' "$(tx 'Unexpected answer' 'Réponse inattendue')" "$ATT" "$1" "$RAZ" ;;
  esac
}

sante() { # /health du pod avec la clé de miner.env : code dans CODE_S, réponse dans SANTE
  local sortie dern
  sortie=$(curl -q -sS --max-time 20 --config <(printf 'header = "Authorization: Bearer %s"\n' "$INF") \
    -w '\n%{http_code}' "$(printf "$PROXY" "$POD")/health" 2>/dev/null) || true
  dern=${sortie##*$'\n'}
  if [ "$dern" = "$sortie" ]; then SANTE=""; else SANTE=${sortie%$'\n'*}; fi
  CODE_S=$dern
  [[ $CODE_S =~ ^[0-9]{3}$ ]] || CODE_S=000
}

sonder() { # passage à vide : un seul /health, en lecture
  local e
  sante
  e=$(etat_sante "$CODE_S" "$(printf '%s' "$SANTE" | jq -r '.model_identity // empty' 2>/dev/null || true)")
  ligne "Pod $POD now: $e" "Pod $POD à cet instant : $e"
}

montrer_politique() { # le pod sert une autre politique : celle de miner.env et son empreinte (publiques), à mettre
  # dans le pod par Edit Pod ; Entrée une fois remplacées
  dire ""
  attention "Pod $POD serves the right model, but another decoding policy.
FLOP has changed it since the template was created." \
    "Le pod $POD sert le bon modèle, mais une autre politique de décodage.
FLOP l’a changée depuis la création du template."
  action 1 "In the RunPod console (Pods), open this pod's three-dot menu." \
    "Dans la console RunPod (Pods), ouvrez le menu ⋮ de ce pod."
  action 2 "Click ${GRAS}Edit Pod${RAZ}, then ${GRAS}Environment Variables${RAZ}." \
    "Cliquez sur ${GRAS}Edit Pod${RAZ}, puis sur ${GRAS}Environment Variables${RAZ}."
  action 3 "Replace the values of DECODE_POLICY and DECODE_POLICY_HASH with the
public values below. Leave the other variables as they are." \
    "Remplacez les valeurs de DECODE_POLICY et de DECODE_POLICY_HASH par les
valeurs publiques ci-dessous. Ne touchez pas aux autres variables."
  action 4 "Click ${GRAS}Save${RAZ}: the pod restarts." "Cliquez sur ${GRAS}Save${RAZ} : le pod redémarre."
  ligne "Value of DECODE_POLICY:" "Valeur de DECODE_POLICY :"
  dire "$POL"
  ligne "Value of DECODE_POLICY_HASH:" "Valeur de DECODE_POLICY_HASH :"
  dire "$(lire DECODE_POLICY_HASH)"
  vider_tty
  printf '%s' "$(tx '  Press Enter once the policy is replaced: ' \
    '  Appuyez sur Entrée une fois la politique remplacée : ')" >/dev/tty
  IFS= read -r -s _ </dev/tty || :
  printf '\n' >/dev/tty
}

attendre() { # /health toutes les PAS s jusqu'à la limite : retour au premier model_ok et policy_ok vrais, mesurés.
  # 404 trois minutes d'affilée : le conseil, une fois ; autre modèle mesuré : sortie 6 (garde F5 : jamais avant la
  # mesure) ; 401 : la clé réaffichée (montrer_cle), autre politique : montrer_politique, chacun une fois par passage,
  # puis la limite repart pour ATTENTE_MIN ; ensuite, le même refus 3 min d'affilée depuis l'Entrée (tout autre code,
  # dont un code de redémarrage, remet le compte à zéro) : sortie 6, avec son remède ; limite dépassée : sortie 7, dont
  # la fin suit le dernier état lu (un refus : son remède ; sinon le conseil). Une ligne « m:ss  état » par changement
  # d'état, ou par minute.
  local debut limite maint ident okm okp refus etat_gpu dernier="" vu=0 d404=0 dit404=0 cle_vue=0 pol_vue=0
  local t_cle=0 t_pol=0 conseil remede_cle remede_pol
  conseil=$(tx "Check the pod ID, that the pod is running, and its logs (console, Logs).
\"INFERENCE_API_KEY is required\" means the variable is missing;
\"cuda>=13.0\" means a host with the wrong CUDA." \
    "Vérifiez l’identifiant, que le pod tourne, et ses journaux (console, Logs).
« INFERENCE_API_KEY is required » veut dire la variable oubliée ;
« cuda>=13.0 », un hôte au mauvais CUDA.")
  remede_cle=$(tx "In the RunPod console (Pods), open this pod's three-dot menu, then Edit Pod.
Check that INFERENCE_API_KEY holds the key shown, whole, without spaces,
and that the change is saved.
Then run the command again: it will show the key again." \
    "Dans la console RunPod (Pods), ouvrez le menu ⋮ de ce pod, puis Edit Pod.
Vérifiez que INFERENCE_API_KEY porte la clé affichée, entière, sans espace,
et que la modification est enregistrée.
Puis relancez la commande : elle remontrera la clé.")
  remede_pol=$(tx "In the RunPod console (Pods), open this pod's three-dot menu, then Edit Pod.
Check that DECODE_POLICY and DECODE_POLICY_HASH hold the values shown, whole,
and that the change is saved.
Then run the command again: it will show the policy again." \
    "Dans la console RunPod (Pods), ouvrez le menu ⋮ de ce pod, puis Edit Pod.
Vérifiez que DECODE_POLICY et DECODE_POLICY_HASH portent les valeurs
affichées, entières, et que la modification est enregistrée.
Puis relancez la commande : elle remontrera la politique.")
  debut=$(date +%s)
  limite=$((debut + ATTENTE_MIN * 60))
  attenue "Up to $ATTENTE_MIN min. The first start downloads about 9 GB, then the model." \
    "$ATTENTE_MIN min au plus. Le premier démarrage télécharge environ 9 Go, puis le modèle."
  while :; do
    maint=$(date +%s)
    ident="" okm=false okp=false refus=""
    sante
    if [ "$CODE_S" != 404 ]; then d404=0; elif [ "$d404" = 0 ]; then d404=$maint; fi
    case $CODE_S in
      200)
        ident=$(printf '%s' "$SANTE" | jq -r '.model_identity // empty' 2>/dev/null || true)
        okm=$(printf '%s' "$SANTE" | H=${MH#0x} jq -r '((.model_hash // "") | ascii_downcase | ltrimstr("0x")) == env.H' \
          2>/dev/null || echo false)
        okp=$(printf '%s' "$SANTE" | H=${PH#0x} jq -r '((.decode_policy_hash // "") | ascii_downcase | ltrimstr("0x")) == env.H' \
          2>/dev/null || echo false)
        if [ "$ident" = measured ]; then
          [ "$okm" = true ] || die 6 "The GPU serves another model than the one in miner.env.
The template is out of date. Delete the pod (Stop, then Terminate)
and tell the author of the guide." "Le GPU sert un autre modèle que celui de miner.env.
Le template n’est plus à jour. Supprimez le pod (Stop, puis Terminate)
et prévenez l’auteur du guide."
          if [ "$okp" = true ]; then break; fi
          refus=politique # bon modèle mesuré, autre politique
        fi
        ;;
      401) refus=cle ;;
    esac
    # le compte d'un refus part de sa consigne, et repart de zéro à chaque autre code lu (redémarrage compris)
    if [ "$refus" != cle ]; then t_cle=$maint; fi
    if [ "$refus" != politique ]; then t_pol=$maint; fi
    case $refus in
      cle)
        if [ "$cle_vue" = 0 ]; then
          cle_vue=1
          dire ""
          attention "Pod $POD refuses the key in miner.env (HTTP 401).
Its INFERENCE_API_KEY variable holds another value." "Le pod $POD refuse la clé de miner.env (HTTP 401).
Sa variable INFERENCE_API_KEY porte une autre valeur."
          action 1 "In the RunPod console (Pods), open this pod's three-dot menu." \
            "Dans la console RunPod (Pods), ouvrez le menu ⋮ de ce pod."
          action 2 "Click ${GRAS}Edit Pod${RAZ}, then ${GRAS}Environment Variables${RAZ}." \
            "Cliquez sur ${GRAS}Edit Pod${RAZ}, puis sur ${GRAS}Environment Variables${RAZ}."
          action 3 "Replace the value of INFERENCE_API_KEY with the key shown below.
Leave the other variables as they are." "Remplacez la valeur de INFERENCE_API_KEY par la clé affichée plus bas.
Ne touchez pas aux autres variables."
          action 4 "Click ${GRAS}Save${RAZ}: the pod restarts." "Cliquez sur ${GRAS}Save${RAZ} : le pod redémarre."
          montrer_cle
          t_cle=$(date +%s)
          limite=$((t_cle + ATTENTE_MIN * 60))
          ligne "Waiting again, $ATTENTE_MIN min at most: the pod restarts with the key." \
            "L’attente reprend, $ATTENTE_MIN min au plus : le pod redémarre avec la clé."
          continue
        fi
        [ $((maint - t_cle)) -lt 180 ] || die 6 "Pod $POD still refuses the key (HTTP 401) after 3 min.
$remede_cle" "Le pod $POD refuse toujours la clé (HTTP 401) depuis 3 min.
$remede_cle"
        ;;
      politique)
        if [ "$pol_vue" = 0 ]; then
          pol_vue=1
          montrer_politique
          t_pol=$(date +%s)
          limite=$((t_pol + ATTENTE_MIN * 60))
          ligne "Waiting again, $ATTENTE_MIN min at most: the pod restarts with the policy." \
            "L’attente reprend, $ATTENTE_MIN min au plus : le pod redémarre avec la politique."
          continue
        fi
        [ $((maint - t_pol)) -lt 180 ] || die 6 "Pod $POD still serves a different decoding policy after 3 min.
$remede_pol" "Le pod $POD sert toujours une autre politique, depuis 3 min.
$remede_pol"
        ;;
    esac
    etat_gpu=$(etat_sante "$CODE_S" "$ident")
    if [ "$refus" = politique ]; then
      etat_gpu=$(tx "Model measured, other decoding policy" "Modèle mesuré, autre politique de décodage")
    fi
    if [ "$etat_gpu" != "$dernier" ] || [ $((maint - vu)) -ge 60 ]; then
      printf '  %d:%02d  %s\n' $(((maint - debut) / 60)) $(((maint - debut) % 60)) "$etat_gpu"
      dernier=$etat_gpu vu=$maint
    fi
    if [ "$d404" != 0 ] && [ "$dit404" = 0 ] && [ $((maint - d404)) -ge 180 ]; then
      dit404=1
      attention "Pod $POD has answered 404 for 3 min. Still waiting.
$conseil" "Depuis 3 min, le pod $POD répond 404. L’attente continue.
$conseil"
    fi
    if [ "$maint" -ge "$limite" ]; then
      case $refus in
        cle) die 7 "The GPU is not ready after $(((maint - debut) / 60)) min.
Pod $POD still refuses the key in miner.env (HTTP 401).
$remede_cle" "Le GPU n’est pas prêt après $(((maint - debut) / 60)) min.
Le pod $POD refuse toujours la clé de miner.env (HTTP 401).
$remede_cle" ;;
        politique) die 7 "The GPU is not ready after $(((maint - debut) / 60)) min.
Pod $POD still serves a different decoding policy from miner.env.
$remede_pol" "Le GPU n’est pas prêt après $(((maint - debut) / 60)) min.
Le pod $POD sert toujours une autre politique que miner.env.
$remede_pol" ;;
        *) die 7 "The GPU is not ready after $(((maint - debut) / 60)) min.
$conseil" "Le GPU n’est pas prêt après $(((maint - debut) / 60)) min.
$conseil" ;;
      esac
    fi
    sleep "$PAS"
  done
  fait "GPU ready: model and policy verified" "GPU prêt : modèle et politique vérifiés"
}

ecrire_env() { # $1 OPENAI_BASE_URL, $2 SESSION_PUBLIC_HOST : remplacés (ou ajoutés) d'un seul coup, mode 600
  ENV_TMP=$(mktemp "$ENVF.XXXXXX")
  E_OB=$1 E_SH=$2 awk '
    /^OPENAI_BASE_URL=/ { if (!a++) print "OPENAI_BASE_URL=" ENVIRON["E_OB"]; next }
    /^SESSION_PUBLIC_HOST=/ { if (!b++) print "SESSION_PUBLIC_HOST=" ENVIRON["E_SH"]; next }
    { print }
    END { if (!a) print "OPENAI_BASE_URL=" ENVIRON["E_OB"]; if (!b) print "SESSION_PUBLIC_HOST=" ENVIRON["E_SH"] }' \
    "$ENVF" >"$ENV_TMP"
  chmod 600 "$ENV_TMP"
  mv -f "$ENV_TMP" "$ENVF"
  ENV_TMP=""
}

lier() {
  local c=(docker compose --env-file miner.env -f docker-compose.miner.yml -f docker-compose.tls.yml)
  ecrire_env "$(printf "$PROXY" "$POD")/v1" "$NOM_HTTPS"
  fait "miner.env updated  ${ATT}OPENAI_BASE_URL, SESSION_PUBLIC_HOST${RAZ}" \
    "miner.env mis à jour  ${ATT}OPENAI_BASE_URL, SESSION_PUBLIC_HOST${RAZ}"
  ligne "Starting the worker…" "Démarrage du worker…"
  (cd "$DIR" && "${c[@]}" pull && "${c[@]}" up -d) ||
    die 8 "The worker failed to start. Read its logs:
  cd $DIR
  docker compose --env-file miner.env -f docker-compose.miner.yml \\
    -f docker-compose.tls.yml logs" "Le démarrage du worker a échoué. Lisez ses journaux :
  cd $DIR
  docker compose --env-file miner.env -f docker-compose.miner.yml \\
    -f docker-compose.tls.yml logs"
  fait "Worker started" "Worker démarré"
}

resume() {
  printf '\n%s%s%s%s\n' "$GRAS" "$VERT" "$(tx 'Done. Your RunPod GPU now serves your FLOP worker.' \
    'C’est fait. Votre GPU RunPod sert maintenant votre worker FLOP.')" "$RAZ"
  printf '  %s  %s%s%s  %s%s%s\n' "$(tx 'RunPod pod' 'Pod RunPod')" "$CYAN" "$POD" "$RAZ" \
    "$CYAN" "$(printf "$PROXY" "$POD")" "$RAZ"
  attention "The pod is billed by the hour while it runs, even with the worker stopped.
To stop paying: RunPod console, Pods, this pod, Stop, then Terminate." \
    "Le pod se paie à l’heure tant qu’il tourne, même worker arrêté.
Pour arrêter de payer : console RunPod, Pods, ce pod, Stop, puis Terminate."
  attention "At \$0 of credit, RunPod deletes this pod and your worker loses its GPU.
Turn on Auto-pay or a Low balance alert (Billing)." \
    "À 0 \$ de crédit, RunPod supprime ce pod et votre worker perd son GPU.
Activez Auto-pay ou une Low balance alert (Billing)."
  ligne "Run this command again to keep this pod or enter a new one." \
    "Relancez cette commande pour garder ce pod ou en donner un nouveau."
  ligne "Next: step 8 of the guide. Paste these three lines first:" \
    "Ensuite : étape 8 du guide. Collez d’abord ces trois lignes :"
  lien "cd $DIR"
  lien 'C="docker compose --env-file miner.env -f docker-compose.miner.yml -f docker-compose.tls.yml"'
  lien "NAME=\"\$(sed -n 's/^SESSION_PUBLIC_HOST=//p' miner.env)\"; echo \"\$NAME\""
}

stty -echo 2>/dev/null </dev/tty || true # rien de ce qui se tape ne s'affiche, pas même une clé collée trop tôt
printf '%sflop-gpu %s%s  %s%s%s\n' "$GRAS" "$VERSION" "$RAZ" "$ATT" \
  "$(tx 'Link your rented GPU to your FLOP worker (guide, steps 6 and 7)' \
    'Reliez votre GPU loué à votre worker FLOP (guide, étapes 6 et 7)')" "$RAZ"
preparer
nom_https
politique
choisir_fournisseur
lire_etat
titre 2 "Your RunPod pod" "Votre pod RunPod"
if [ "$A_VIDE" = 1 ]; then
  consigne_runpod 1
  dire ""
  attenue "Dry run: the real command shows your key here, then clears the screen." \
    "Passage à vide : la vraie commande affiche ici votre clé, puis efface l’écran."
  dire ""
  consigne_runpod 2
  demander_pod
  if [ -n "$POD" ]; then sonder; fi
  printf '\n%s✓%s %s\n' "$VERT" "$RAZ" "$(tx 'Dry run finished: nothing was written or started.' \
    'Passage à vide terminé : rien n’a été écrit ni démarré.')"
  exit 0
fi
if [ -z "$POD_CONNU" ] || ! garder_pod; then
  consigne_runpod 1
  montrer_cle
  consigne_runpod 2
  demander_pod
fi
garder_etat
titre 3 "Waiting for your GPU" "Attente de votre GPU"
attendre
titre 4 "Starting the worker" "Démarrage du worker"
lier
resume
