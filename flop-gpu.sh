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
#   dès la consigne montrée, toute sortie autre que 0 rappelle que le pod, s'il a été créé, se paie jusqu'à Stop puis
#   Terminate dans la console.
# Langue : anglais par défaut ; FLOP_GPU_LANG=fr passe au français, retenu dans flop-gpu.etat
#   (FLOP_GPU_LANG=en revient à l'anglais).
# Dérogations : FLOP_MINER_DIR (/opt/flop-miner), FLOP_RUNPOD_TEMPLATE (tipfc9vtff), FLOP_GPU_ATTENTE_MIN (40).
# Sorties : 0 fait ; 2 VPS pas prêt ou usage ; 3 politique ; 6 pod (identifiant, modèle, clé ou politique non
#           corrigée) ; 7 délai dépassé ; 8 worker ou nom public ; 130 interrompu.
# shellcheck disable=SC1112,SC2059 # apostrophes typographiques voulues ; PROXY et les formats choisis par tx sont printf
{ set +xv; } 2>/dev/null # bash -x imprimerait la clé : la trace est coupée d'office
unset BASH_XTRACEFD
set -Eeuo pipefail
umask 077
export LC_ALL=C

VERSION=0.3.3
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
    echo "flop-gpu: FLOP_GPU_LANG must be en or fr / FLOP_GPU_LANG doit valoir en ou fr" >&2
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
M_ERR=$(tx 'flop-gpu: unexpected error (line %s)' 'flop-gpu : erreur inattendue (ligne %s)')

A_VIDE=0
case "${1:-}" in
  "") ;;
  --a-vide | --dry-run) A_VIDE=1 ;;
  -h | --aide | --help)
    if [ "$LANGUE" = fr ]; then
      sed -n '29,54p' "$0" 2>/dev/null || true
    else
      sed -n '2,27p' "$0" 2>/dev/null || true
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

dire() { printf '%s\n' "$*"; } # une donnée telle quelle (politique, empreinte, ligne vide)
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
  printf "$(tx 'If it was created, your RunPod pod%s is billed by the hour until you Stop then Terminate it in the RunPod console (Pods).' \
    'S’il a été créé, votre pod RunPod%s se paie à l’heure jusqu’à Stop puis Terminate dans la console RunPod (Pods).')\n" \
    "${POD:+ $POD}" >&2
}
effacer_cle() { # si la clé est à l'écran : écran puis historique effacés, dans cet ordre ; le drapeau ne tombe
  # qu'après, pour qu'un signal reçu entre les deux efface encore (deux effacements ne gênent pas)
  if [ "$CLE_ECRAN" = 1 ]; then
    { printf '\033[H\033[2J\033[3J' >/dev/tty; } 2>/dev/null || true
    CLE_ECRAN=0
  fi
}
die() { # die <code> <message anglais> <message français> ; sans français, l'anglais (jamais « unbound variable »)
  local c=$1
  effacer_cle
  if [ "$LANGUE" = fr ]; then printf 'flop-gpu : %s\n' "${3:-$2}"; else printf 'flop-gpu: %s\n' "$2"; fi | masque >&2
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
  printf '\n%s\n' "$(tx 'Interrupted.' 'Interrompu.')" >&2
  rappel
  exit 130
}
trap fin EXIT
trap interrompu INT TERM HUP
trap 'trap - ERR; effacer_cle; printf "$M_ERR\n" "$LINENO" >&2; rappel' ERR

