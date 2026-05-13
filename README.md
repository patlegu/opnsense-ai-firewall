# opnsense-ai-firewall

🇫🇷 **Français** · [🇬🇧 English](README.en.md)

**Experimental** — déploie une VM OPNsense Hetzner avec un LLM
embarqué (llama-server FreeBSD + LoRA Phi-3 OPNsense) qui pilote son
propre API depuis l'intérieur de la VM. **Pas de sidecar.**

> ⚠️ **Lab uniquement.** Cette topologie est délibérément déconseillée
> en production (voir [`docs/why-not-in-prod.md`](docs/why-not-in-prod.md)
> pour les 4 raisons concrètes : surface d'attaque, contention CPU,
> cycle de vie, audit). Le but de ce repo est de **mesurer** à quel
> point c'est une mauvaise idée et où sont les seuils.

## Statut — proof-of-concept validée (mai 2026)

| Composant | Statut |
| --- | --- |
| llama-server natif FreeBSD | ✅ Build b9000 (cf. [`docs/build-logs/`](docs/build-logs/)) |
| Service rc.d `llama` | ✅ Bind strict `127.0.0.1:8080`, daemon(8) |
| Agent local `oaf-agent` | ✅ Python 3.13, wrapper `/usr/local/bin/oaf-agent` |
| Chaîne intent → tool_call → API (read) | ✅ `oaf-agent ask "Show system information"` → JSON OPNsense |
| Chaîne intent → tool_call → API (write) | ✅ `oaf-agent ask "Block IP 1.2.3.4 on WAN" --confirm` → règle pf créée avec UUID |
| Latence intent → réponse | ~10 s sur cx33 (4 vCPU CPU-only) |
| Couverture `TOOLS_CATALOG` | **101 / 102** fonctions canoniques (verify v7) dispatchées : 97 auto-résolues via `scripts/generate-tools-catalog.py` + 4 overrides locaux ; reste `import_alias` (pas d'endpoint REST natif OPNsense) |

Démo détaillée et logs de test : [`docs/demo-results.md`](docs/demo-results.md).

Forked from `kickstart-forge` (template Hetzner Cloud privé).

> **Note publique GitHub** : ce repo dépend du module Tofu interne
> `iac-modules` (hébergé en privé sur GitLab) pour les modules
> `hcloud/{network,opnsense,debian,agent}` + `wireguard-mesh`. Sans
> accès à ce module, `tofu apply` ne tourne pas. Le repo est publié
> comme **démonstration de pattern** (LLM in-box + agent local +
> tool-calling vers l'API OPNsense), pas comme une infra
> reproductible clés-en-main. Pour reproduire intégralement, adapter
> les `source = "git::ssh://..."` du `main.tf` vers tes propres
> modules Tofu (les contrats d'interface sont documentés dans
> `infra/envs/hcloud/variables.tf`).

## Ce qu'il faut pour faire tourner le GGUF

**Trois ingrédients**, rien d'autre :

1. **Une VM OPNsense** — n'importe laquelle, peu importe l'hébergeur
   (Hetzner Cloud, libvirt local, baremetal, lab perso…). Version
   conseillée : 26.1.x amd64 (FreeBSD 14). Au moins 8 GB de RAM pour
   tenir le modèle (~2.4 GB) + `pf` + le reste de la VM.
2. **`llama-server` compilé pour FreeBSD** — binaire + 6 `.so`
   embarqués (`libllama`, `libggml*`, `libopenblas`, `libgfortran`,
   `libquadmath`). C'est l'effort principal du repo, voir
   [`docs/build-llama-freebsd.md`](docs/build-llama-freebsd.md).
   Tag `llama.cpp` ≥ b9000 (pour le support natif `tools` +
   `--jinja`).
3. **Le GGUF merged Phi-3+LoRA** : [`patlegu/opnsense-agent-phi35-q4_k_m.gguf`](https://huggingface.co/patlegu/opnsense-agent-phi35/resolve/main/opnsense-agent-phi35-q4_k_m.gguf)
   sur Hugging Face (~2.4 GB, Q4_K_M, déjà fusionné — pas besoin de
   `--lora`).

Plus, côté OPNsense, **Python 3.11+** (un `pkg install python311`)
pour l'agent local. C'est tout.

Avec ces 3 éléments en place, le pipeline `intent → tool_call →
API OPNsense` fonctionne sur n'importe quelle OPNsense — l'infra
Hetzner/Tofu plus bas n'est qu'un confort d'automatisation.

## Topologie

```text
┌─────────────────────────────────────────────────┐
│  OPNsense 26.x (FreeBSD 14)                     │
│  ┌───────────────────────────────────────────┐  │
│  │ llama-server (FreeBSD natif, b9000+)      │  │
│  │   bind 127.0.0.1:8080                     │  │
│  │   merged Phi-3 mini Q4_K_M + LoRA OPNsense│  │
│  └─────────────────┬─────────────────────────┘  │
│                    │ HTTP local                  │
│  ┌─────────────────▼─────────────────────────┐  │
│  │ agent local (Python 3.11)                 │  │
│  │   intent NL → tool_call (101/102)         │  │
│  │   → OPNsense API 127.0.0.1:4443           │  │
│  │   scope_confirmed sur tout mutating       │  │
│  └───────────────────────────────────────────┘  │
│                                                 │
│   pf · NAT · DHCP · DNS · …                     │
└─────────────────────────────────────────────────┘
```

Aucun sidecar, aucun trafic LLM en clair sur le réseau, aucun port
externe lié au LLM (toujours `127.0.0.1`). L'agent local et
`llama-server` partagent le même CPU/RAM que `pf`.

## Installation manuelle (n'importe quelle OPNsense)

Si tu as déjà une OPNsense up et les artefacts compilés (cf. la
section précédente) :

```bash
# Depuis ton poste de travail
OPNSENSE_IP="<IP_DE_TON_OPNSENSE>"

# 1. SCP des artefacts FreeBSD + agent
scp -P 2222 llama-bin/freebsd-amd64/llama-server \
            root@${OPNSENSE_IP}:/var/llm/bin/
scp -P 2222 llama-bin/freebsd-amd64/lib.tar.gz \
            root@${OPNSENSE_IP}:/tmp/
scp -P 2222 agent/oaf_agent.py agent/tools_catalog.py \
            root@${OPNSENSE_IP}:/var/llm/agent/

# 2. Sur la VM OPNsense : préparer, télécharger le GGUF, configurer rc.d
ssh -p 2222 root@${OPNSENSE_IP} /bin/sh <<'EOF'
set -e
mkdir -p /var/llm/{bin,lib,models,agent} /var/log/llama
tar -C /var/llm/lib -xzf /tmp/lib.tar.gz
chmod +x /var/llm/bin/llama-server
pkg install -y python311
fetch --no-verify-hostname \
    -o /var/llm/models/opnsense-agent-phi35-q4_k_m.gguf \
    https://huggingface.co/patlegu/opnsense-agent-phi35/resolve/main/opnsense-agent-phi35-q4_k_m.gguf
EOF

# 3. Service rc.d + agent env (templates dans infra/envs/hcloud/templates/)
#    Adapter rc-llama.tftpl et post-install-llm.sh.tftpl avec tes valeurs,
#    pousser sur /usr/local/etc/rc.d/llama + /etc/oaf-agent.env, puis :
ssh -p 2222 root@${OPNSENSE_IP} 'service llama start && oaf-agent health'
```

Résultat attendu :

```text
[oaf] llama-server : 200 {"status":"ok"}
[oaf] OPNsense API OK : keys=['name', 'versions', 'updates']
```

À partir de là, `oaf-agent ask "Show system information"` te retourne
un JSON OPNsense, `oaf-agent ask "Block IP 1.2.3.4 on WAN" --confirm`
crée une vraie règle `pf`. Voir [`docs/demo-results.md`](docs/demo-results.md)
pour les traces de validation.

## Automatisation Hetzner (Tofu, optionnel)

Si tu déploies sur **Hetzner Cloud** et que tu veux tout en une
commande, l'infra Tofu de `infra/envs/hcloud/` automatise les
étapes ci-dessus (création VM + SCP artefacts + rc.d + healthcheck).
Elle **dépend du module privé `iac-modules`** (cf. note publique
en haut), donc pour reproduire ailleurs il faut adapter les sources
de module. C'est l'angle "lab Hetzner" du repo, pas la fonctionnalité
centrale.

<details>
<summary>Quickstart Tofu Hetzner (déplier)</summary>

```bash
# .env à la racine du projet
cat > .env <<'EOF'
HCLOUD_TOKEN=hcloud_xxxxx
EOF

# tfvars : secrets propres au déploiement
cp infra/envs/hcloud/terraform.tfvars.example \
   infra/envs/hcloud/terraform.tfvars
# Renseigner ssh_public_keys, vm_password_hash, etc.
bash scripts/init-secrets.sh --auto

# Build llama.cpp FreeBSD (une fois)
bash scripts/build-llama-freebsd.sh root@<IP_VM_FREEBSD>

# Déployer
set -a && . .env && set +a
cd infra/envs/hcloud && tofu init && tofu apply
```

</details>

## Composants

| Composant | Valeur par défaut |
| --- | --- |
| VM | `cx33` (4 vCPU / 8 GB) |
| OS | OPNsense 26.1.x amd64 (FreeBSD 14) |
| Base LLM | `microsoft/Phi-3-mini-4k-instruct-gguf` Q4_K_M (~2.5 GB) |
| LoRA | [`patlegu/opnsense-agent-phi35`](https://huggingface.co/patlegu/opnsense-agent-phi35) (~480 MB) |
| Runtime | `llama-server` compilé natif FreeBSD (palier B) |
| Port LLM | `127.0.0.1:8080` (jamais exposé WAN) |
| Port OPNsense API | `4443` (WAN + restreint par alias) |
| Port SSH OPNsense | `2222` (jamais 22 — réservé pour Cowrie si T-Pot étendu) |

## Sécurité — non-objectifs

Ce repo **n'essaie pas** :

- de faire d'OPNsense un système production-grade avec LLM embarqué ;
- de réduire la surface d'attaque ajoutée par `llama-server` ;
- de garantir une latence pf sous charge LLM ;
- d'auditer les chaînes d'appel agent → API (toute action passe par
  un `scope_confirmed` mais ce n'est pas un contrôle anti-malicieux,
  juste un garde-fou opérateur).

Si tu cherches cette topologie en production, regarde plutôt
les patterns "sidecar VM dédiée + OPNsense vanilla" — bien plus sain.
Quelques implémentations existent (privées) dans l'écosystème
`*-forge` interne ; le pattern public se résume à : VM Debian avec
llama-server, plus un agent Python qui parle à l'API OPNsense via HTTPS.

## Documentation

- [`docs/why-not-in-prod.md`](docs/why-not-in-prod.md) — les 4
  raisons concrètes
- [`docs/build-llama-freebsd.md`](docs/build-llama-freebsd.md) —
  compilation native FreeBSD (palier B)
- [`docs/embedded-llm.md`](docs/embedded-llm.md) — architecture du
  service rc.d + agent local
- [`docs/access-credentials.md`](docs/access-credentials.md) —
  hérité du kickstart, secrets / SSH / API OPNsense

## Origine

Spawné depuis `kickstart-forge` (template interne) avec la convention
`*-forge` (préfixe 3 lettres = `oaf`). Tout ce
qui n'est pas spécifique au LLM in-box vient du kickstart ; ce qui
est spécifique vit dans `docs/embedded-llm.md` et les variables
`opnsense_llm_*`.
