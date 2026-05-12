# Build llama.cpp natif FreeBSD — procédure complète

> **Audience** : opérateur qui veut **reproduire** le binaire `llama-server`
> de ce repo (et donc savoir exactement ce qui tourne dans son firewall).

Cible : `llama-bin/freebsd-amd64/llama-server` exécutable sur OPNsense
(FreeBSD 14 amd64) **sans Linuxulator**.

## Software Bill of Materials (cible)

| Composant | Version | Source |
| --- | --- | --- |
| OS de build | FreeBSD 14.2-RELEASE amd64 | `ftp://ftp.freebsd.org/pub/FreeBSD/releases/amd64/14.2-RELEASE/` |
| OS cible | OPNsense 26.1.x (basé FreeBSD 14.x) | image officielle OPNsense |
| Toolchain | clang/llvm (du système, pas gcc-port) | `pkg install llvm` ou base |
| Build system | CMake ≥ 3.16, gmake | `pkg install cmake gmake` |
| BLAS | OpenBLAS | `pkg install openblas` |
| llama.cpp | **tag `b3813`** | `https://github.com/ggml-org/llama.cpp` |
| Quantization base | Phi-3 mini Q4_K_M | `microsoft/Phi-3-mini-4k-instruct-gguf` |
| LoRA | `patlegu/opnsense-agent-phi35` Q4_K_M | HuggingFace |

Le tag `b3813` de llama.cpp est figé exprès — c'est le baseline qui
corrige le bug `--lora-init-without-apply` des versions antérieures
(cf. mémoire opérateur `project_lora_wireguard_bug` ; le LoRA est
mal-appliqué sur `b1-9c69907` et antérieurs, et donne des sorties
incohérentes pour les outils OPNsense).

## Plan d'ensemble

```text
1. Spawner une VM Hetzner Cloud cpx32 (Debian rescue → mfsBSD → FreeBSD 14)
2. SSH dans la VM FreeBSD, installer les build deps (pkg)
3. git clone llama.cpp @ b3813, cmake configure + build
4. strip + tar.gz les artefacts (binaire + .so)
5. scp le tarball en local dans llama-bin/freebsd-amd64/
6. Vérifier (file, sha256), détruire la VM
```

`scripts/build-llama-freebsd.sh` automatise les étapes 2–5 *à partir
d'une VM FreeBSD déjà up*. Le bloc ci-dessous documente l'étape 1
(spawn FreeBSD sur Hetzner Cloud, manuelle) pour pouvoir refaire la
manip avec une autre infra (libvirt, baremetal, etc.).

---

## Étape 1 — Spawn d'une VM FreeBSD sur Hetzner Cloud

Hetzner Cloud n'a pas d'image FreeBSD officielle. La procédure
standard sur la communauté FreeBSD est :

1. créer une VM avec une image Linux quelconque
2. la booter en mode rescue (Debian-based)
3. `dd` une image `mfsbsd` (FreeBSD minimaliste en RAM) sur le disque
4. reboot — la VM démarre maintenant sur mfsBSD
5. installer FreeBSD complet sur le disque depuis mfsBSD
6. reboot — vraie FreeBSD installée

### 1.1 Créer la VM

```bash
hcloud server create \
    --name oaf-build-freebsd \
    --type cpx32 \
    --image debian-12 \
    --location hel1 \
    --ssh-key <NOM_DE_TA_CLE> \
    --label purpose=oaf-llama-build

IP=$(hcloud server ip oaf-build-freebsd)
echo "VM IP : $IP"
```

`cpx32` = 4 vCPU AMD + 8 GB RAM + 160 GB SSD pour ~0.012 €/h.
Hetzner Helsinki (`hel1`) parce que c'est typiquement où sont les
*-forge labs.

### 1.2 Booter en rescue + écrire mfsBSD

```bash
hcloud server enable-rescue --type linux64 oaf-build-freebsd
hcloud server reboot oaf-build-freebsd
sleep 30  # le temps que le rescue boote
ssh-keygen -R $IP
ssh -o StrictHostKeyChecking=accept-new root@$IP <<'EOF'
set -e
cd /tmp
wget -q https://mfsbsd.vx.sk/files/images/14/amd64/mfsbsd-14.2-RELEASE-amd64.img
dd if=mfsbsd-14.2-RELEASE-amd64.img of=/dev/sda bs=1M conv=fsync status=progress
sync
EOF

# Hetzner désactive le mode rescue de lui-même au prochain boot.
hcloud server reboot oaf-build-freebsd
sleep 30
```