preparer() {
  local o
  [ "$(id -u)" = 0 ] || die 2 "run the command as root (type sudo -i first)" \
    "lancez la commande en root (tapez d’abord sudo -i)"
  for o in curl jq awk flock timeout docker stty; do
    command -v "$o" >/dev/null 2>&1 || die 2 "missing tool: $o (step 2 of the guide)" "outil absent : $o (étape 2 du guide)"
  done
  docker compose version >/dev/null 2>&1 || die 2 "docker compose is missing (step 2 of the guide)" \
    "docker compose absent (étape 2 du guide)"
  [ -f "$ENVF" ] && [ -x "$DIR/decode-policy.sh" ] && [ -f "$DIR/docker-compose.miner.yml" ] &&
    [ -f "$DIR/docker-compose.tls.yml" ] || die 2 "$DIR is not ready: do steps 3 to 5 of the guide first" \
    "$DIR n’est pas prêt : faites d’abord les étapes 3 à 5 du guide"
  [[ $TEMPLATE_ID =~ ^[A-Za-z0-9_-]{1,64}$ ]] || die 2 "invalid RunPod template ID: $TEMPLATE_ID" \
    "identifiant de template RunPod invalide : $TEMPLATE_ID"
  { : </dev/tty; } 2>/dev/null || die 2 "no terminal: run the command in a terminal, to answer its questions" \
    "aucun terminal : lancez la commande dans un terminal, pour y répondre"
  if [ "$A_VIDE" = 0 ]; then
    exec 9>"$DIR/.flop-gpu.verrou"
    flock -n 9 || die 2 "the command is already running in another terminal" \
      "la commande tourne déjà dans un autre terminal"
  fi
  MH=$(lire MODEL_HASH | tr 'A-F' 'a-f')
  [[ $MH =~ ^0x[0-9a-f]{64}$ ]] || die 2 "MODEL_HASH unreadable in miner.env (step 3 of the guide)" \
    "MODEL_HASH illisible dans miner.env (étape 3 du guide)"
  INF=$(lire INFERENCE_API_KEY)
  if ! [[ $INF =~ ^[A-Za-z0-9._~+/=-]{16,256}$ ]]; then
    INF=""
    die 2 "INFERENCE_API_KEY empty or invalid in miner.env (step 4 of the guide)" \
      "INFERENCE_API_KEY vide ou invalide dans miner.env (étape 4 du guide)"
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
  local ip
  NOM_HTTPS=$(lire SESSION_PUBLIC_HOST)
  if [ -n "$NOM_HTTPS" ] && [[ $NOM_HTTPS != *.sslip.io ]]; then
    msg "Worker HTTPS name: $NOM_HTTPS (already in miner.env, kept)." \
      "Nom HTTPS du worker : $NOM_HTTPS (déjà dans miner.env, gardé)."
  else
    ip=$(ip_publique) || die 8 \
      "no public IPv4 address found: write SESSION_PUBLIC_HOST=<DNS name of this VPS> in miner.env, then run the \
command again. Nothing else is done." \
      "aucune adresse IPv4 publique trouvée : écrivez SESSION_PUBLIC_HOST=<nom DNS de ce VPS> \
dans miner.env, puis relancez. Rien d’autre n’est fait."
    NOM_HTTPS=${ip//./-}.sslip.io
    msg "Worker HTTPS name: $NOM_HTTPS (check that these numbers are the IP address of your VPS)." \
      "Nom HTTPS du worker : $NOM_HTTPS (vérifiez que ces chiffres sont l’adresse IP de votre VPS)."
  fi
  [[ $NOM_HTTPS =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]] ||
    die 8 "SESSION_PUBLIC_HOST is not a lowercase DNS name: $NOM_HTTPS. Nothing else is done." \
      "SESSION_PUBLIC_HOST n’est pas un nom DNS en minuscules : $NOM_HTTPS. Rien d’autre n’est fait."
}

politique() {
  local v=() err
  if [ "$A_VIDE" = 1 ]; then
    msg "Dry run: decode-policy.sh is not run, the policy read is the one in miner.env." \
      "Passage à vide : decode-policy.sh n’est pas lancé, la politique lue est celle de miner.env."
  else
    msg "Decoding policy: ./decode-policy.sh miner.env (FLOP package)…" \
      "Politique de décodage : ./decode-policy.sh miner.env (paquet FLOP)…"
    [ -z "$(lire FLOP_CLI)" ] || v+=("FLOP_CLI=$(lire FLOP_CLI)")
    [ -z "$(lire FLOP_RPC)" ] || v+=("FLOP_RPC=$(lire FLOP_RPC)")
    if ! err=$(decode_policy "${v[@]+"${v[@]}"}"); then
      if [ -n "$POL" ]; then # la chaîne a pu retirer la politique écrite : on reprend celle que FLOP publie
        msg "The policy in miner.env is refused: the command takes the one FLOP publishes instead." \
          "La politique de miner.env est refusée : la commande reprend celle que FLOP publie."
        vider_politique
        err=$(decode_policy "${v[@]+"${v[@]}"}") || {
          printf '%s\n' "$err" | sed -E "s/(0x)?[0-9a-fA-F]{64}/$M_EMP_ERR/g; s/[{].*\$/$M_POL/" | masque >&2
          die 3 "decode-policy.sh refused the policy, or the FLOP network did not answer within 5 min: nothing else is done" \
            "decode-policy.sh a refusé la politique, ou le réseau FLOP n’a pas répondu en 5 min : rien d’autre n’est fait"
        }
      else
        printf '%s\n' "$err" | sed -E "s/(0x)?[0-9a-fA-F]{64}/$M_EMP_ERR/g; s/[{].*\$/$M_POL/" | masque >&2
        die 3 "decode-policy.sh refused the policy, or the FLOP network did not answer within 5 min: nothing else is done" \
          "decode-policy.sh a refusé la politique, ou le réseau FLOP n’a pas répondu en 5 min : rien d’autre n’est fait"
      fi
    fi
  fi
  lire_politique
  if ! { [[ $PH =~ ^0x[0-9a-f]{64}$ ]] && printf '%s' "$POL" | jq -e 'type == "object"' >/dev/null 2>&1; }; then
    if [ "$A_VIDE" = 1 ]; then
      msg "Dry run: no policy in miner.env yet; the real command runs decode-policy.sh." \
        "Passage à vide : pas encore de politique dans miner.env ; la vraie commande lance decode-policy.sh."
    else
      die 3 "no decoding policy in miner.env after decode-policy.sh: nothing else is done" \
        "pas de politique de décodage dans miner.env après decode-policy.sh : rien d’autre n’est fait"
    fi
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
  dire ""
  msg "Which provider do you rent your GPU from?" "Chez quel fournisseur louez-vous votre GPU ?"
  dire "  1) RunPod"
  for _ in 1 2 3; do
    vider_tty
    printf '%s' "$(tx 'GPU provider (Enter for RunPod): ' 'Fournisseur de GPU (Entrée pour RunPod) : ')" >/dev/tty
    IFS= read -r -s r </dev/tty || r=""
    printf '\n' >/dev/tty
    case ${r//[[:space:]]/} in
      "" | 1 | "&") # & : la touche 1 d'un clavier AZERTY, sans Maj (recette réelle du 18/11)
        FOURNISSEUR=runpod
        msg "Provider: RunPod." "Fournisseur : RunPod."
        return 0
        ;;
    esac
    msg "Press Enter: only RunPod is offered for now (QuickPod and Vast will come later)." \
      "Appuyez sur Entrée : seul RunPod est proposé pour l’instant (QuickPod et Vast viendront ensuite)."
  done
  die 2 "no provider chosen" "aucun fournisseur choisi"
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
  dire ""
  msg "RunPod pod of this VPS, from a previous run: $POD_CONNU." \
    "Pod RunPod de ce VPS, d’après un passage précédent : $POD_CONNU."
  for _ in 1 2 3; do
    vider_tty
    printf '%s' "$(tx 'Press Enter to keep this pod, n to enter a new one: ' \
      'Entrée pour garder ce pod, n pour en donner un nouveau : ')" >/dev/tty
    IFS= read -r -s r </dev/tty || r=""
    printf '\n' >/dev/tty
    r=${r//[[:space:]]/}
    case ${r,,} in
      "" | o | oui | y | yes)
        POD=$POD_CONNU
        msg "Pod kept: $POD." "Pod gardé : $POD."
        return 0
        ;;
      n | non | no)
        msg "Pod $POD_CONNU is billed while it runs: if you no longer need it, Stop, then Terminate it in the RunPod \
console." "Le pod $POD_CONNU se paie tant qu’il tourne : s’il ne sert plus, Stop, puis Terminate dans la console RunPod."
        return 1
        ;;
    esac
    msg "Answer with Enter (this pod is kept) or n (you enter a new one)." \
      "Répondez par Entrée (ce pod est gardé) ou par n (vous en donnez un nouveau)."
  done
  die 2 "answer not understood: run the command again" "réponse non comprise : relancez la commande"
}

