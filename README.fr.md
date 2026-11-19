# FLOP GPU : reliez votre GPU RunPod à votre worker FLOP, en une commande

Une commande, collée sur le VPS qui fait tourner votre worker FLOP (devnet). Vous louez le GPU vous-même dans la
console RunPod, depuis un template public ; la commande vous dit où cliquer, vous montre une fois votre clé d’inférence
pour que vous la colliez là-bas, attend que votre GPU serve le bon modèle avec la bonne politique de décodage, puis
écrit `miner.env` et démarre le worker. Aucune clé API RunPod, aucun accès à votre compte RunPod.

Outil communautaire non officiel : il n’est fait ni par FLOP Labs ni par RunPod. Il remplace les étapes 6 et 7 du guide
« Lancez votre Nœud GPU FLOP » de BreizhNode sur [Medium](https://medium.com/@breizh-node) : faites d’abord les étapes
qui les précèdent.

[Read in English](README.md). Version 0.3.3, 19 novembre 2026. La commande parle anglais par défaut ;
`FLOP_GPU_LANG=fr` la fait passer au français, et ce choix est retenu dans `flop-gpu.etat`.

## Avant de commencer

- **RunPod facture votre GPU à l’heure jusqu’à Stop, puis Terminate**, même si la commande s’arrête ou si votre worker
  est arrêté. La console affiche le prix à l’heure avant le déploiement : de 0,16 à 0,69 $ pour une carte qui convient
  le 14 novembre 2026, selon le stock (Community ou Secure Cloud), soit de 4 à 17 $ par jour. À 0 $ de crédit, RunPod
  supprime le pod et votre worker perd son GPU : activez la recharge automatique ou une alerte de solde (Billing).
- **Devnet seulement** : les jetons de test n’ont pas de valeur et il n’y a pas encore de récompenses.

## La lancer

Sur votre VPS, en root (tapez d’abord `sudo -i`), une fois `/opt/flop-miner` et son `miner.env` prêts :

```bash
curl -fsSL https://raw.githubusercontent.com/Syphiliis/flop-gpu/v0.3.3/flop-gpu.sh -o /root/flop-gpu.sh && FLOP_GPU_LANG=fr bash /root/flop-gpu.sh
```

Rien de ce que vous tapez ne s’affiche, c’est voulu. La commande :

1. affiche le nom HTTPS de votre worker et récupère la politique de décodage de FLOP ;
2. demande votre fournisseur de GPU : appuyez sur Entrée pour RunPod ;
3. donne le lien du template, `https://console.runpod.io/hub/template/tipfc9vtff` (la recherche de RunPod ne le trouve
   pas : passez par le lien). Dans la console : **Configure Pod**, **Set overrides**, **Environment variables**, **Add
   Environment variable**, nommée `INFERENCE_API_KEY` ;
4. affiche votre clé d’inférence quand vous appuyez sur Entrée. Collez-la comme valeur de la variable, cliquez **Set
   overrides**, puis Entrée : l’écran et son historique s’effacent ;
5. vous fait choisir une carte disponible (CUDA 13.0 à 13.4 dans **Filter**) et cliquer **Deploy Pod**, jamais **Deploy
   when available** ; puis demande l’identifiant du pod (console, **Pods**) ou son adresse
   `https://…-8000.proxy.runpod.net` ;
6. attend 40 minutes au plus, une ligne par minute, que le GPU soit prêt ; écrit `miner.env`, démarre le worker, et
   finit par votre pod, la façon d’arrêter de payer, et trois lignes à coller avant l’étape 8 du guide.

Pour voir les consignes sans rien changer : `FLOP_GPU_LANG=fr bash /root/flop-gpu.sh --a-vide`.

Si elle s’arrête en route (coupure SSH, fenêtre fermée, Ctrl+C), relancez `FLOP_GPU_LANG=fr bash /root/flop-gpu.sh` :
elle propose de garder le pod qu’elle connaît (Entrée), ou d’en donner un nouveau (`n`). Si votre pod redémarre en
boucle faute de clé, ajoutez la variable par **Edit Pod** (menu ⋮ du pod), puis redonnez son identifiant ; n’en déployez pas
un second. Une fois l’identifiant du pod donné, la langue est retenue : `bash /root/flop-gpu.sh` suffit ensuite.

Pour arrêter de payer : console RunPod, **Pods**, votre pod, **Stop**, puis **Terminate** (la corbeille).

## Ce qu’il vous faut

- Un VPS où `/opt/flop-miner` contient `miner.env` (avec `MODEL_HASH` et `INFERENCE_API_KEY`), le `decode-policy.sh`
  de FLOP et les deux fichiers compose ; Docker avec `docker compose` ; `curl`, `jq`, `awk`, `flock`, `timeout` et
  `stty`.
- Une adresse IPv4 publique sur le VPS, ou son nom DNS dans `SESSION_PUBLIC_HOST` de `miner.env`.
- Un compte RunPod avec du crédit.

## Ce qu’elle garantit

- Votre clé d’inférence s’affiche une fois, seule sur sa ligne, quand vous le demandez, et une autre fois seulement si
  votre pod la refuse. L’écran et son historique s’effacent dès qu’elle est collée, et à toute sortie pendant qu’elle
  est affichée. Elle ne passe dans la ligne de commande d’aucun processus et ne s’écrit nulle part ailleurs que dans
  `miner.env`. Certains terminaux gardent l’écran effacé dans leur historique : remontez-le pour vérifier.
- `SESSION_AUTH_TOKEN` et la clé de signature du mineur ne s’affichent jamais. Rien de ce qui se tape ne s’affiche, pas
  même une clé collée trop tôt.
- Elle n’appelle jamais l’API de RunPod : elle ne lit que le `/health` de votre pod, par le proxy HTTPS de RunPod.
- La relancer est sans danger : un verrou empêche deux passages en même temps, et toute sortie après les consignes
  rappelle que votre pod se paie jusqu’à Stop, puis Terminate.
- `bash -x` ne peut pas imprimer un secret : la trace est coupée d’office.

## Ce qu’elle écrit et contacte

- `/opt/flop-miner/miner.env` : `OPENAI_BASE_URL` et `SESSION_PUBLIC_HOST`, remplacés d’un seul coup, en mode 600 ; la
  politique de décodage, par le `decode-policy.sh` de FLOP.
- `/opt/flop-miner/flop-gpu.etat` : le fournisseur, l’identifiant du pod et la langue, aucun secret, en mode 600.
- `/opt/flop-miner/.flop-gpu.verrou` : le verrou.

Elle contacte votre pod par le proxy HTTPS de RunPod et le réseau FLOP par `decode-policy.sh` ; Docker tire ensuite les
images du worker. Rien ne part vers les auteurs de cet outil.

## Options

| Option ou variable | Effet |
|---|---|
| `--a-vide`, `--dry-run` | passage à vide : montre les consignes, rien n’est écrit ni démarré |
| `-h`, `--aide`, `--help` | le résumé de la commande, dans sa langue |
| `FLOP_RUNPOD_TEMPLATE` | un autre template RunPod que `tipfc9vtff` |
| `FLOP_GPU_LANG` | `fr` pour les messages en français, `en` pour l’anglais (par défaut) ; retenue dans `flop-gpu.etat` |
| `FLOP_GPU_ATTENTE_MIN` | l’attente du GPU, en minutes (40 par défaut) |
| `FLOP_MINER_DIR` | un autre dossier que `/opt/flop-miner` |

Codes de sortie : 0 fait ; 2 VPS pas prêt ou mauvais usage ; 3 politique de décodage ; 6 pod (identifiant, modèle,
clé ou politique toujours refusés) ; 7 délai dépassé ; 8 worker ou nom HTTPS ; 130 interrompu.

## La lire avant de la lancer

La commande est un seul fichier bash lisible :

```bash
curl -fsSL https://raw.githubusercontent.com/Syphiliis/flop-gpu/v0.3.3/flop-gpu.sh -o /root/flop-gpu.sh
less /root/flop-gpu.sh
FLOP_GPU_LANG=fr bash /root/flop-gpu.sh --a-vide
```

Vous lancez le fichier même que vous avez lu, et l’adresse nomme une version (`v0.3.3`), pas les derniers changements.

## État

Version 0.3.3, 19 novembre 2026 : messages en anglais par défaut, en français sous `FLOP_GPU_LANG=fr` ; pour le reste,
la même commande que la 0.3.2. La 0.3.3 a été éprouvée sur un banc qui simule le VPS, le proxy de RunPod et Docker :
31 scénarios (25 en anglais, 6 pour le français et le choix de la langue), sans GPU, le worker jamais démarré.

Passage réel le 18 novembre 2026 (versions 0.3.1 et 0.3.2), sur un VPS en Ubuntu 22.04 avec une RTX PRO 4000 louée
chez RunPod : passage à vide, lien du GPU et relance tous réussis. Le pod avait été déployé sans la clé ; l’ajouter par
**Edit Pod** a suffi, et le GPU était prêt moins de 2 minutes après. Le worker répondait en HTTPS, et aucune copie de la
clé d’inférence n’a été trouvée sur le VPS hors de `miner.env`. La durée entre **Deploy Pod** et un GPU prêt, au
premier démarrage, n’a pas été mesurée.

## À propos

Écrite et maintenue par Alex ([Syphiliis](https://github.com/Syphiliis)), fondateur d’EasyNode, hébergeur de nodes.
Cet outil n’est ni fait ni approuvé par FLOP Labs ou RunPod. Aucun jeton à acheter, aucun conseil financier. Les
signalements sont bienvenus dans les issues. Licence : [MIT](LICENSE).
