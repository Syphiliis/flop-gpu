#!/usr/bin/env bash
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
# Dérogations : FLOP_MINER_DIR (/opt/flop-miner), FLOP_RUNPOD_TEMPLATE (tipfc9vtff), FLOP_GPU_ATTENTE_MIN (40).
# Sorties : 0 fait ; 2 VPS pas prêt ou usage ; 3 politique ; 6 pod (identifiant, modèle, clé ou politique non
#           corrigée) ; 7 délai dépassé ; 8 worker ou nom public ; 130 interrompu.
# shellcheck disable=SC1112,SC2059 # apostrophes typographiques voulues ; PROXY est un format printf (%s : le pod)
{ set +xv; } 2>/dev/null # bash -x imprimerait la clé : la trace est coupée d'office
unset BASH_XTRACEFD
set -Eeuo pipefail
umask 077
export LC_ALL=C

VERSION=0.3.2
DIR=${FLOP_MINER_DIR:-/opt/flop-miner}
ENVF=$DIR/miner.env
ETAT=$DIR/flop-gpu.etat # FOURNISSEUR= et POD= : aucun secret
TEMPLATE_ID=${FLOP_RUNPOD_TEMPLATE:-tipfc9vtff} # template public « FLOP GPU devnet » (lot K44)
ATTENTE_MIN=${FLOP_GPU_ATTENTE_MIN:-40}
[[ $ATTENTE_MIN =~ ^[0-9]{1,3}$ ]] && [ "$((10#$ATTENTE_MIN))" -ge 1 ] || ATTENTE_MIN=40
ATTENTE_MIN=$((10#$ATTENTE_MIN)) # 08 resterait de l'octal pour $(( ))
PROXY=https://%s-8000.proxy.runpod.net
PAS=20
IP_FORCEE=""

A_VIDE=0
case "${1:-}" in
  "") ;;
  --a-vide | --dry-run) A_VIDE=1 ;;
  -h | --aide | --help)
    sed -n '2,25p' "$0" 2>/dev/null || true
    exit 0
    ;;
  *)
    echo "usage : bash flop-gpu.sh [--a-vide]" >&2
    exit 2
    ;;
esac

INF="" POL="" PH="" MH="" NOM_HTTPS="" FOURNISSEUR="" POD="" POD_CONNU="" SANTE="" ENV_TMP="" ETAT_TMP=""
CODE_S=000 RAPPEL=0 CLE_ECRAN=0