consigne_runpod() { # 1 : où coller la clé ; 2 : la carte, Deploy et l'identifiant (après la clé, l'écran effacé)
  RAPPEL=1 # dès ici, le lecteur a pu créer un pod
  if [ "$1" = 1 ] && [ "$LANGUE" = fr ]; then
    cat <<EOF

Dans votre navigateur, ouvrez ce lien (la recherche de la console RunPod ne trouve pas le template) :
  https://console.runpod.io/hub/template/$TEMPLATE_ID
Le template public « FLOP GPU devnet » porte déjà l’image de FLOP, le disque, le port 8000, le modèle et la politique
publiée ; il ne lui manque que votre clé d’inférence :
  - cliquez Configure Pod, puis Set overrides, et ouvrez Environment variables ;
  - cliquez Add Environment variable : nom INFERENCE_API_KEY, valeur la clé que la commande va afficher, sans toucher
    aux autres lignes ; puis Set overrides, en bas de la fenêtre. Sans cette variable, le pod redémarre en boucle et
    se paie jusqu’à ce que vous le supprimiez.
EOF
  elif [ "$1" = 1 ]; then
    cat <<EOF

In your browser, open this link (the RunPod console's search does not find the template):
  https://console.runpod.io/hub/template/$TEMPLATE_ID
The public template "FLOP GPU devnet" already has FLOP's image, the disk, port 8000, the model and the published
policy; all it lacks is your inference key:
  - click Configure Pod, then Set overrides, and open Environment variables;
  - click Add Environment variable: name INFERENCE_API_KEY, value the key the command is about to show, without
    touching the other lines; then Set overrides, at the bottom of the window. Without this variable, the pod
    restarts in a loop and is billed until you delete it.
EOF
  elif [ "$LANGUE" = fr ]; then
    cat <<EOF

Puis, dans la même page RunPod :
  - GPU : une carte disponible du guide (NVIDIA, 16 Go ou plus, RTX 30 ou plus récente, ou l’A40 ; 24 Go suffisent),
    en CUDA 13.0 à 13.4. Le template règle ce filtre, mais passer le cloud à Community dans Filter le remet à « Any » :
    recochez 13.0 à 13.4 ;
  - cliquez Deploy Pod : le pod se paie à l’heure dès lors, jusqu’à Stop, puis Terminate dans la console (Pods). Si le
    bouton dit Deploy when available, la carte n’est pas libre : choisissez-en une autre.
Son identifiant se lit ensuite dans la console RunPod (Pods), ou dans son adresse
https://<identifiant>-8000.proxy.runpod.net : la commande s’en sert pour joindre votre GPU.
EOF
  else
    cat <<EOF

Then, on the same RunPod page:
  - GPU: an available card from the guide (NVIDIA, 16 GB or more, RTX 30 series or newer, or the A40; 24 GB is
    enough), with CUDA 13.0 to 13.4. The template sets this filter, but switching the cloud to Community in Filter
    resets it to "Any": tick 13.0 to 13.4 again;
  - click Deploy Pod: from then on the pod is billed by the hour, until Stop, then Terminate in the console (Pods).
    If the button says Deploy when available, that card is not available right now: choose another one.
The pod's ID then shows in the RunPod console (Pods), or in its address
https://<ID>-8000.proxy.runpod.net: the command uses it to reach your GPU.
EOF
  fi
}

montrer_cle() { # INFERENCE_API_KEY seule sur sa ligne, sur Entrée ; écran et historique effacés une fois collée
  dire ""
  msg "The key about to be shown is the password between your worker and your GPU: do not show it to anyone." \
    "La clé qui va s’afficher est le mot de passe entre votre worker et votre GPU : ne la montrez à personne."
  msg "As soon as you have pasted it in RunPod, the screen and its scrollback will be cleared." \
    "Dès que vous l’aurez collée dans RunPod, l’écran et son historique s’effaceront."
  vider_tty
  printf '%s' "$(tx 'Press Enter to show the key: ' 'Entrée pour afficher la clé : ')" >/dev/tty
  IFS= read -r -s _ </dev/tty || die 2 "terminal closed: the key is not shown" "terminal fermé : la clé n’est pas affichée"
  printf '\n' >/dev/tty
  CLE_ECRAN=1 # dès ici, toute sortie efface l'écran (effacer_cle : die, interrompu, piège ERR, fin)
  printf '%s\n' "$INF" >/dev/tty
  vider_tty
  printf '%s' "$(tx 'Copy it into the value of INFERENCE_API_KEY, confirm in RunPod, then press Enter once the key is pasted: ' \
    'Copiez-la dans la valeur de INFERENCE_API_KEY, validez dans RunPod, puis Entrée une fois la clé collée : ')" >/dev/tty
  IFS= read -r -s _ </dev/tty || :
  effacer_cle
  msg "Key pasted: the screen and its scrollback have been cleared." \
    "Clé collée : l’écran et son historique ont été effacés."
}

demander_pod() { # POD : l'identifiant tapé, ou tiré de l'adresse du proxy ; lu sans écho, réaffiché une fois validé
  local saisie="" adresse='^(https?://)?([a-z0-9]{6,40})-[0-9]{2,5}\.proxy\.runpod\.net(/[^[:space:]]*)?$'
  POD=""
  for _ in 1 2 3; do
    vider_tty
    if [ "$A_VIDE" = 0 ]; then
      printf '%s' "$(tx 'Pod ID (or its address https://…-8000.proxy.runpod.net), then Enter: ' \
        'Identifiant du pod (ou son adresse https://…-8000.proxy.runpod.net), puis Entrée : ')" >/dev/tty
    elif [ -n "$POD_CONNU" ]; then
      printf "$(tx 'Pod ID to check once (Enter: %s): ' 'Identifiant du pod à sonder une fois (Entrée : %s) : ')" \
        "$POD_CONNU" >/dev/tty
    else
      printf '%s' "$(tx 'Pod ID to check once (Enter to skip): ' \
        'Identifiant du pod à sonder une fois (Entrée pour passer) : ')" >/dev/tty
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
      msg "This is your inference key: it goes in the INFERENCE_API_KEY variable of the RunPod page, and the command \
does not show it. Here, type the ID of your pod, read in the RunPod console (Pods)." \
        "C’est votre clé d’inférence : elle va dans la variable INFERENCE_API_KEY de la page RunPod, et la commande \
ne l’affiche pas. Ici, tapez l’identifiant de votre pod, lu dans la console RunPod (Pods)."
      continue
    fi
    if [[ $saisie =~ ^[a-z0-9]{6,40}$ ]]; then
      POD=$saisie
    elif [[ $saisie =~ $adresse ]]; then
      POD=${BASH_REMATCH[2]}
    fi
    if [ -n "$POD" ]; then
      msg "Pod: $POD." "Pod : $POD."
      return 0
    fi
    if [ -z "$saisie" ]; then
      msg "Nothing was typed." "Rien n’a été tapé."
    else
      msg "This is not a RunPod pod ID (lowercase letters and digits, read in the console, Pods); what you typed is \
not shown." "Ce n’est pas un identifiant de pod RunPod (lettres minuscules et chiffres, lus dans la console, Pods) ; \
la saisie n’est pas réaffichée."
    fi
  done
  die 6 "no valid pod ID in three tries: run the command again once the pod is deployed" \
    "aucun identifiant de pod valide en trois essais : relancez la commande une fois le pod déployé"
}

garder_etat() { # flop-gpu.etat : FOURNISSEUR=, POD= et FLOP_GPU_LANG= (la langue du passage), écrits d'un seul
  # coup, mode 600 ; aucun secret
  ETAT_TMP=$(mktemp "$ETAT.XXXXXX")
  printf 'FOURNISSEUR=%s\nPOD=%s\nFLOP_GPU_LANG=%s\n' "$FOURNISSEUR" "$POD" "$LANGUE" >"$ETAT_TMP"
  chmod 600 "$ETAT_TMP"
  mv -f "$ETAT_TMP" "$ETAT"
  ETAT_TMP=""
}

etat_sante() { # $1 code HTTP de /health, $2 model_identity
  case $1 in
    200) msg "model being measured (${2:-?})" "modèle en cours de mesure (${2:-?})" ;;
    000) msg "not reachable yet" "pas encore joignable" ;;
    401) msg "key refused (HTTP 401)" "clé refusée (HTTP 401)" ;;
    404 | 502 | 503 | 504 | 520 | 521 | 522 | 523 | 524) msg "starting (HTTP $1)" "en démarrage (HTTP $1)" ;;
    *) echo "HTTP $1" ;;
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
  msg "Dry run: /health of pod $POD: $e." "Passage à vide : /health du pod $POD : $e."
}

