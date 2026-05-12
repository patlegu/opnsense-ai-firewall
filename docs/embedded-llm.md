# LLM embarqué dans OPNsense — architecture du service

> **Audience** : opérateur qui a déployé le repo (`tofu apply` réussi)
> et veut comprendre ce qui tourne dans la VM OPNsense, comment ça
> dialogue avec l'API locale, et où sont les garde-fous.

## Vue d'ensemble

Dans la VM OPNsense (FreeBSD 14), trois choses :

```text
┌────────────────────── OPNsense (FreeBSD) ──────────────────────┐
│                                                                 │
│  ┌─────────────────────────────┐                                │
│  │  llama-server               │  bind 127.0.0.1:8080           │
│  │  /var/llm/bin/llama-server  │  ─────────────────────► HTTP   │
│  │  LD_LIBRARY_PATH=/var/llm/lib                                │
│  │  -m /var/llm/models/phi-3-mini-4k-q4.gguf                    │
│  │  --lora /var/llm/models/opnsense-agent-phi35.gguf            │
│  │  --ctx-size 4096                                             │
│  └──────────────┬──────────────┘                                │
│                 │                                               │
│                 │  /v1/chat/completions                         │
│                 │  (OpenAI tool-calling format)                 │
│                 │                                               │
│  ┌──────────────▼──────────────────────────────────────────┐    │
│  │  agent local  (/var/llm/agent/oaf_agent.py)             │    │
│  │  - construit un CAP v1 packet à partir de l'intent NL   │    │
│  │  - appelle llama-server pour avoir le tool_call         │    │
│  │  - filtre via TOOLS_WHITELIST                           │    │
│  │  - vérifie scope_confirmed pour les outils mutating     │    │
│  │  - dispatch sur l'API OPNsense locale                   │    │
│  └──────────────┬──────────────────────────────────────────┘    │
│                 │                                               │
│                 │  HTTPS 127.0.0.1:4443                         │
│                 │  Basic auth = key:secret                      │
│                 │                                               │
│  ┌──────────────▼──────────────────────────────────────────┐    │
│  │  OPNsense REST API (/api/cron/..., /api/firewall/..., …)│    │
│  │  → effets de bord sur pf / NAT / VPN / Suricata / etc.  │    │
│  └─────────────────────────────────────────────────────────┘    │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

## Composants

### 1. `llama-server` (rc.d service `llama`)

Géré par `/usr/local/etc/rc.d/llama` (généré au `tofu apply` depuis
le template `templates/rc-llama.tftpl`).

```sh
service llama status
service llama start
service llama stop
service llama restart
tail -f /var/log/llama/server.log
```

PID dans `/var/run/llama.pid`. Daemonisé via `daemon(8)` du base
system FreeBSD — pas de supervisord, pas de systemd.

### 2. Modèles GGUF

| Fichier | Origine | Taille |
| --- | --- | --- |
| `/var/llm/models/phi-3-mini-4k-q4.gguf` | `microsoft/Phi-3-mini-4k-instruct-gguf` Q4_K_M | ~2.4 GB |
| `/var/llm/models/opnsense-agent-phi35.gguf` | `patlegu/opnsense-agent-phi35` | ~480 MB |

Téléchargés par le script `post-install-llm.sh` (généré au tofu apply)
via `fetch(1)` du base system. Le download initial prend 1–2 min sur
réseau Hetzner Helsinki.

### 3. Agent local Python (`oaf_agent.py`)

Vit à `/var/llm/agent/oaf_agent.py` (déployé par le palier C). Pas de
deps externes — stdlib + Python 3.11 (déjà sur OPNsense via `pkg`).

Usage :

```sh
# smoke test : llama-server + OPNsense API joignables
python3 /var/llm/agent/oaf_agent.py health

# intent en lecture seule (pas de --confirm requis)
python3 /var/llm/agent/oaf_agent.py ask "List all scheduled cron jobs"

# intent mutating (échoue sans --confirm, affiche dry-run)
python3 /var/llm/agent/oaf_agent.py ask "Block IP 203.0.113.42 on WAN"

# Idem mais effectivement appliqué
python3 /var/llm/agent/oaf_agent.py ask "Block IP 203.0.113.42 on WAN" --confirm
```

Variables d'environnement (par défaut OK si OPNsense vanilla) :

| Var | Défaut | Rôle |
| --- | --- | --- |
| `OAF_LLM_URL` | `http://127.0.0.1:8080` | endpoint llama-server |
| `OAF_OPNSENSE_URL` | `https://127.0.0.1:4443` | endpoint API OPNsense |
| `OAF_OPNSENSE_KEY` | (à set) | clé API OPNsense en clair |
| `OAF_OPNSENSE_SECRET` | (à set) | secret API OPNsense en clair |
| `OAF_TIMEOUT` | `120` | timeout HTTP (s) |

