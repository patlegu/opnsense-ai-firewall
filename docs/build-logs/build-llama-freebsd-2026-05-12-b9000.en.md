# Build log — native FreeBSD llama.cpp, 2026-05-12 (bump b9000)

Re-build on a recent tag to get **native tool-calling support** +
`--jinja` (the original b3813 rejected `tools` with
`Unsupported param: tools` on `/v1/chat/completions`).

## Why the bump

The `patlegu/opnsense-agent-phi35` LoRA speaks OpenAI tool-calling
format. On b3813 (Sept 2024), the `tools` arg wasn't implemented
on the `llama-server` side. On **b9000** (May 1st, 2026), it's native.

## Environment (same as the original build)

| Item | Value |
| --- | --- |
| Date | 2026-05-12 |
| Build host | libvirt VM on <LIBVIRT_HOST> (`oaf-build-net` network) |
| Build OS | FreeBSD 14.4-RELEASE amd64 |
| vCPU / RAM | 4 / 4 GB |

## llama.cpp tag

| Field | Value |
| --- | --- |
| Tag | `b9000` |
| Commit | `1a03cf47f67be591699d1f0f7ca28e1ed6eb8c7e` |
| Date | 2026-05-01 20:29:13 -0700 |
| Subject | "hexagon: hmx flash attention (#22347)" |

## cmake configuration (same as b3813)

```bash
cmake -B build \
    -DCMAKE_BUILD_TYPE=Release \
    -DGGML_NATIVE=ON \
    -DGGML_BLAS=ON \
    -DGGML_BLAS_VENDOR=OpenBLAS \
    -DLLAMA_BUILD_SERVER=ON \
    -DLLAMA_BUILD_TESTS=OFF
```

> Note: `LLAMA_BUILD_EXAMPLES` is no longer necessary — since ~b4500
> `llama-server` lives in `tools/server/` (not `examples/`).

## Duration

```text
time cmake --build build -j 4 --config Release --target llama-server
→ 188.76 real / 617.18 user / 16.40 sys
```

3 minutes — still well within cpx32/cx33.

## Delivered artefacts

Many more `.so` than in b3813 (split of ggml-base, ggml-cpu,
ggml-blas, llama-common, mtmd modules):

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

Total: ~52 MB. Main binary **8.9 MB** (vs 2.1 MB on b3813) because
the server-side code has grown a lot (tool-calling, jinja, etc.).

## Tarball SHA-256

`1274ff893299a24d84134053b5783e1efa01bb5273cf130a331ea6384edc3915`

## Practical differences vs b3813

- `--jinja` is available → we enable it in `rc-llama.tftpl` so that
  llama-server uses the chat template from the GGUF (Phi-3 here).
- `--lora` remains usable if we have a separate LoRA.
- The `tools` param of `/v1/chat/completions` is implemented → the
  Python agent can send tool definitions and receive formatted
  `tool_calls`.

## Build VM

Still stoppable/restartable:

```bash
ssh -p 2222 root@<LIBVIRT_HOST> 'virsh shutdown oaf-build-freebsd'
# later:
ssh -p 2222 root@<LIBVIRT_HOST> 'virsh start oaf-build-freebsd'
ssh -J root@<LIBVIRT_HOST>:2222 root@192.168.230.50
```