montrer_politique() { # le pod sert une autre politique : celle de miner.env et son empreinte (publiques), à mettre
  # dans le pod par Edit Pod ; Entrée une fois remplacées
  dire ""
  msg "Pod $POD serves the right model, but not the decoding policy in miner.env (policy_ok false): FLOP has \
changed it since the template was created." \
    "Le pod $POD sert le bon modèle, mais pas la politique de décodage de miner.env (policy_ok false) : FLOP l’a \
changée depuis la création du template."
  msg "In the RunPod console (Pods), click the three-dot menu of this pod, then Edit Pod, then Environment Variables: \
replace the values of DECODE_POLICY and DECODE_POLICY_HASH with the lines below, which are public, without touching \
the other variables, then click Save: the pod restarts." \
    "Dans la console RunPod (Pods), ouvrez le menu ⋮ de ce pod, cliquez Edit Pod, puis Environment Variables : \
remplacez les valeurs de DECODE_POLICY et de DECODE_POLICY_HASH par les lignes ci-dessous, publiques, sans toucher \
aux autres variables, puis cliquez Save : le pod redémarre."
  msg "Value of DECODE_POLICY:" "Valeur de DECODE_POLICY :"
  dire "$POL"
  msg "Value of DECODE_POLICY_HASH:" "Valeur de DECODE_POLICY_HASH :"
  dire "$(lire DECODE_POLICY_HASH)"
  vider_tty
  printf '%s' "$(tx 'Press Enter once the policy is replaced: ' 'Entrée une fois la politique remplacée : ')" >/dev/tty
  IFS= read -r -s _ </dev/tty || :
  printf '\n' >/dev/tty
}

