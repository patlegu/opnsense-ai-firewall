# Build log — native FreeBSD llama.cpp, 2026-05-12

First native FreeBSD build of the `llama-server` binary embedded by
this repo. This log exists to enable reproducibility and the
diagnosis of any future regression.

## Environment

| Item | Value |
| --- | --- |
| Date | 2026-05-12 |
| Build host | libvirt VM on <LIBVIRT_HOST> (`oaf-build-net` network) |
| Build OS | FreeBSD 14.4-RELEASE amd64 (`releng/14.4-n273675-a456f852d145`) |
| Source image | `FreeBSD-14.4-RELEASE-amd64-BASIC-CI.raw.xz` (official CI image) |
| vCPU / RAM | 4 / 4 GB |
| Architecture | amd64 (Hetzner-style virtio) |

## Toolchain

```text
clang/llvm    : 18.x (`llvm` package)
cmake         : 3.31+
gmake         : 4.x
pkgconf       : 2.4.3
openblas      : 0.3.x
git           : 2.x
```

(Exact versions: `pkg info` wasn't running at the time of the log;
to be re-run next time.)

## llama.cpp tag

| Field | Value |
| --- | --- |
| Tag | `b3813` |
| Commit | `116efee0eef09d8c3c4c60b52fa01b56ddeb432c` |
| Date | 2024-09-24 |
| Subject | "cuda: add q8_0->f32 cpy operation (#9571)" |

## cmake configuration (effective)

```bash
cmake -B build \
    -DCMAKE_BUILD_TYPE=Release \
    -DGGML_NATIVE=ON \
    -DGGML_BLAS=ON \
    -DGGML_BLAS_VENDOR=OpenBLAS \
    -DLLAMA_BUILD_SERVER=ON \
    -DLLAMA_BUILD_TESTS=OFF
```

> ⚠️ Note `LLAMA_BUILD_EXAMPLES`: on b3813 the `llama-server` target is
> under `examples/`. If you pass `LLAMA_BUILD_EXAMPLES=OFF` (as the
> doc suggested to save build time), gmake refuses the target
> `llama-server` ("No rule to make target 'llama-server'"). For b3813
> you must therefore **leave EXAMPLES ON**; more recent versions
> may have moved it.

## Build duration

```text
time cmake --build build -j 4 --config Release --target llama-server
→ 61.65 real / 108.34 user / 1.70 sys
```

Very fast because we only build the `llama-server` target and its
dependencies (libllama + libggml), not all the examples.

## Runtime dependencies (ldd)

```text
llama-server requires:
  libthr.so.3           (FreeBSD base)
  libllama.so           ← embedded in lib/
  libggml.so            ← embedded in lib/
  libc++.so.1           (FreeBSD base)
  libcxxrt.so.1         (FreeBSD base)
  libm.so.5             (FreeBSD base)
  libgcc_s.so.1         (FreeBSD base)
  libc.so.7             (FreeBSD base)
  libopenblas.so.0      ← embedded in lib/ (openblas port)
  libomp.so             (FreeBSD base)
  libgfortran.so.5      ← embedded in lib/ (gcc14, OpenBLAS dependency)
  libquadmath.so.0      ← embedded in lib/ (gcc14)
```

So we **embed 5 `.so`** in `llama-bin/freebsd-amd64/lib/` to
be self-contained on OPNsense. The other libs (`libthr`, `libm`,
`libomp`, etc.) come from the FreeBSD 14 base system, which we
assume identical on OPNsense 26.1.

## Delivered artefacts (SHA-256)

```text
llama-server                                                 eb2e9024c69f6096f4d4b0f7cc4cd7a7b13f80cb0fdbe17162834860219a0663
lib/libgfortran.so.5                                         09f1f25910f34d59651fec3fd4fb58d67ee71989b84ffdc255124d6d83e283ba
lib/libggml.so                                               630120cb1a002e92b0d5bb88bfbbd8f480fc2d6a959f418092441aef75afd507
lib/libllama.so                                              2f923abafdd518947ae8f05f97fd0fddd024ca97c0dfd07bcf207e5d326a2855
lib/libopenblas.so.0                                         f544a5f61fe0817df3192dcac087cb802c7392ab065c8c89233805d91e26bf35
lib/libquadmath.so.0                                         7691f212d8f22e74eea1dd23429d2006eea404af699e1a964c2f3faa5fb8a363
```

Intermediate tarball (before unpack on <WORKSTATION>):
`4743852f93de290d547819cf9a7860b26de0de5bdd21384940cc40284ab5ccae`.

## Build VM (status)

The `oaf-build-freebsd` VM on <LIBVIRT_HOST> is **kept stopped** (not
destroyed) — useful if we want to rebuild at another llama.cpp tag or
compile other FreeBSD components. To reuse it:

```bash
ssh -p 2222 root@<LIBVIRT_HOST> 'virsh start oaf-build-freebsd'
# wait 30s then SSH via ProxyJump:
ssh -J root@<LIBVIRT_HOST>:2222 root@192.168.230.50
```

## Pitfalls encountered (summary, for long-term memory)

- `LLAMA_BUILD_EXAMPLES=OFF` breaks the `llama-server` target on b3813.
- pkgconf is NOT a transitive dependency of `openblas` on
  FreeBSD 14.4 — you need a separate `pkg install pkgconf` (otherwise
  cmake crashes hunting for `pkg-config`).
- Cloud-init seed iso + BASIC-CI image works very well on libvirt
  <LIBVIRT_HOST> (whereas Hetzner Cloud + mfsBSD = friction).
- The `DHCP pool` of the `ptm-pentest-stack-lan-1` network was saturated →
  created a dedicated network `oaf-build-net` (192.168.230.0/24).
