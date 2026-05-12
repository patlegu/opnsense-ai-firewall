# opnsense-ai-firewall

**Experimental** — déploie une VM OPNsense Hetzner avec un LLM
embarqué (llama-server FreeBSD + LoRA Phi-3 OPNsense) qui pilote son
propre API depuis l'intérieur de la VM. **Pas de sidecar.**

> ⚠️ **Lab uniquement.** Cette topologie est délibérément déconseillée
> en production (voir [`docs/why-not-in-prod.md`](docs/why-not-in-prod.md)
> pour les 4 raisons concrètes : surface d'attaque, contention CPU,
> cycle de vie, audit). Le but de ce repo est de **mesurer** à quel
> point c'est une mauvaise idée et où sont les seuils.

Forked from [kickstart-forge](https://gitlab.com/llm_tests/kickstart-forge).

## Topologie

```text
Internet
    │
    ▼
┌───────────────────────────────────────────────────────┐
│  Hetzner Cloud — cx33 (8 GB) ou cx43 (16 GB)          │
│                                                       │
│  ┌─────────────────────────────────────────────────┐  │
│  │  OPNsense 26.x (FreeBSD 14)                     │  │
│  │  ┌───────────────────────────────────────────┐  │  │
│  │  │ llama-server                              │  │  │
│  │  │   bind 127.0.0.1:8080                     │  │  │
│  │  │   Phi-3 mini Q4_K_M + opnsense_agent LoRA │  │  │
│  │  └─────────────────┬─────────────────────────┘  │  │
│  │                    │ HTTP local                  │  │
│  │  ┌─────────────────▼─────────────────────────┐  │  │
│  │  │ agent local (Python)                      │  │  │
│  │  │   intent → CAP v1 → tool_call             │  │  │
│  │  │   → OPNsense API 127.0.0.1:4443           │  │  │
│  │  │   scope_confirmed guard sur tout mutating │  │  │
│  │  └───────────────────────────────────────────┘  │  │
│  │                                                 │  │
│  │   pf · NAT · DHCP · DNS · …                     │  │
│  └─────────────────────────────────────────────────┘  │
│                                                       │
└───────────────────────────────────────────────────────┘
```

Aucun sidecar, aucun trafic LLM en clair sur le réseau, aucun port
externe lié au LLM (toujours `127.0.0.1`). L'agent local et
`llama-server` partagent le même CPU/RAM que `pf`.

## Quickstart

```bash
# 1. Cloner + secrets
git clone git@gitlab.com:llm_tests/opnsense-ai-firewall.git
cd opnsense-ai-firewall

# 1a. .env à la racine — HCLOUD_TOKEN obligatoire, TF_HTTP_* si backend
#     GitLab Managed Terraform State activé.
cat > .env <<'EOF'
HCLOUD_TOKEN=hcloud_xxxxx
# TF_HTTP_USERNAME=patlegu
# TF_HTTP_PASSWORD=glpat-xxx
EOF

# 1b. tfvars : juste les secrets propres au déploiement (hashes, clé pub,
#     API OPNsense). hcloud_token n'est PAS requis ici — il sera lu de
#     l'environnement HCLOUD_TOKEN (cf. 1a).
cp infra/envs/hcloud/terraform.tfvars.example \
   infra/envs/hcloud/terraform.tfvars
# Renseigner : ssh_public_key, vm_password_hash, opnsense_root_hash, …

bash scripts/init-secrets.sh --auto

# 2. Compiler llama.cpp pour FreeBSD (palier B — une fois)
bash scripts/build-llama-freebsd.sh
# produit llama-bin/freebsd-amd64/{llama-server, lib/*.so}

# 3. Déployer
set -a && . .env && set +a   # charge HCLOUD_TOKEN dans l'env Tofu
cd infra/envs/hcloud
tofu init && tofu apply

# 4. Vérifier que l'agent répond
ssh -p 2222 root@<IP_OPNSENSE> 'curl -s http://127.0.0.1:8080/health'
```

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
[asp-forge](https://gitlab.com/llm_tests/asp-forge) ou
[purpleteam-forge](https://gitlab.com/llm_tests/purpleteam-forge) :
sidecar VM dédiée + OPNsense vanilla.

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

Spawné depuis [kickstart-forge](https://gitlab.com/llm_tests/kickstart-forge)
avec la convention `*-forge` (préfixe 3 lettres = `oaf`). Tout ce
qui n'est pas spécifique au LLM in-box vient du kickstart ; ce qui
est spécifique vit dans `docs/embedded-llm.md` et les variables
`opnsense_llm_*`.