attendre() { # /health toutes les PAS s jusqu'à la limite : retour au premier model_ok et policy_ok vrais, mesurés.
  # 404 trois minutes d'affilée : le conseil, une fois ; autre modèle mesuré : sortie 6 (garde F5 : jamais avant la
  # mesure) ; 401 : la clé réaffichée (montrer_cle), autre politique : montrer_politique, chacun une fois par passage,
  # puis la limite repart pour ATTENTE_MIN ; ensuite, le même refus 3 min d'affilée depuis l'Entrée (tout autre code,
  # dont un code de redémarrage, remet le compte à zéro) : sortie 6, avec son remède ; limite dépassée : sortie 7, dont
  # la fin suit le dernier état lu (un refus : son remède ; sinon le conseil)
  local debut limite maint ident okm okp refus etat_gpu ligne dernier="" vu=0 d404=0 dit404=0 cle_vue=0 pol_vue=0
  local t_cle=0 t_pol=0 conseil remede_cle remede_pol
  conseil=$(tx "check the pod ID, that the pod is running, and its logs (console, Logs): \"INFERENCE_API_KEY is \
required\" means the variable is missing, \"cuda>=13.0\" a host with the wrong CUDA." \
    "vérifiez l’identifiant, que le pod tourne, et ses journaux (console, Logs) : « INFERENCE_API_KEY is \
required » veut dire la variable oubliée, « cuda>=13.0 » un hôte au mauvais CUDA.")
  remede_cle=$(tx "in the RunPod console (Pods), click the three-dot menu of this pod, then Edit Pod: check that \
INFERENCE_API_KEY holds the key shown, whole and without spaces, and that the change is saved; then run the command \
again, which will show the key again." \
    "dans la console RunPod (Pods), ouvrez le menu ⋮ de ce pod, cliquez Edit Pod : vérifiez que INFERENCE_API_KEY \
porte la clé affichée, entière et sans espace, et que la modification est enregistrée ; puis relancez la commande, \
qui remontrera la clé.")
  remede_pol=$(tx "in the RunPod console (Pods), click the three-dot menu of this pod, then Edit Pod: check that \
DECODE_POLICY and DECODE_POLICY_HASH hold the values shown, whole, and that the change is saved; then run the command \
again, which will show the policy again." \
    "dans la console RunPod (Pods), ouvrez le menu ⋮ de ce pod, cliquez Edit Pod : vérifiez que DECODE_POLICY et \
DECODE_POLICY_HASH portent les valeurs affichées, entières, et que la modification est enregistrée ; puis relancez la \
commande, qui remontrera la politique.")
  debut=$(date +%s)
  limite=$((debut + ATTENTE_MIN * 60))
  msg "Waiting for the GPU, $ATTENTE_MIN min at most: the first start downloads about 9 GB of image, then the model." \
    "Attente du GPU, $ATTENTE_MIN min au plus : le premier démarrage télécharge environ 9 Go d’image, puis le modèle."
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
          [ "$okm" = true ] || die 6 "model_ok false: the GPU serves another model than the one in miner.env, the \
template is out of date. Delete the pod (Stop, then Terminate) and tell the author of the guide." \
            "model_ok false : le GPU sert un autre modèle que celui de miner.env, le template \
n’est plus à jour. Supprimez le pod (Stop, puis Terminate) et prévenez l’auteur du guide."
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
          msg "Pod $POD refuses the key in miner.env (HTTP 401): its INFERENCE_API_KEY variable holds another \
value. In the RunPod console (Pods), click the three-dot menu of this pod, then Edit Pod, then Environment Variables: \
replace the value of INFERENCE_API_KEY with the key the command is about to show, without touching the other \
variables, then click Save: the pod restarts." \
            "Le pod $POD refuse la clé de miner.env (HTTP 401) : sa variable INFERENCE_API_KEY porte une autre \
valeur. Dans la console RunPod (Pods), ouvrez le menu ⋮ de ce pod, cliquez Edit Pod, puis Environment Variables : \
remplacez la valeur de INFERENCE_API_KEY par la clé que la commande va afficher, sans toucher aux autres variables, \
puis cliquez Save : le pod redémarre."
          montrer_cle
          t_cle=$(date +%s)
          limite=$((t_cle + ATTENTE_MIN * 60))
          msg "Waiting again, $ATTENTE_MIN min at most: the pod restarts with the key in miner.env." \
            "L’attente reprend, $ATTENTE_MIN min au plus : le pod redémarre avec la clé de miner.env."
          continue
        fi
        [ $((maint - t_cle)) -lt 180 ] || die 6 "pod $POD still refuses the key in miner.env (HTTP 401) after 3 min: \
$remede_cle" "le pod $POD refuse toujours la clé de miner.env (HTTP 401) depuis \
3 min : $remede_cle"
        ;;
      politique)
        if [ "$pol_vue" = 0 ]; then
          pol_vue=1
          montrer_politique
          t_pol=$(date +%s)
          limite=$((t_pol + ATTENTE_MIN * 60))
          msg "Waiting again, $ATTENTE_MIN min at most: the pod restarts with the policy in miner.env." \
            "L’attente reprend, $ATTENTE_MIN min au plus : le pod redémarre avec la politique de miner.env."
          continue
        fi
        [ $((maint - t_pol)) -lt 180 ] || die 6 "pod $POD still serves a different decoding policy from miner.env \
after 3 min: $remede_pol" "le pod $POD sert toujours une autre politique de décodage que \
miner.env depuis 3 min : $remede_pol"
        ;;
    esac
    etat_gpu=$(etat_sante "$CODE_S" "$ident")
    if [ "$refus" = politique ]; then
      etat_gpu=$(tx "model measured, but not the decoding policy in miner.env" \
        "modèle mesuré, mais pas la politique de décodage de miner.env")
    fi
    ligne=$(tx "GPU: $etat_gpu" "GPU : $etat_gpu")
    if [ "$ligne" != "$dernier" ] || [ $((maint - vu)) -ge 60 ]; then
      printf '[%3d min %02d s] %s\n' $(((maint - debut) / 60)) $(((maint - debut) % 60)) "$ligne"
      dernier=$ligne vu=$maint
    fi
    if [ "$d404" != 0 ] && [ "$dit404" = 0 ] && [ $((maint - d404)) -ge 180 ]; then
      dit404=1
      msg "Pod $POD has answered 404 for 3 min: $conseil Still waiting." \
        "Depuis 3 min, le pod $POD répond 404 : $conseil L’attente continue."
    fi
    if [ "$maint" -ge "$limite" ]; then
      case $refus in
        cle) die 7 "the GPU is not ready after $(((maint - debut) / 60)) min, the pod still refuses the key in \
miner.env (HTTP 401): $remede_cle" "le GPU n’est pas prêt après $(((maint - debut) / 60)) min, le pod refuse toujours la clé de \
miner.env (HTTP 401) : $remede_cle" ;;
        politique) die 7 "the GPU is not ready after $(((maint - debut) / 60)) min, the pod still serves a different \
decoding policy from miner.env: $remede_pol" "le GPU n’est pas prêt après $(((maint - debut) / 60)) min, le pod sert toujours une autre \
politique de décodage que miner.env : $remede_pol" ;;
        *) die 7 "the GPU is not ready after $(((maint - debut) / 60)) min: $conseil" \
          "le GPU n’est pas prêt après $(((maint - debut) / 60)) min : $conseil" ;;
      esac
    fi
    sleep "$PAS"
  done
  msg "GPU ready: model_identity measured, model_ok true, policy_ok true." \
    "GPU prêt : model_identity measured, model_ok true, policy_ok true."
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
  msg "miner.env: OPENAI_BASE_URL and SESSION_PUBLIC_HOST written. Starting the worker, as in step 7…" \
    "miner.env : OPENAI_BASE_URL et SESSION_PUBLIC_HOST écrits. Démarrage du worker, comme à l’étape 7…"
  (cd "$DIR" && "${c[@]}" pull && "${c[@]}" up -d) ||
    die 8 "the worker failed to start: cd $DIR, then docker compose --env-file miner.env -f docker-compose.miner.yml \
-f docker-compose.tls.yml logs" "le démarrage du worker a échoué : cd $DIR, puis docker compose --env-file miner.env -f docker-compose.miner.yml \
-f docker-compose.tls.yml logs"
}