dire() { printf '%s\n' "$*"; }
masque() { # aucun secret ne sort, même dans un message d'erreur de FLOP
  local l
  while IFS= read -r l || [ -n "$l" ]; do
    [ -z "$INF" ] || l=${l//"$INF"/[clé masquée]}
    [ -z "$POL" ] || l=${l//"$POL"/[politique masquée]}
    if [ -n "$PH" ]; then
      l=${l//"$PH"/[empreinte masquée]}
      l=${l//"${PH#0x}"/[empreinte masquée]}
    fi
    printf '%s\n' "$l"
  done
}
rappel() { # armé dès la consigne montrée (le lecteur a pu créer un pod) : toute sortie autre que 0 le dit
  [ "$RAPPEL" = 1 ] || return 0
  printf 'S’il a été créé, votre pod RunPod%s se paie à l’heure jusqu’à Stop puis Terminate dans la console RunPod (Pods).\n' \
    "${POD:+ $POD}" >&2
}
effacer_cle() { # si la clé est à l'écran : écran puis historique effacés, dans cet ordre ; le drapeau ne tombe
  # qu'après, pour qu'un signal reçu entre les deux efface encore (deux effacements ne gênent pas)
  if [ "$CLE_ECRAN" = 1 ]; then
    { printf '\033[H\033[2J\033[3J' >/dev/tty; } 2>/dev/null || true
    CLE_ECRAN=0
  fi
}
die() {
  local c=$1
  shift
  effacer_cle
  printf 'flop-gpu : %s\n' "$*" | masque >&2
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
  printf '\nInterrompu.\n' >&2
  rappel
  exit 130
}
trap fin EXIT
trap interrompu INT TERM HUP
trap 'trap - ERR; effacer_cle; printf "flop-gpu : erreur inattendue (ligne %s)\n" "$LINENO" >&2; rappel' ERR

lire() { # valeur de la ligne CLE= de miner.env, ou du fichier donné
  awk -v k="$1" 'index($0, k "=") == 1 { v = substr($0, length(k) + 2) } END { printf "%s", v }' "${2:-$ENVF}"
}
confirmer() { # vrai seulement sur o ou oui, tapé au terminal après la question (sans écho)
  local r=""
  vider_tty
  printf '%s [o/N] ' "$1" >/dev/tty
  IFS= read -r -s r </dev/tty || r=""
  printf '\n' >/dev/tty
  case $r in o | O | oui | Oui | OUI | y | Y | yes) return 0 ;; *) return 1 ;; esac
}

preparer() {
  local o
  [ "$(id -u)" = 0 ] || die 2 "lancez la commande en root (tapez d’abord sudo -i)"
  for o in curl jq awk flock timeout docker stty; do
    command -v "$o" >/dev/null 2>&1 || die 2 "outil absent : $o (étape 2 du guide)"
  done
  docker compose version >/dev/null 2>&1 || die 2 "docker compose absent (étape 2 du guide)"
  [ -f "$ENVF" ] && [ -x "$DIR/decode-policy.sh" ] && [ -f "$DIR/docker-compose.miner.yml" ] &&
    [ -f "$DIR/docker-compose.tls.yml" ] || die 2 "$DIR n’est pas prêt : faites d’abord les étapes 3 à 5 du guide"
  [[ $TEMPLATE_ID =~ ^[A-Za-z0-9_-]{1,64}$ ]] || die 2 "identifiant de template RunPod invalide : $TEMPLATE_ID"
  { : </dev/tty; } 2>/dev/null || die 2 "aucun terminal : lancez la commande dans un terminal, pour y répondre"
  if [ "$A_VIDE" = 0 ]; then
    exec 9>"$DIR/.flop-gpu.verrou"
    flock -n 9 || die 2 "la commande tourne déjà dans un autre terminal"
  fi
  MH=$(lire MODEL_HASH | tr 'A-F' 'a-f')
  [[ $MH =~ ^0x[0-9a-f]{64}$ ]] || die 2 "MODEL_HASH illisible dans miner.env (étape 3 du guide)"
  INF=$(lire INFERENCE_API_KEY)
  if ! [[ $INF =~ ^[A-Za-z0-9._~+/=-]{16,256}$ ]]; then
    INF=""
    die 2 "INFERENCE_API_KEY vide ou invalide dans miner.env (étape 4 du guide)"
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
    dire "Nom HTTPS du worker : $NOM_HTTPS (déjà dans miner.env, gardé)."
  else
    ip=$(ip_publique) || die 8 "aucune adresse IPv4 publique trouvée : écrivez SESSION_PUBLIC_HOST=<nom DNS de ce VPS> \
dans miner.env, puis relancez. Rien d’autre n’est fait."
    NOM_HTTPS=${ip//./-}.sslip.io
    dire "Nom HTTPS du worker : $NOM_HTTPS (vérifiez que ces chiffres sont l’adresse IP de votre VPS)."
  fi
  [[ $NOM_HTTPS =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]] ||
    die 8 "SESSION_PUBLIC_HOST n’est pas un nom DNS en minuscules : $NOM_HTTPS. Rien d’autre n’est fait."
}

politique() {
  local v=() err
  if [ "$A_VIDE" = 1 ]; then
    dire "Passage à vide : decode-policy.sh n’est pas lancé, la politique lue est celle de miner.env."
  else
    dire "Politique de décodage : ./decode-policy.sh miner.env (paquet FLOP)…"
    [ -z "$(lire FLOP_CLI)" ] || v+=("FLOP_CLI=$(lire FLOP_CLI)")
    [ -z "$(lire FLOP_RPC)" ] || v+=("FLOP_RPC=$(lire FLOP_RPC)")
    if ! err=$(decode_policy "${v[@]+"${v[@]}"}"); then
      if [ -n "$POL" ]; then # la chaîne a pu retirer la politique écrite : on reprend celle que FLOP publie
        dire "La politique de miner.env est refusée : la commande reprend celle que FLOP publie."
        vider_politique
        err=$(decode_policy "${v[@]+"${v[@]}"}") || {
          printf '%s\n' "$err" | sed -E 's/(0x)?[0-9a-fA-F]{64}/[empreinte]/g; s/[{].*$/[politique masquée]/' | masque >&2
          die 3 "decode-policy.sh a refusé la politique, ou le réseau FLOP n’a pas répondu en 5 min : rien d’autre n’est fait"
        }
      else
        printf '%s\n' "$err" | sed -E 's/(0x)?[0-9a-fA-F]{64}/[empreinte]/g; s/[{].*$/[politique masquée]/' | masque >&2
        die 3 "decode-policy.sh a refusé la politique, ou le réseau FLOP n’a pas répondu en 5 min : rien d’autre n’est fait"
      fi
    fi
  fi
  lire_politique
  if ! { [[ $PH =~ ^0x[0-9a-f]{64}$ ]] && printf '%s' "$POL" | jq -e 'type == "object"' >/dev/null 2>&1; }; then
    if [ "$A_VIDE" = 1 ]; then
      dire "Passage à vide : pas encore de politique dans miner.env ; la vraie commande lance decode-policy.sh."
    else
      die 3 "pas de politique de décodage dans miner.env après decode-policy.sh : rien d’autre n’est fait"
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
  dire "Chez quel fournisseur louez-vous votre GPU ?"
  dire "  1) RunPod"
  for _ in 1 2 3; do
    vider_tty
    printf 'Fournisseur de GPU (Entrée pour RunPod) : ' >/dev/tty
    IFS= read -r -s r </dev/tty || r=""
    printf '\n' >/dev/tty
    case ${r//[[:space:]]/} in
      "" | 1 | "&") # & : la touche 1 d'un clavier AZERTY, sans Maj (recette réelle du 18/11)
        FOURNISSEUR=runpod
        dire "Fournisseur : RunPod."
        return 0
        ;;
    esac
    dire "Appuyez sur Entrée : seul RunPod est proposé pour l’instant (QuickPod et Vast viendront ensuite)."
  done
  die 2 "aucun fournisseur choisi"
}

lire_etat() { # POD_CONNU : le pod que flop-gpu.etat garde pour ce fournisseur, s'il est bien formé
  local p
  [ -f "$ETAT" ] || return 0
  [ "$(lire FOURNISSEUR "$ETAT")" = "$FOURNISSEUR" ] || return 0
  p=$(lire POD "$ETAT")
  if [[ $p =~ ^[a-z0-9]{6,40}$ ]]; then POD_CONNU=$p; fi
}

garder_pod() { # vrai si le lecteur garde le pod connu de ce VPS (Entrée), faux s'il en donne un nouveau (n)
  local r=""
  RAPPEL=1 # ce pod a existé : il peut se payer encore
  dire ""
  dire "Pod RunPod de ce VPS, d’après un passage précédent : $POD_CONNU."
  for _ in 1 2 3; do
    vider_tty
    printf 'Entrée pour garder ce pod, n pour en donner un nouveau : ' >/dev/tty
    IFS= read -r -s r </dev/tty || r=""
    printf '\n' >/dev/tty
    case ${r//[[:space:]]/} in
      "" | o | O | oui | Oui | OUI)
        POD=$POD_CONNU
        dire "Pod gardé : $POD."
        return 0
        ;;
      n | N | non | Non | NON)
        dire "Le pod $POD_CONNU se paie tant qu’il tourne : s’il ne sert plus, Stop, puis Terminate dans la console RunPod."
        return 1
        ;;
    esac
    dire "Répondez par Entrée (ce pod est gardé) ou par n (vous en donnez un nouveau)."
  done
  die 2 "réponse non comprise : relancez la commande"
}

consigne_runpod() { # 1 : où coller la clé ; 2 : la carte, Deploy et l'identifiant (après la clé, l'écran effacé)
  RAPPEL=1 # dès ici, le lecteur a pu créer un pod
  if [ "$1" = 1 ]; then
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
  else
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
  fi
}

montrer_cle() { # INFERENCE_API_KEY seule sur sa ligne, sur Entrée ; écran et historique effacés une fois collée
  dire ""
  dire "La clé qui va s’afficher est le mot de passe entre votre worker et votre GPU : ne la montrez à personne."
  dire "Dès que vous l’aurez collée dans RunPod, l’écran et son historique s’effaceront."
  vider_tty
  printf 'Entrée pour afficher la clé : ' >/dev/tty
  IFS= read -r -s _ </dev/tty || die 2 "terminal fermé : la clé n’est pas affichée"
  printf '\n' >/dev/tty
  CLE_ECRAN=1 # dès ici, toute sortie efface l'écran (effacer_cle : die, interrompu, piège ERR, fin)
  printf '%s\n' "$INF" >/dev/tty
  vider_tty
  printf 'Copiez-la dans la valeur de INFERENCE_API_KEY, validez dans RunPod, puis Entrée une fois la clé collée : ' >/dev/tty
  IFS= read -r -s _ </dev/tty || :
  effacer_cle
  dire "Clé collée : l’écran et son historique ont été effacés."
}

demander_pod() { # POD : l'identifiant tapé, ou tiré de l'adresse du proxy ; lu sans écho, réaffiché une fois validé
  local saisie="" adresse='^(https?://)?([a-z0-9]{6,40})-[0-9]{2,5}\.proxy\.runpod\.net(/[^[:space:]]*)?$'
  POD=""
  for _ in 1 2 3; do
    vider_tty
    if [ "$A_VIDE" = 0 ]; then
      printf 'Identifiant du pod (ou son adresse https://…-8000.proxy.runpod.net), puis Entrée : ' >/dev/tty
    elif [ -n "$POD_CONNU" ]; then
      printf 'Identifiant du pod à sonder une fois (Entrée : %s) : ' "$POD_CONNU" >/dev/tty
    else
      printf 'Identifiant du pod à sonder une fois (Entrée pour passer) : ' >/dev/tty
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
      dire "C’est votre clé d’inférence : elle va dans la variable INFERENCE_API_KEY de la page RunPod, et la commande \
ne l’affiche pas. Ici, tapez l’identifiant de votre pod, lu dans la console RunPod (Pods)."
      continue
    fi
    if [[ $saisie =~ ^[a-z0-9]{6,40}$ ]]; then
      POD=$saisie
    elif [[ $saisie =~ $adresse ]]; then
      POD=${BASH_REMATCH[2]}
    fi
    if [ -n "$POD" ]; then
      dire "Pod : $POD."
      return 0
    fi
    if [ -z "$saisie" ]; then
      dire "Rien n’a été tapé."
    else
      dire "Ce n’est pas un identifiant de pod RunPod (lettres minuscules et chiffres, lus dans la console, Pods) ; \
la saisie n’est pas réaffichée."
    fi
  done
  die 6 "aucun identifiant de pod valide en trois essais : relancez la commande une fois le pod déployé"
}

garder_etat() { # flop-gpu.etat : FOURNISSEUR= et POD=, écrits d'un seul coup, mode 600 ; aucun secret
  ETAT_TMP=$(mktemp "$ETAT.XXXXXX")
  printf 'FOURNISSEUR=%s\nPOD=%s\n' "$FOURNISSEUR" "$POD" >"$ETAT_TMP"
  chmod 600 "$ETAT_TMP"
  mv -f "$ETAT_TMP" "$ETAT"
  ETAT_TMP=""
}

etat_sante() { # $1 code HTTP de /health, $2 model_identity
  case $1 in
    200) echo "modèle en cours de mesure (${2:-?})" ;;
    000) echo "pas encore joignable" ;;
    401) echo "clé refusée (HTTP 401)" ;;
    404 | 502 | 503 | 504 | 520 | 521 | 522 | 523 | 524) echo "en démarrage (HTTP $1)" ;;
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
  sante
  dire "Passage à vide : /health du pod $POD : $(etat_sante "$CODE_S" "$(printf '%s' "$SANTE" | jq -r '.model_identity // empty' \
    2>/dev/null || true)")."
}