Les `OAF_OPNSENSE_*` sont à set par l'opérateur (jamais committés).
Ils correspondent aux `opnsense_api_key` / `opnsense_api_secret_plain`
de `terraform.tfvars` (l'opérateur les a déjà sur sa machine de
déploiement).

## Garde-fous

### Catalogue + blacklist (au lieu d'une whitelist rigide)

Trois couches de filtrage côté `oaf_agent.py` :

1. **`TOOLS_CATALOG`** (généré) : noms sur lesquels le LoRA a été
   entraîné, avec leur `(method, endpoint, mutating)` extraits du repo
   `cyber-agent-engine`. Produit par `scripts/generate-tools-catalog.py`.
   ~72 entrées actuellement.
2. **`TOOLS_LOCAL_OVERRIDES`** (manuel, dans `oaf_agent.py`) : aliases
   et endpoints non couverts par le catalog auto — observés en sortie
   LoRA pendant les tests (ex: `diagnostics_cron`,
   `wireguard_client_get_client_builder`, etc.).
3. **`TOOLS_BLACKLIST`** (opérateur runtime) : opt-in via env
   `OAF_BLACKLIST="a,b,c"` ou fichier `/etc/oaf-agent.blacklist` (1
   nom par ligne). Permet un mode read-only / démo non disruptive sans
   toucher au code. Tofu peut peupler ce fichier via la variable
   `opnsense_llm_tools_blacklist`.

Trois codes de sortie distincts au dispatch :

| Code | Sens |
| --- | --- |
| `0` | Tool dispatché avec succès |
| `3` | Tool **inconnu** = hallucination LoRA (hors catalog + overrides) |
| `5` | Tool blacklisté par l'opérateur |
| `6` | Tool **connu** du LoRA mais sans endpoint mappé (à ajouter dans `TOOLS_LOCAL_OVERRIDES`) |

L'erreur `6` est utile en debug : elle te dit "le LoRA est cohérent
mais l'agent a besoin d'une nouvelle entrée d'override".

Pour régénérer le catalog après évolution du training set :

```bash
bash scripts/generate-tools-catalog.py
# émet agent/tools_catalog.py — committer le résultat
```

### scope_confirmed

Tout tool marqué `mutating=True` dans `TOOLS_WHITELIST` exige
`--confirm` (qui set `scope_confirmed=true` dans le CAP). Sans, l'agent
sort un dry-run JSON et exit 4. Ça évite les "le LoRA m'a fait
créer 50 règles fantômes".

C'est un **garde-fou opérateur**, pas un contrôle anti-malveillant —
quelqu'un avec accès SSH à la VM peut bypasser. Cf. CLAUDE.md sur le
non-objectif "audit sécurité".

### Bind 127.0.0.1

`llama-server` écoute **strictement** sur `127.0.0.1:8080`. Le port
8080 n'est jamais ouvert sur l'IP publique d'OPNsense, ni sur le LAN.
Vérifier après déploiement :

```sh
sockstat -4l | grep 8080
# attendu : llama-server  *  127.0.0.1:8080  *.*
```

Si tu vois `*:8080`, c'est un bug — fix `opnsense_llm_listen_addr` dans
les variables et redéployer.

## Limitations connues

- **Latence d'inférence sur cx33 (8 GB shared)** : ~2-4 s pour le
  prompt processing initial, puis ~7-10 tokens/s en génération. Une
  intent admin = **~10 s total** mesuré en démo (cf.
  [`demo-results.md`](demo-results.md)). Pas adapté pour des décisions
  temps-réel pf — c'est de l'aide à l'admin.
- **Contention CPU** : pendant l'inférence, les 4 vCPU sont saturés.
  Le routage pf prend de la latence mesurable (cf. palier E pour les
  benchs).
- **Une intent à la fois** : `llama-server` est en `--parallel 1` par
  défaut. Plusieurs admin qui posent des questions = file d'attente.
  Si tu veux multi-concurrent, augmenter `--parallel 2` au prix de
  plus de RAM.
- **Pas de mémoire conversationnelle** : chaque `oaf-agent ask` est
  indépendant. Pas de "et maintenant supprime la règle que tu viens
  de créer" — c'est délibéré (KISS + agent stateless).
