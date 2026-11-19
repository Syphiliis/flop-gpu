# FLOP GPU: link your RunPod GPU to your FLOP worker, in one command

One command, pasted on the VPS that runs your FLOP devnet worker. You rent the GPU yourself in RunPod's console, from a
public template; the command tells you what to click, shows your inference key once so you can paste it there, waits
until your GPU serves the right model with the right decoding policy, then writes `miner.env` and starts the worker.
No RunPod API key, no access to your RunPod account.

This is an unofficial community tool: neither FLOP Labs nor RunPod made it. It replaces steps 6 and 7 of the guide
"Launch Your FLOP GPU Node" by BreizhNode on [Medium](https://medium.com/@breizh-node): do the steps before them first.

[Lire en français](README.fr.md). Version 0.3.3, 19 November 2026. The command speaks English by default;
`FLOP_GPU_LANG=fr` switches it to French and is remembered in `flop-gpu.etat`. That happens
once the pod's ID is given; until then, set `FLOP_GPU_LANG=fr` on each run.

## Before you start

- **RunPod bills your GPU by the hour until you Stop, then Terminate it**, even if the command stops or your worker is
  down. The console shows the hourly price before you deploy: from $0.16 to $0.69 for a suitable card on 14 November
  2026, depending on stock (Community or Secure Cloud), that is $4 to $17 a day. At $0 of credit, RunPod deletes the
  pod and your worker loses its GPU: turn on Auto-pay or a Low balance alert (Billing).
- **Devnet only**: test tokens have no value and there are no rewards yet.

## Run it

On your VPS, as root (type `sudo -i` first), once `/opt/flop-miner` and its `miner.env` are ready:

```bash
curl -fsSL https://raw.githubusercontent.com/Syphiliis/flop-gpu/v0.3.3/flop-gpu.sh -o /root/flop-gpu.sh && bash /root/flop-gpu.sh
```

Nothing you type is shown, by design. The command:

1. shows your worker's HTTPS name and fetches FLOP's decoding policy;
2. asks for your GPU provider: press Enter for RunPod;
3. gives you the template link, `https://console.runpod.io/hub/template/tipfc9vtff` (RunPod's search does not list it:
   use the link). In the console: **Configure Pod**, **Set overrides**, **Environment variables**, **Add Environment
   variable**, named `INFERENCE_API_KEY`;
4. shows your inference key when you press Enter. Paste it as the variable's value, click **Set overrides**, then press
   Enter: the screen and its scrollback are cleared;
5. tells you to pick an available card (CUDA 13.0 to 13.4 in **Filter**) and click **Deploy Pod**, never **Deploy when
   available**; then asks for the pod's ID (console, **Pods**), or its `https://…-8000.proxy.runpod.net` address;
6. waits up to 40 minutes, one line per minute, until the GPU is ready; writes `miner.env`, starts the worker, and ends
   with your pod, how to stop paying, and three lines to paste before step 8 of the guide.

To see the instructions without changing anything: `bash /root/flop-gpu.sh --dry-run`.

If it stops halfway (SSH cut, window closed, Ctrl+C), run `bash /root/flop-gpu.sh` again: it offers to keep the pod it
already knows (Enter), or to enter a new one (`n`). If your pod restarts in a loop because the key is missing, add the
variable with **Edit Pod**, in the three-dot menu of that pod, and give its ID again; do not deploy a second one.

To stop paying: RunPod console, **Pods**, your pod, **Stop**, then **Terminate** (the trash icon).

## What you need

- A VPS where `/opt/flop-miner` holds `miner.env` (with `MODEL_HASH` and `INFERENCE_API_KEY`), FLOP's
  `decode-policy.sh` and both compose files; Docker with `docker compose`; `curl`, `jq`, `awk`, `flock`, `timeout` and
  `stty`.
- A public IPv4 address on the VPS, or its DNS name in `SESSION_PUBLIC_HOST` of `miner.env`.
- A RunPod account with credit.

## What it guarantees

- Your inference key is shown once, alone on its line, when you ask for it, and once more only if your pod refuses
  it. The screen and its scrollback are cleared as soon as you have pasted it, and on any exit while it is shown. It
  never appears in a process's command line and is written nowhere but `miner.env`. Some terminals keep cleared screens
  in their scrollback: scroll up to check.
- `SESSION_AUTH_TOKEN` and your miner's signing key are never shown. Nothing you type is echoed, not even a key pasted
  too early.
- It never calls RunPod's API: it only reads your pod's `/health` through RunPod's HTTPS proxy.
- Running it again is safe: a lock stops two runs at once, and any exit once the instructions are shown reminds you
  that your pod is billed until Stop, then Terminate.
- `bash -x` cannot print a secret: tracing is turned off at the start.

## What it writes and contacts

- `/opt/flop-miner/miner.env`: `OPENAI_BASE_URL` and `SESSION_PUBLIC_HOST`, replaced in one go, mode 600; the decoding
  policy, through FLOP's `decode-policy.sh`.
- `/opt/flop-miner/flop-gpu.etat`: the provider, the pod's ID and the language, no secret, mode 600.
- `/opt/flop-miner/.flop-gpu.verrou`: the lock.

It contacts your pod through RunPod's HTTPS proxy and FLOP's network through `decode-policy.sh`; Docker then pulls the
worker's images. Nothing goes to the authors of this tool.

## Options

| Option or variable | Effect |
|---|---|
| `--dry-run`, `--a-vide` | dry run: shows the instructions, nothing is written or started |
| `-h`, `--help`, `--aide` | the command's own summary, in its language |
| `FLOP_RUNPOD_TEMPLATE` | another RunPod template than `tipfc9vtff` |
| `FLOP_GPU_LANG` | `fr` for French messages, `en` for English (the default); remembered in `flop-gpu.etat` |
| `FLOP_GPU_ATTENTE_MIN` | how long to wait for the GPU, in minutes (40 by default) |
| `FLOP_MINER_DIR` | another folder than `/opt/flop-miner` |

Exit codes: 0 done; 2 VPS not ready or wrong usage; 3 decoding policy; 6 pod (ID, model, key or policy still refused);
7 time limit; 8 worker or HTTPS name; 130 interrupted.

## Read it before you run it

The command is one readable bash file:

```bash
curl -fsSL https://raw.githubusercontent.com/Syphiliis/flop-gpu/v0.3.3/flop-gpu.sh -o /root/flop-gpu.sh
less /root/flop-gpu.sh
bash /root/flop-gpu.sh --dry-run
```

You run the very file you read, and the address names a version (`v0.3.3`), not the latest changes.

## Status

Version 0.3.3, 19 November 2026: English messages by default, French with `FLOP_GPU_LANG=fr`; otherwise the same
command as 0.3.2. Version 0.3.3 was checked on a test bench that simulates the VPS, the RunPod proxy and Docker: 31
scenarios (25 in English, 6 for French and the choice of language), no GPU, the worker never started.

Real run on 18 November 2026 (versions 0.3.1 and 0.3.2), on an Ubuntu 22.04 VPS with an RTX PRO 4000 rented on
RunPod: dry run, GPU link and re-run all passed. The pod had been deployed without the key; adding it with **Edit Pod**
was enough, and the GPU was ready less than 2 minutes later. The worker answered over HTTPS, and no copy of the
inference key was found on the VPS outside `miner.env`. The time from **Deploy Pod** to a ready GPU on a first start
was not measured.

## About

Written and maintained by Alex ([Syphiliis](https://github.com/Syphiliis)), founder of EasyNode, a node hosting
company. This tool is neither made nor endorsed by FLOP Labs or RunPod. No token to buy, no financial advice. Bug
reports are welcome in the issues. Licence: [MIT](LICENSE).