montrer_politique() { # le pod sert une autre politique : celle de miner.env et son empreinte (publiques), à mettre
  # dans le pod par Edit Pod ; Entrée une fois remplacées
  dire ""
  dire "Le pod $POD sert le bon modèle, mais pas la politique de décodage de miner.env (policy_ok false) : FLOP l’a \
changée depuis la création du template."
  dire "Dans la console RunPod (Pods), ouvrez ce pod, cliquez Edit Pod, puis Environment Variables : remplacez les \
valeurs de DECODE_POLICY et de DECODE_POLICY_HASH par les lignes ci-dessous, publiques, sans toucher aux autres \
variables, puis enregistrez : le pod redémarre."
  dire "Valeur de DECODE_POLICY :"
  dire "$POL"
  dire "Valeur de DECODE_POLICY_HASH :"
  dire "$(lire DECODE_POLICY_HASH)"
  vider_tty
  printf 'Entrée une fois la politique remplacée : ' >/dev/tty
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
  conseil="vérifiez l’identifiant, que le pod tourne, et ses journaux (console, Logs) : « INFERENCE_API_KEY is \
required » veut dire la variable oubliée, « cuda>=13.0 » un hôte au mauvais CUDA."
  remede_cle="dans la console RunPod (Pods), ouvrez ce pod, Edit Pod : vérifiez que INFERENCE_API_KEY porte la clé \
affichée, entière et sans espace, et que la modification est enregistrée ; puis relancez la commande, qui remontrera \
la clé."
  remede_pol="dans la console RunPod (Pods), ouvrez ce pod, Edit Pod : vérifiez que DECODE_POLICY et \
DECODE_POLICY_HASH portent les valeurs affichées, entières, et que la modification est enregistrée ; puis relancez la \
commande, qui remontrera la politique."
  debut=$(date +%s)
  limite=$((debut + ATTENTE_MIN * 60))
  dire "Attente du GPU, $ATTENTE_MIN min au plus : le premier démarrage télécharge environ 9 Go d’image, puis le modèle."
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
          [ "$okm" = true ] || die 6 "model_ok false : le GPU sert un autre modèle que celui de miner.env, le template \
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
          dire "Le pod $POD refuse la clé de miner.env (HTTP 401) : sa variable INFERENCE_API_KEY porte une autre \
valeur. Dans la console RunPod (Pods), ouvrez ce pod, cliquez Edit Pod, puis Environment Variables : remplacez la \
valeur de INFERENCE_API_KEY par la clé que la commande va afficher, sans toucher aux autres variables, puis \
enregistrez : le pod redémarre."
          montrer_cle
          t_cle=$(date +%s)
          limite=$((t_cle + ATTENTE_MIN * 60))
          dire "L’attente reprend, $ATTENTE_MIN min au plus : le pod redémarre avec la clé de miner.env."
          continue
        fi
        [ $((maint - t_cle)) -lt 180 ] || die 6 "le pod $POD refuse toujours la clé de miner.env (HTTP 401) depuis \
3 min : $remede_cle"
        ;;
      politique)
        if [ "$pol_vue" = 0 ]; then
          pol_vue=1
          montrer_politique
          t_pol=$(date +%s)
          limite=$((t_pol + ATTENTE_MIN * 60))
          dire "L’attente reprend, $ATTENTE_MIN min au plus : le pod redémarre avec la politique de miner.env."
          continue
        fi
        [ $((maint - t_pol)) -lt 180 ] || die 6 "le pod $POD sert toujours une autre politique de décodage que \
miner.env depuis 3 min : $remede_pol"
        ;;
    esac
    etat_gpu=$(etat_sante "$CODE_S" "$ident")
    if [ "$refus" = politique ]; then etat_gpu="modèle mesuré, mais pas la politique de décodage de miner.env"; fi
    ligne="GPU : $etat_gpu"
    if [ "$ligne" != "$dernier" ] || [ $((maint - vu)) -ge 60 ]; then
      printf '[%3d min %02d s] %s\n' $(((maint - debut) / 60)) $(((maint - debut) % 60)) "$ligne"
      dernier=$ligne vu=$maint
    fi
    if [ "$d404" != 0 ] && [ "$dit404" = 0 ] && [ $((maint - d404)) -ge 180 ]; then
      dit404=1
      dire "Depuis 3 min, le pod $POD répond 404 : $conseil L’attente continue."
    fi
    if [ "$maint" -ge "$limite" ]; then
      case $refus in
        cle) die 7 "le GPU n’est pas prêt après $(((maint - debut) / 60)) min, le pod refuse toujours la clé de \
miner.env (HTTP 401) : $remede_cle" ;;
        politique) die 7 "le GPU n’est pas prêt après $(((maint - debut) / 60)) min, le pod sert toujours une autre \
politique de décodage que miner.env : $remede_pol" ;;
        *) die 7 "le GPU n’est pas prêt après $(((maint - debut) / 60)) min : $conseil" ;;
      esac
    fi
    sleep "$PAS"
  done
  dire "GPU prêt : model_identity measured, model_ok true, policy_ok true."
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
  dire "miner.env : OPENAI_BASE_URL et SESSION_PUBLIC_HOST écrits. Démarrage du worker, comme à l’étape 7…"
  (cd "$DIR" && "${c[@]}" pull && "${c[@]}" up -d) ||
    die 8 "le démarrage du worker a échoué : cd $DIR, puis docker compose --env-file miner.env -f docker-compose.miner.yml \
-f docker-compose.tls.yml logs"
}

resume() {
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
}

stty -echo 2>/dev/null </dev/tty || true # rien de ce qui se tape ne s'affiche, pas même une clé collée trop tôt
dire "flop-gpu $VERSION : relie votre GPU à votre worker FLOP (étapes 6 et 7 du guide)."
preparer
nom_https
politique
choisir_fournisseur
lire_etat
if [ "$A_VIDE" = 1 ]; then
  consigne_runpod 1
  dire "(Passage à vide : la vraie commande affiche ici votre INFERENCE_API_KEY, quand vous le demandez, puis efface \
l’écran.)"
  consigne_runpod 2
  demander_pod
  if [ -n "$POD" ]; then sonder; fi
  dire "Passage à vide terminé : rien n’a été écrit ni démarré."
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
