# llama-bin/freebsd-amd64

Binaires compilés natifs FreeBSD amd64. Produits par
`scripts/build-llama-freebsd.sh` (palier B). Pas dans git.

Après build :

```text
llama-server      # binaire principal
lib/
├── libggml.so
├── libggml-base.so
├── libggml-cpu.so
└── libllama.so
```

Vérifier que c'est bien FreeBSD :

```bash
file llama-server
# attendu : ELF 64-bit LSB pie executable, x86-64, version 1 (FreeBSD)
```
