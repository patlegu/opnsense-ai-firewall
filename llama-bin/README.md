# llama-bin/

Binaires `llama-server` compilés pour FreeBSD (OPNsense). **Ignorés
par git** sauf ce README et `freebsd-amd64/README.md`.

## Layout

```text
llama-bin/
├── README.md
└── freebsd-amd64/
    ├── README.md
    ├── llama-server       # binaire principal
    └── lib/               # *.so requises au runtime
        ├── libggml.so
        ├── libggml-base.so
        ├── libggml-cpu.so
        └── libllama.so
```

## Pourquoi pas Linux x86_64 ?

OPNsense est FreeBSD 14. Lancer un binaire Linux nécessiterait
d'activer le Linuxulator (compat layer), qui :

- élargit la surface d'attaque du firewall (cf. CLAUDE.md) ;
- a un overhead variable sur les threads (llama-server en abuse) ;
- est désactivé par défaut sur OPNsense pour de bonnes raisons.

Donc compilation native FreeBSD obligatoire — voir
[`docs/build-llama-freebsd.md`](../docs/build-llama-freebsd.md) et le
script [`scripts/build-llama-freebsd.sh`](../scripts/build-llama-freebsd.sh)
(palier B).