À ce stade le disque contient mfsBSD. La VM démarre dessus.

### 1.3 Installer FreeBSD complet depuis mfsBSD

mfsBSD a un user root sans mot de passe en SSH (clé Hetzner injectée
par le script vx.sk). Sur mfsBSD :

```bash
ssh-keygen -R $IP
ssh -o StrictHostKeyChecking=accept-new root@$IP <<'EOF'
set -e
# zfsinstall = utilitaire mfsBSD qui installe FreeBSD sur le disque
zfsinstall -d /dev/ada0 -u ftp://ftp.freebsd.org/pub/FreeBSD/releases/amd64/14.2-RELEASE
# Activer SSH + DHCP au reboot
echo 'sshd_enable="YES"' >> /mnt/etc/rc.conf
echo 'ifconfig_DEFAULT="DHCP"' >> /mnt/etc/rc.conf
# Copier la clé SSH déjà autorisée sous mfsBSD
mkdir -p /mnt/root/.ssh
cp /root/.ssh/authorized_keys /mnt/root/.ssh/
shutdown -r now
EOF
```

Attendre 30-60s, puis :

```bash
ssh-keygen -R $IP
ssh -o StrictHostKeyChecking=accept-new root@$IP "uname -a"
# attendu : FreeBSD oaf-build-freebsd 14.2-RELEASE FreeBSD 14.2-RELEASE GENERIC amd64
```

---

## Étape 2 — Build (automatisé)

À partir d'ici, `scripts/build-llama-freebsd.sh` prend le relais. Mais
on documente ce qu'il fait sous le capot :

### 2.1 Install des deps via pkg

```bash
ssh root@$IP <<'EOF'
pkg update -q
pkg install -y -q git cmake gmake llvm openblas
EOF
```

| Paquet | Rôle | Version typique |
| --- | --- | --- |
| `git` | Récupération du source llama.cpp | ≥ 2.40 |
| `cmake` | Build system | ≥ 3.27 |
| `gmake` | Make GNU (llama.cpp préfère gmake à make BSD) | 4.x |
| `llvm` | Toolchain clang/clang++/lld | 18.x |
| `openblas` | BLAS pour ggml | 0.3.x |

### 2.2 Clone + configure cmake

```bash
ssh root@$IP <<'EOF'
mkdir -p /usr/home/llama-build
cd /usr/home/llama-build
git clone https://github.com/ggml-org/llama.cpp.git
cd llama.cpp
git checkout b3813
EOF
```

Configurer cmake avec les flags suivants :

```bash
cmake -B build \
    -DCMAKE_BUILD_TYPE=Release \
    -DGGML_NATIVE=ON \
    -DGGML_BLAS=ON \
    -DGGML_BLAS_VENDOR=OpenBLAS \
    -DLLAMA_BUILD_SERVER=ON \
    -DLLAMA_BUILD_EXAMPLES=OFF \
    -DLLAMA_BUILD_TESTS=OFF
```

Justification des flags :

| Flag | Raison |
| --- | --- |
| `GGML_NATIVE=ON` | Détecte les extensions CPU (AVX2/FMA) du host de build. OPNsense Hetzner cpx32/cx33 = `EPYC 7002/3` qui supportent AVX2. Si tu vises d'autres CPU, désactiver et compiler portable. |
| `GGML_BLAS=ON` + `OpenBLAS` | Accélère le prompt processing (multiplication matricielle dense). Sans, on perd ~30 % sur le prefill. |
| `LLAMA_BUILD_SERVER=ON` | C'est ce binaire qu'on veut. |
| `LLAMA_BUILD_EXAMPLES=OFF` | Skip les ~30 binaires d'exemples qu'on n'utilise pas. |
| `LLAMA_BUILD_TESTS=OFF` | Skip les tests (gain de ~2 min de build). |

### 2.3 Build

```bash
cmake --build build -j "$(sysctl -n hw.ncpu)" --config Release --target llama-server
```

`hw.ncpu` = 4 sur cpx32 → build en ~15 min.

