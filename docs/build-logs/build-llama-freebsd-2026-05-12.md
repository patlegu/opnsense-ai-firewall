# Build log — llama.cpp natif FreeBSD, 2026-05-12

Premier build natif FreeBSD du binaire `llama-server` embarqué par ce
repo. Ce log existe pour permettre la reproductibilité et le
diagnostic d'une éventuelle régression future.

## Environnement

| Item | Valeur |
| --- | --- |
| Date | 2026-05-12 |
| Build host | VM libvirt sur <LIBVIRT_HOST> (réseau `oaf-build-net`) |
| OS de build | FreeBSD 14.4-RELEASE amd64 (`releng/14.4-n273675-a456f852d145`) |
| Image source | `FreeBSD-14.4-RELEASE-amd64-BASIC-CI.raw.xz` (CI image officielle) |
| vCPU / RAM | 4 / 4 GB |
| Architecture | amd64 (Hetzner-style virtio) |

## Toolchain

```text
clang/llvm    : 18.x (paquet `llvm`)
cmake         : 3.31+
gmake         : 4.x
pkgconf       : 2.4.3
openblas      : 0.3.x
git           : 2.x
```

(Versions exactes : `pkg info` ne tournait pas au moment du log ; à
relancer la prochaine fois.)

## Tag llama.cpp

| Field | Valeur |
| --- | --- |
| Tag | `b3813` |
| Commit | `116efee0eef09d8c3c4c60b52fa01b56ddeb432c` |
| Date | 2024-09-24 |
| Sujet | "cuda: add q8_0->f32 cpy operation (#9571)" |

## Configuration cmake (effective)

```bash
cmake -B build \
    -DCMAKE_BUILD_TYPE=Release \
    -DGGML_NATIVE=ON \
    -DGGML_BLAS=ON \
    -DGGML_BLAS_VENDOR=OpenBLAS \
    -DLLAMA_BUILD_SERVER=ON \
    -DLLAMA_BUILD_TESTS=OFF
```

> ⚠️ Note `LLAMA_BUILD_EXAMPLES`: sur b3813 la cible `llama-server` est
> sous `examples/`. Si on passe `LLAMA_BUILD_EXAMPLES=OFF` (comme la
> doc le suggérait pour économiser du build), gmake refuse la target
> `llama-server` ("No rule to make target 'llama-server'"). Pour b3813
> il faut donc **laisser EXAMPLES ON** ; les versions plus récentes
> ont peut-être bougé.

## Durée de build

```text
time cmake --build build -j 4 --config Release --target llama-server
→ 61.65 real / 108.34 user / 1.70 sys
```

Très rapide parce qu'on builde juste la target `llama-server` et ses
dépendances (libllama + libggml), pas tous les exemples.

## Dépendances runtime (ldd)

```text
llama-server requiert :
  libthr.so.3           (base FreeBSD)
  libllama.so           ← embarqué dans lib/
  libggml.so            ← embarqué dans lib/
  libc++.so.1           (base FreeBSD)
  libcxxrt.so.1         (base FreeBSD)
  libm.so.5             (base FreeBSD)
  libgcc_s.so.1         (base FreeBSD)
  libc.so.7             (base FreeBSD)
  libopenblas.so.0      ← embarqué dans lib/ (port openblas)
  libomp.so             (base FreeBSD)
  libgfortran.so.5      ← embarqué dans lib/ (gcc14, dépendance d'OpenBLAS)
  libquadmath.so.0      ← embarqué dans lib/ (gcc14)
```

Donc on **embarque 5 `.so`** dans `llama-bin/freebsd-amd64/lib/` pour
être autonomes sur OPNsense. Les autres libs (`libthr`, `libm`,
`libomp`, etc.) viennent du base system FreeBSD 14, qu'on suppose
identique sur OPNsense 26.1.

## Artefacts livrés (SHA-256)

```text
llama-server                                                 eb2e9024c69f6096f4d4b0f7cc4cd7a7b13f80cb0fdbe17162834860219a0663
lib/libgfortran.so.5                                         09f1f25910f34d59651fec3fd4fb58d67ee71989b84ffdc255124d6d83e283ba
lib/libggml.so                                               630120cb1a002e92b0d5bb88bfbbd8f480fc2d6a959f418092441aef75afd507
lib/libllama.so                                              2f923abafdd518947ae8f05f97fd0fddd024ca97c0dfd07bcf207e5d326a2855
lib/libopenblas.so.0                                         f544a5f61fe0817df3192dcac087cb802c7392ab065c8c89233805d91e26bf35
lib/libquadmath.so.0                                         7691f212d8f22e74eea1dd23429d2006eea404af699e1a964c2f3faa5fb8a363
```

Tarball intermédiaire (avant unpack côté <WORKSTATION>) :
`4743852f93de290d547819cf9a7860b26de0de5bdd21384940cc40284ab5ccae`.

## VM de build (statut)

La VM `oaf-build-freebsd` sur <LIBVIRT_HOST> est **gardée stopped** (pas
détruite) — utile si on veut rebuilder à un autre tag llama.cpp ou
compiler d'autres composants FreeBSD. Pour la réutiliser :

```bash
ssh -p 2222 root@<LIBVIRT_HOST> 'virsh start oaf-build-freebsd'
# attendre 30s puis SSH via ProxyJump :
ssh -J root@<LIBVIRT_HOST>:2222 root@192.168.230.50
```

## Pièges rencontrés (résumé, pour mémoire long terme)

- `LLAMA_BUILD_EXAMPLES=OFF` casse la target `llama-server` sur b3813.
- pkgconf n'est PAS une dépendance transitive de `openblas` chez
  FreeBSD 14.4 — il faut le `pkg install pkgconf` séparément (sinon
  cmake plante en chasse de `pkg-config`).
- Cloud-init seed iso + image BASIC-CI marche très bien sur libvirt
  <LIBVIRT_HOST> (par contre Hetzner Cloud + mfsBSD = friction).
- Le `pool DHCP` du réseau `ptm-pentest-stack-lan-1` était saturé →
  créé un network dédié `oaf-build-net` (192.168.230.0/24).