resume() {
  if [ "$LANGUE" = fr ]; then
    cat <<EOF

C’est fait : votre GPU RunPod sert votre worker FLOP.
- Pod RunPod : $POD, à l’adresse $(printf "$PROXY" "$POD").
- Il se paie à l’heure tant qu’il tourne, même worker arrêté. Pour arrêter de payer : console RunPod, Pods, ce pod,
  Stop, puis Terminate (corbeille).
- Crédit RunPod : à 0 \$, RunPod supprime ce pod (il n’a pas de volume) et le worker perd son GPU. Activez la
  recharge automatique ou une alerte de solde (Billing).
- Relancer cette commande propose de garder ce pod, ou d’en donner un nouveau.
- Pour l’étape 8 du guide, collez d’abord ces trois lignes :
    cd $DIR
    C="docker compose --env-file miner.env -f docker-compose.miner.yml -f docker-compose.tls.yml"
    NAME="\$(sed -n 's/^SESSION_PUBLIC_HOST=//p' miner.env)"; echo "\$NAME"
EOF
  else
    cat <<EOF

Done: your RunPod GPU now serves your FLOP worker.
- RunPod pod: $POD, at $(printf "$PROXY" "$POD").
- It is billed by the hour while it runs, even with the worker stopped. To stop paying: RunPod console, Pods, this
  pod, Stop, then Terminate (trash icon).
- RunPod credit: at \$0, RunPod deletes this pod (it has no volume) and the worker loses its GPU. Turn on
  Auto-pay or a Low balance alert (Billing).
- Running this command again offers to keep this pod, or to enter a new one.
- For step 8 of the guide, first paste these three lines:
    cd $DIR
    C="docker compose --env-file miner.env -f docker-compose.miner.yml -f docker-compose.tls.yml"
    NAME="\$(sed -n 's/^SESSION_PUBLIC_HOST=//p' miner.env)"; echo "\$NAME"
EOF
  fi
}

stty -echo 2>/dev/null </dev/tty || true # rien de ce qui se tape ne s'affiche, pas même une clé collée trop tôt
msg "flop-gpu $VERSION: links your GPU to your FLOP worker (steps 6 and 7 of the guide)." \
  "flop-gpu $VERSION : relie votre GPU à votre worker FLOP (étapes 6 et 7 du guide)."
preparer
nom_https
politique
choisir_fournisseur
lire_etat
if [ "$A_VIDE" = 1 ]; then
  consigne_runpod 1
  msg "(Dry run: the real command shows your INFERENCE_API_KEY here, when you ask for it, then clears the screen.)" \
    "(Passage à vide : la vraie commande affiche ici votre INFERENCE_API_KEY, quand vous le demandez, puis efface \
l’écran.)"
  consigne_runpod 2
  demander_pod
  if [ -n "$POD" ]; then sonder; fi
  msg "Dry run finished: nothing was written or started." "Passage à vide terminé : rien n’a été écrit ni démarré."
  exit 0
fi
if [ -z "$POD_CONNU" ] || ! garder_pod; then
  consigne_runpod 1
  montrer_cle
  consigne_runpod 2
  demander_pod
fi
garder_etat
attendre
lier
resume