### 2.4 Strip + collecte des artefacts

```bash
strip build/bin/llama-server build/bin/lib*.so* || true

mkdir -p /tmp/llama-out/lib
cp build/bin/llama-server /tmp/llama-out/
cp -a build/bin/lib*.so* /tmp/llama-out/lib/
tar -C /tmp/llama-out -czf /tmp/llama-freebsd-amd64.tar.gz .
```

On garde toute la chaîne de symlinks `.so → .so.0 → .so.0.X.Y` parce
que le linker FreeBSD résout en runtime.

### 2.5 Récupérer en local

```bash
scp root@$IP:/tmp/llama-freebsd-amd64.tar.gz \
    llama-bin/freebsd-amd64/
tar -C llama-bin/freebsd-amd64 -xzf llama-bin/freebsd-amd64/llama-freebsd-amd64.tar.gz
rm llama-bin/freebsd-amd64/llama-freebsd-amd64.tar.gz
```

### 2.6 Vérifier

```bash
file llama-bin/freebsd-amd64/llama-server
# attendu : ELF 64-bit LSB pie executable, x86-64, version 1 (FreeBSD)

ls -lh llama-bin/freebsd-amd64/{llama-server,lib/}
sha256sum llama-bin/freebsd-amd64/llama-server llama-bin/freebsd-amd64/lib/*.so*
```

Le hash SHA-256 du binaire est attendu **stable** pour un même tag
llama.cpp + même toolchain + même flags. On peut donc reproduire et
comparer.

---

## Étape 3 — Détruire la VM de build

```bash
hcloud server delete oaf-build-freebsd
```

Coût total pour un build typique : ~0.005 € (15 min × 0.012 €/h, plus
quelques fractions pour le rescue boot).

Tu peux aussi garder la VM stopped pour rebuilder facilement à chaque
bump de llama.cpp (`hcloud server poweroff oaf-build-freebsd`) ;
coût d'une VM stopped sur Hetzner = ~stockage seul.

---

## Reproductibilité

Pour reproduire **exactement** le binaire de ce repo :

1. Spawner FreeBSD 14.2-RELEASE amd64 (cf. étape 1).
2. `pkg update` puis `pkg install` les paquets de la SBOM.
3. Checkout llama.cpp **au tag `b3813`** (commit SHA :
   `9c69907 → tag b3813`).
4. `cmake` avec les flags exacts ci-dessus (étape 2.2).
5. Comparer `sha256sum llama-server` avec celui logué dans
   `docs/build-logs/` au build du repo (cf. log d'origine
   ci-dessous).

> 💡 **Note** : la reproductibilité bit-à-bit dépend aussi du compilateur
> (version clang, libc, etc.). En pratique on a une reproductibilité
> *fonctionnelle* (mêmes résultats) plus que *binaire stricte*.

## Logs de build versionnés

Chaque build du binaire embarqué dans le repo est associé à un log
sous `docs/build-logs/build-llama-freebsd-YYYY-MM-DD.md`, qui
contient :

- timestamp du build ;
- nom + type de la VM (cpx32, location) ;
- versions exactes des paquets installés (`pkg info -ax`) ;
- output complet de `cmake -B build -DCMAKE_*` (avec les compilers détectés) ;
- output abrégé de `cmake --build` (juste les warnings et la fin) ;
- `file` et `sha256sum` des artefacts produits.

Ce log permet à un futur opérateur de :

- vérifier qu'on n'a pas pull un compilateur cassé entre deux dates ;
- diagnostiquer une régression introduite par une nouvelle version
  d'OpenBLAS ou de clang ;
- ne pas avoir à *deviner* ce qui se trouve dans le binaire.

## Alternative : libvirt sur korrig

Si tu as un host libvirt (`korrig` par convention dans cet écosystème),
le module `iac-modules/libvirt/freebsd-vm` (à créer en upstream)
spawne une VM FreeBSD 14 locale gratuite. Procédure plus rapide et
sans coût Hetzner, mais nécessite le host libvirt.

## Pourquoi pas un Docker FreeBSD ?

Les images "FreeBSD" sur Docker Hub tournent via qemu-user-static ou
en jail Linux — pas exécutables sans host FreeBSD. Aucun gain par
rapport à la VM Hetzner jetable.
