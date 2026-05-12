# gguf/

Modèles GGUF à uploader sur la VM OPNsense. **Ignorés par git** —
les fichiers sont trop gros (~3 GB cumulés) et publics par ailleurs.

## Contenu attendu

| Fichier | Origine | Taille |
| --- | --- | --- |
| `phi-3-mini-4k-q4.gguf` | [microsoft/Phi-3-mini-4k-instruct-gguf](https://huggingface.co/microsoft/Phi-3-mini-4k-instruct-gguf) (Q4_K_M) | ~2.4 GB |
| `opnsense-agent-phi35.gguf` | [patlegu/opnsense-agent-phi35](https://huggingface.co/patlegu/opnsense-agent-phi35) (LoRA Phi-3 OPNsense, déjà au format GGUF) | ~480 MB |

## Récupération

`tofu apply` télécharge automatiquement depuis les URLs définies
dans les variables :

- `opnsense_llm_base_url`     → `phi-3-mini-4k-q4.gguf`
- `opnsense_llm_lora_url`     → `opnsense-agent-phi35.gguf`

Pour download local (test) :

```bash
huggingface-cli download microsoft/Phi-3-mini-4k-instruct-gguf \
    Phi-3-mini-4k-instruct-q4.gguf --local-dir ./gguf
mv ./gguf/Phi-3-mini-4k-instruct-q4.gguf ./gguf/phi-3-mini-4k-q4.gguf

huggingface-cli download patlegu/opnsense-agent-phi35 \
    opnsense-agent-phi35-q4_k_m.gguf --local-dir ./gguf
mv ./gguf/opnsense-agent-phi35-q4_k_m.gguf ./gguf/opnsense-agent-phi35.gguf
```
