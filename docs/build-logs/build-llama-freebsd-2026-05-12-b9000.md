# Build log — llama.cpp natif FreeBSD, 2026-05-12 (bump b9000)

Re-build sur tag récent pour avoir le **support tool-calling natif** +
`--jinja` (le b3813 d'origine rejetait `tools` avec
`Unsupported param: tools` côté `/v1/chat/completions`).

## Pourquoi le bump

Le LoRA `patlegu/opnsense-agent-phi35` parle OpenAI tool-calling
format. Sur b3813 (sept 2024), le `tools` arg n'était pas implémenté
côté `llama-server`. Sur **b9000** (1er mai 2026), c'est natif.

## Environnement (idem que le build d'origine)

| Item | Valeur |
| --- | --- |
| Date | 2026-05-12 |
| Build host | VM libvirt sur korrig.breizhland.eu (réseau `oaf-build-net`) |
| OS de build | FreeBSD 14.4-RELEASE amd64 |
| vCPU / RAM | 4 / 4 GB |

## Tag llama.cpp

| Field | Valeur |
| --- | --- |
| Tag | `b9000` |
| Commit | `1a03cf47f67be591699d1f0f7ca28e1ed6eb8c7e` |
| Date | 2026-05-01 20:29:13 -0700 |
| Sujet | "hexagon: hmx flash attention (#22347)" |

## Configuration cmake (idem que b3813)

```bash
cmake -B build \
    -DCMAKE_BUILD_TYPE=Release \
    -DGGML_NATIVE=ON \
    -DGGML_BLAS=ON \
    -DGGML_BLAS_VENDOR=OpenBLAS \
    -DLLAMA_BUILD_SERVER=ON \
    -DLLAMA_BUILD_TESTS=OFF
```

> Note : `LLAMA_BUILD_EXAMPLES` n'est plus nécessaire — depuis ~b4500
> `llama-server` est dans `tools/server/` (pas `examples/`).

## Durée

```text
time cmake --build build -j 4 --config Release --target llama-server
→ 188.76 real / 617.18 user / 16.40 sys
```

3 minutes — toujours bien sous cpx32/cx33.

## Artefacts livrés

Bien plus de `.so` qu'en b3813 (split des modules ggml-base, ggml-cpu,
ggml-blas, llama-common, mtmd) :

```text
llama-server                       8.9 MB
lib/
├── libggml.so          (+ links)  35 KB
├── libggml-base.so     (+ links)  738 KB
├── libggml-cpu.so      (+ links)  1.2 MB
├── libggml-blas.so     (+ links)  22 KB
├── libllama.so         (+ links)  2.5 MB
├── libllama-common.so  (+ links)  4.2 MB
├── libmtmd.so          (+ links)  903 KB
├── libopenblas.so.0    28 MB
├── libgfortran.so.5    3.2 MB
└── libquadmath.so.0    279 KB
```

Total : ~52 MB. Binaire principal **8.9 MB** (vs 2.1 MB en b3813) car
le code a beaucoup grossi côté serveur (tool-calling, jinja, etc.).

## SHA-256 du tarball

`1274ff893299a24d84134053b5783e1efa01bb5273cf130a331ea6384edc3915`

## Différences pratiques vs b3813

- `--jinja` est dispo → on l'active dans `rc-llama.tftpl` pour que
  llama-server utilise le chat template du GGUF (Phi-3 ici).
- `--lora` reste utilisable si on a un LoRA séparé.
- Le param `tools` de `/v1/chat/completions` est implémenté → l'agent
  Python peut envoyer des tool definitions et recevoir des
  `tool_calls` formatés.

## VM de build

Toujours stoppable/redémarrable :

```bash
ssh -p 2222 root@korrig.breizhland.eu 'virsh shutdown oaf-build-freebsd'
# plus tard :
ssh -p 2222 root@korrig.breizhland.eu 'virsh start oaf-build-freebsd'
ssh -J root@korrig.breizhland.eu:2222 root@192.168.230.50
```
