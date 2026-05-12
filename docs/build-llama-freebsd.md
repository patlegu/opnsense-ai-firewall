# Build llama.cpp natif FreeBSD (palier B)

Objectif : produire `llama-bin/freebsd-amd64/llama-server` et les
`.so` requises, exécutables sur OPNsense (FreeBSD 14 amd64) **sans
Linuxulator**.

Cible llama.cpp : **tag `b3813`** (cohérent avec l'écosystème
`*-forge`, corrige le bug `--lora-init-without-apply` des builds
antérieurs ; cf. mémoire `project_lora_wireguard_bug`).

## Pourquoi pas plus simple ?

- Hetzner Cloud n'a pas d'image FreeBSD officielle (Robot oui, Cloud non).
- `pkg install llama-cpp` n'est pas garanti dans le repo
  d'OPNsense (qui suit FreeBSD 14 release avec retard).
- Cross-compile depuis Linux exige les headers FreeBSD complets +
  une libc compatible — plus de friction que de gain pour un build
  one-shot par tag.

Le compromis : spawner une **VM FreeBSD jetable** une seule fois,
builder, récupérer les artefacts, détruire la VM.

## Étape 1 — Spawner une VM FreeBSD jetable sur Hetzner

Hetzner Cloud ne propose pas FreeBSD nativement. Procédure mfsBSD
via rescue :

```bash
# 1. Créer la VM en rescue mode (Linux Debian rescue)
hcloud server create \
    --name oaf-build-freebsd \
    --type cx22 \
    --image debian-12 \
    --location hel1 \
    --ssh-key "$(hcloud ssh-key list -o columns=name -o noheader | head -1)"

IP=$(hcloud server ip oaf-build-freebsd)

# 2. Booter en rescue + install mfsBSD
hcloud server enable-rescue oaf-build-freebsd
hcloud server reboot oaf-build-freebsd

# Attendre 30s puis SSH en rescue
ssh root@$IP <<'EOF'
cd /tmp
wget -q https://mfsbsd.vx.sk/files/images/14/amd64/mfsbsd-14.2-RELEASE-amd64.img
dd if=mfsbsd-14.2-RELEASE-amd64.img of=/dev/sda bs=1M conv=fsync
reboot
EOF

# 3. Attendre 60s, SSH sur mfsBSD (mot de passe : mfsroot)
ssh-keygen -R $IP
ssh root@$IP   # mot de passe : mfsroot

# 4. Installer FreeBSD sur le disque (depuis mfsBSD en RAM)
# Dans la session mfsBSD :
zfsinstall -d /dev/ada0 -u ftp://ftp.freebsd.org/pub/FreeBSD/releases/amd64/14.2-RELEASE
echo 'sshd_enable="YES"' >> /mnt/etc/rc.conf
echo 'ifconfig_DEFAULT="DHCP"' >> /mnt/etc/rc.conf
mkdir -p /mnt/root/.ssh
cp ~/.ssh/authorized_keys /mnt/root/.ssh/
reboot
```

À ce stade tu as une vraie VM FreeBSD 14 jetable.

> 💡 **Alternative plus rapide** : si tu as accès à un host libvirt
> (ex: korrig), spawne une VM FreeBSD via le module Tofu
> `iac-modules/libvirt/freebsd-vm` (à créer) — coût zéro, isolation
> totale, image FreeBSD officielle direct.

## Étape 2 — Lancer le build (remote)

Depuis ton poste opérateur :

```bash
bash scripts/build-llama-freebsd.sh root@<IP_VM>
```

Le script :

1. SSH vers la VM et installe les paquets via `pkg`
   (`git`, `cmake`, `gmake`, `gcc` ou `llvm`).
2. Clone llama.cpp@b3813.
3. `cmake -DGGML_NATIVE=ON && cmake --build build -j$(sysctl -n hw.ncpu)`.
4. Stripe les binaires, tar.gz le résultat
   (`llama-server` + `lib/*.so`).
5. `scp` le tarball en local dans `llama-bin/freebsd-amd64/`.
6. Désarchive sur place.

Durée typique : **20-30 min** sur cx22 (2 vCPU).

## Étape 3 — Vérifier le binaire

```bash
file llama-bin/freebsd-amd64/llama-server
# attendu : ELF 64-bit LSB pie executable, x86-64, version 1 (FreeBSD)

ls -lh llama-bin/freebsd-amd64/
# attendu :
#   llama-server  ~10 MB
#   lib/
#     libggml.so       ~1 MB
#     libggml-base.so  ~500 KB
#     libggml-cpu.so   ~600 KB
#     libllama.so      ~1.5 MB
```

## Étape 4 — Détruire la VM de build

```bash
hcloud server delete oaf-build-freebsd
```

Tu peux la garder stopped si tu prévois de re-builder fréquemment
(bumps de llama.cpp). Coût d'une VM stopped sur Hetzner = environ
0 (seulement le stockage).

## Tag bumps

Pour passer à un tag llama.cpp plus récent (ex: `b4500`) :

1. `LLAMA_TAG=b4500 bash scripts/build-llama-freebsd.sh root@<IP_VM>`
2. Tester en local le bon démarrage : voir
   [`docs/embedded-llm.md`](embedded-llm.md).
3. Commiter le bump du tag dans le script.
4. Re-uploader les artefacts vers GitLab Generic Packages (palier C
   gère ça via `scripts/upload-llm-assets.sh`).

## Pourquoi pas un Docker FreeBSD ?

Il existe des conteneurs FreeBSD (`freebsd/freebsd-runner` etc.) mais
ils tournent en Linux jail/qemu-user-static — pas exécutables sans
host FreeBSD. Aucun gain par rapport à la VM jetable.
