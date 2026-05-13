# gguf/

Modèles GGUF à uploader sur la VM OPNsense. **Ignorés par git** —
les fichiers sont trop gros et déjà publics ailleurs.

## Contenu attendu (configuration par défaut)

| Fichier | Origine | Taille |
| --- | --- | --- |
| `opnsense-agent-phi35-q4_k_m.gguf` | [patlegu/opnsense-agent-phi35](https://huggingface.co/patlegu/opnsense-agent-phi35) (Phi-3 mini + LoRA OPNsense déjà mergé, Q4_K_M) | ~2.4 GB |

Un seul fichier suffit : c'est le **modèle merged** (base Phi-3 mini
+ adapter LoRA fusionnés), pas un base + LoRA séparés. Pas besoin de
`--lora` côté `llama-server`.

## Récupération automatique (tofu apply)

Le `null_resource embedded_llm` du `infra/envs/hcloud/main.tf`
télécharge le fichier directement sur la VM OPNsense via `fetch(1)`,
depuis l'URL définie dans la variable :

- `opnsense_llm_base_url` → `opnsense-agent-phi35-q4_k_m.gguf`

Donc en pratique tu n'as **rien à mettre dans `gguf/`** côté ton poste
de travail — le download se fait directement sur la VM.

## Récupération locale (optionnel, pour tests offline)

Si tu veux le fichier en local (debug, build d'image custom, etc.) :

```bash
huggingface-cli download patlegu/opnsense-agent-phi35 \
    opnsense-agent-phi35-q4_k_m.gguf --local-dir ./gguf
```

## Cas avancé : LoRA séparé

Si tu veux superposer un LoRA séparé (au format GGUF, converti via
`convert_lora_to_gguf.py` de llama.cpp) sur une base Phi-3 mini brute,
renseigne les variables Tofu :

- `opnsense_llm_base_url` → la base Phi-3 mini Q4 GGUF (microsoft/Phi-3-mini-4k-instruct-gguf)
- `opnsense_llm_lora_url` → le LoRA GGUF séparé

Le rc.d ajoutera alors `--lora <fichier>` à la commande `llama-server`.
Voir `infra/envs/hcloud/templates/rc-llama.tftpl` pour le détail.
