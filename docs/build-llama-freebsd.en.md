# Native FreeBSD llama.cpp build — full procedure

> **Audience**: operator who wants to **reproduce** the `llama-server`
> binary in this repo (and therefore know exactly what is running in
> their firewall).

Target: `llama-bin/freebsd-amd64/llama-server` executable on OPNsense
(FreeBSD 14 amd64) **without Linuxulator**.

## Software Bill of Materials (target)

| Component | Version | Source |
| --- | --- | --- |
| Build OS | FreeBSD 14.2-RELEASE amd64 | `ftp://ftp.freebsd.org/pub/FreeBSD/releases/amd64/14.2-RELEASE/` |
| Target OS | OPNsense 26.1.x (based on FreeBSD 14.x) | official OPNsense image |
| Toolchain | clang/llvm (system, not gcc-port) | `pkg install llvm` or base |
| Build system | CMake >= 3.16, gmake | `pkg install cmake gmake` |
| BLAS | OpenBLAS | `pkg install openblas` |
| llama.cpp | **tag `b3813`** | `https://github.com/ggml-org/llama.cpp` |
| Base quantization | Phi-3 mini Q4_K_M | `microsoft/Phi-3-mini-4k-instruct-gguf` |
| LoRA | `patlegu/opnsense-agent-phi35` Q4_K_M | HuggingFace |

The llama.cpp tag `b3813` is pinned on purpose — it is the baseline
that fixes the `--lora-init-without-apply` bug from earlier versions
(see operator memory `project_lora_wireguard_bug`; the LoRA is
mis-applied on `b1-9c69907` and earlier, and produces incoherent
output for OPNsense tools).

## Overall plan

```text
1. Spawn a Hetzner Cloud cpx32 VM (Debian rescue -> mfsBSD -> FreeBSD 14)
2. SSH into the FreeBSD VM, install build deps (pkg)
3. git clone llama.cpp @ b3813, cmake configure + build
4. strip + tar.gz the artifacts (binary + .so)
5. scp the tarball locally into llama-bin/freebsd-amd64/
6. Verify (file, sha256), destroy the VM
```

`scripts/build-llama-freebsd.sh` automates steps 2-5 *starting from
a FreeBSD VM that is already up*. The block below documents step 1
(spawning FreeBSD on Hetzner Cloud, manual) so the procedure can be
redone on a different infra (libvirt, baremetal, etc.).

---

## Step 1 — Spawn a FreeBSD VM on Hetzner Cloud

Hetzner Cloud does not have an official FreeBSD image. The standard
procedure in the FreeBSD community is:

1. create a VM with any Linux image
2. boot it in rescue mode (Debian-based)
3. `dd` an `mfsbsd` image (minimal FreeBSD in RAM) onto the disk
4. reboot — the VM now boots on mfsBSD
5. install full FreeBSD on the disk from mfsBSD
6. reboot — real FreeBSD installed

### 1.1 Create the VM

```bash
hcloud server create \
    --name oaf-build-freebsd \
    --type cpx32 \
    --image debian-12 \
    --location hel1 \
    --ssh-key <YOUR_KEY_NAME> \
    --label purpose=oaf-llama-build

IP=$(hcloud server ip oaf-build-freebsd)
echo "VM IP: $IP"
```

`cpx32` = 4 vCPU AMD + 8 GB RAM + 160 GB SSD for ~0.012 EUR/h.
Hetzner Helsinki (`hel1`) because that's typically where the
*-forge labs live.

### 1.2 Boot in rescue + write mfsBSD

```bash
hcloud server enable-rescue --type linux64 oaf-build-freebsd
hcloud server reboot oaf-build-freebsd
sleep 30  # time for rescue to boot
ssh-keygen -R $IP
ssh -o StrictHostKeyChecking=accept-new root@$IP <<'EOF'
set -e
cd /tmp
wget -q https://mfsbsd.vx.sk/files/images/14/amd64/mfsbsd-14.2-RELEASE-amd64.img
dd if=mfsbsd-14.2-RELEASE-amd64.img of=/dev/sda bs=1M conv=fsync status=progress
sync
EOF

# Hetzner disables rescue mode on its own at the next boot.
hcloud server reboot oaf-build-freebsd
sleep 30
```

At this point the disk contains mfsBSD. The VM boots on it.

### 1.3 Install full FreeBSD from mfsBSD

mfsBSD has a passwordless root user over SSH (Hetzner key injected
by the vx.sk script). On mfsBSD:

```bash
ssh-keygen -R $IP
ssh -o StrictHostKeyChecking=accept-new root@$IP <<'EOF'
set -e
# zfsinstall = mfsBSD utility that installs FreeBSD on disk
zfsinstall -d /dev/ada0 -u ftp://ftp.freebsd.org/pub/FreeBSD/releases/amd64/14.2-RELEASE
# Enable SSH + DHCP on reboot
echo 'sshd_enable="YES"' >> /mnt/etc/rc.conf
echo 'ifconfig_DEFAULT="DHCP"' >> /mnt/etc/rc.conf
# Copy the SSH key already authorized under mfsBSD
mkdir -p /mnt/root/.ssh
cp /root/.ssh/authorized_keys /mnt/root/.ssh/
shutdown -r now
EOF
```

Wait 30-60s, then:

```bash
ssh-keygen -R $IP
ssh -o StrictHostKeyChecking=accept-new root@$IP "uname -a"
# expected: FreeBSD oaf-build-freebsd 14.2-RELEASE FreeBSD 14.2-RELEASE GENERIC amd64
```

---

## Step 2 — Build (automated)

From here on, `scripts/build-llama-freebsd.sh` takes over. But we
document what it does under the hood:

### 2.1 Install deps via pkg

```bash
ssh root@$IP <<'EOF'
pkg update -q
pkg install -y -q git cmake gmake llvm openblas
EOF
```

| Package | Role | Typical version |
| --- | --- | --- |
| `git` | Fetch llama.cpp source | >= 2.40 |
| `cmake` | Build system | >= 3.27 |
| `gmake` | GNU make (llama.cpp prefers gmake over BSD make) | 4.x |
| `llvm` | clang/clang++/lld toolchain | 18.x |
| `openblas` | BLAS for ggml | 0.3.x |

### 2.2 Clone + cmake configure

```bash
ssh root@$IP <<'EOF'
mkdir -p /usr/home/llama-build
cd /usr/home/llama-build
git clone https://github.com/ggml-org/llama.cpp.git
cd llama.cpp
git checkout b3813
EOF
```

Configure cmake with these flags:

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

Flag rationale:

| Flag | Reason |
| --- | --- |
| `GGML_NATIVE=ON` | Detects CPU extensions (AVX2/FMA) of the build host. OPNsense Hetzner cpx32/cx33 = `EPYC 7002/3` which support AVX2. If you target other CPUs, disable and compile portable. |
| `GGML_BLAS=ON` + `OpenBLAS` | Speeds up prompt processing (dense matrix multiplication). Without it, you lose ~30% on prefill. |
| `LLAMA_BUILD_SERVER=ON` | This is the binary we want. |
| `LLAMA_BUILD_EXAMPLES=OFF` | Skip the ~30 example binaries we don't use. |
| `LLAMA_BUILD_TESTS=OFF` | Skip tests (saves ~2 min of build time). |

### 2.3 Build

```bash
cmake --build build -j "$(sysctl -n hw.ncpu)" --config Release --target llama-server
```

`hw.ncpu` = 4 on cpx32 -> build in ~15 min.

### 2.4 Strip + collect artifacts

```bash
strip build/bin/llama-server build/bin/lib*.so* || true

mkdir -p /tmp/llama-out/lib
cp build/bin/llama-server /tmp/llama-out/
cp -a build/bin/lib*.so* /tmp/llama-out/lib/
tar -C /tmp/llama-out -czf /tmp/llama-freebsd-amd64.tar.gz .
```

We keep the whole symlink chain `.so -> .so.0 -> .so.0.X.Y` because
the FreeBSD linker resolves at runtime.

### 2.5 Fetch locally

```bash
scp root@$IP:/tmp/llama-freebsd-amd64.tar.gz \
    llama-bin/freebsd-amd64/
tar -C llama-bin/freebsd-amd64 -xzf llama-bin/freebsd-amd64/llama-freebsd-amd64.tar.gz
rm llama-bin/freebsd-amd64/llama-freebsd-amd64.tar.gz
```

### 2.6 Verify

```bash
file llama-bin/freebsd-amd64/llama-server
# expected: ELF 64-bit LSB pie executable, x86-64, version 1 (FreeBSD)

ls -lh llama-bin/freebsd-amd64/{llama-server,lib/}
sha256sum llama-bin/freebsd-amd64/llama-server llama-bin/freebsd-amd64/lib/*.so*
```

The binary's SHA-256 hash is expected to be **stable** for a given
llama.cpp tag + same toolchain + same flags. So we can reproduce and
compare.

---

## Step 3 — Destroy the build VM

```bash
hcloud server delete oaf-build-freebsd
```

Total cost for a typical build: ~0.005 EUR (15 min x 0.012 EUR/h, plus
a few fractions for the rescue boot).

You can also keep the VM stopped to rebuild easily on every llama.cpp
bump (`hcloud server poweroff oaf-build-freebsd`); the cost of a
stopped VM on Hetzner = ~storage only.

---

## Reproducibility

To reproduce the binary in this repo **exactly**:

1. Spawn FreeBSD 14.2-RELEASE amd64 (see step 1).
2. `pkg update` then `pkg install` the packages in the SBOM.
3. Checkout llama.cpp **at tag `b3813`** (commit SHA:
   `9c69907 -> tag b3813`).
4. `cmake` with the exact flags above (step 2.2).
5. Compare `sha256sum llama-server` with the one logged in
   `docs/build-logs/` at the repo build time (see original log
   below).

> 💡 **Note**: bit-for-bit reproducibility also depends on the
> compiler (clang version, libc, etc.). In practice we have
> *functional* reproducibility (same results) more than *strict
> binary* reproducibility.

## Versioned build logs

Every build of the binary embedded in the repo is associated with a
log under `docs/build-logs/build-llama-freebsd-YYYY-MM-DD.md`, which
contains:

- build timestamp;
- VM name + type (cpx32, location);
- exact versions of installed packages (`pkg info -ax`);
- full output of `cmake -B build -DCMAKE_*` (with detected compilers);
- shortened output of `cmake --build` (only warnings and the end);
- `file` and `sha256sum` of produced artifacts.

This log lets a future operator:

- verify we didn't pull a broken compiler between two dates;
- diagnose a regression introduced by a new version of OpenBLAS or
  clang;
- not have to *guess* what's inside the binary.

## Alternative: libvirt on <LIBVIRT_HOST>

If you have a libvirt host (`<LIBVIRT_HOST>` by convention in this
ecosystem), the `iac-modules/libvirt/freebsd-vm` module (to be created
upstream) spawns a free local FreeBSD 14 VM. Faster procedure with no
Hetzner cost, but requires the libvirt host.

## Pitfalls observed (real pain)

Compilation of notes taken during the May 2026 attempts — consult
before re-running the procedure to save time.

### 1. The "root@<WORKSTATION>" SSH key registered with Hetzner didn't match the local key

Multiple ed25519 keys with the same name in `hcloud ssh-key list`
came from different machines. Check `ssh-keygen -lf
~/.ssh/id_ed25519.pub` and compare with `hcloud ssh-key describe <NAME>`
**before** spawning the VM. Otherwise you lose 5 min recreating.

### 2. `ifconfig_DEFAULT="DHCP"` is not enough on FreeBSD 14.4

On reboot after `zfsinstall`, the network doesn't come up if you only
have `ifconfig_DEFAULT="DHCP"`. Explicitly use the detected interface
(`ifconfig vtnet0` under mfsBSD):

```sh
ifconfig_vtnet0="DHCP"
```

### 3. Default `PermitRootLogin` on FreeBSD blocks key-based SSH

FreeBSD 14.4 ships an `sshd_config` with `PermitRootLogin no` (or
`prohibit-password`). On reboot, port 22 answers but key auth is
refused for root. Add before shutdown:

```sh
sed -i '' 's/^#PermitRootLogin .*/PermitRootLogin yes/' /mnt/etc/ssh/sshd_config
```

### 4. The Hetzner Linux rescue does not mount ZFS easily

If you want to edit the installed system from rescue (because you
forgot a fix before reboot), installing `zfsutils-linux` in the
Debian rescue often fails on interactive acceptance of the CDDL/GPL
license. It's faster to redo the mfsBSD install than to debug that.

### 5. FreeBSD 14.2 gone from the download.freebsd.org mirror

mfsBSD vx.sk ships a 14.2 kernel, but the 14.2 user-land is no longer
on `download.freebsd.org` (release cycle: only n-1/n/n+1 are hosted).
Use **14.4-RELEASE** as `zfsinstall -u` target. OPNsense 26.1.x is on
FreeBSD 14.x so OK.

### 6. Recommendation: if it's a pain, use the noVNC console

Open <https://console.hetzner.cloud> -> your VM -> "Console" puts a
serial console in the browser. You can see the FreeBSD boot live,
correct via `mfsroot` login or in single-user. Much faster than a
script polling blindly.

### Validated strategy to re-run B next time

1. `hcloud server create ... --ssh-key claude-shell-local` (registered local key).
2. Rescue + dd mfsBSD -> reboot.
3. SSH mfsBSD (`sshpass -p mfsroot ssh ...`).
4. `gpart destroy -F /dev/da0 && zfsinstall -d /dev/da0 -u <URL_14.4>`.
5. **BEFORE reboot**, from mfsBSD:
   - `cat >> /mnt/etc/rc.conf` with `ifconfig_vtnet0="DHCP"`,
     `hostname`, `sshd_enable="YES"`.
   - `sed` PermitRootLogin yes in /mnt/etc/ssh/sshd_config.
   - copy the pubkey to `/mnt/root/.ssh/authorized_keys` (chmod 600).
6. `shutdown -r now`, wait 60-90 s.
7. SSH by key -> `bash scripts/build-llama-freebsd.sh root@<IP>`.

## Why not a Docker FreeBSD?

"FreeBSD" images on Docker Hub run via qemu-user-static or in a Linux
jail — not executable without a FreeBSD host. No gain compared to the
disposable Hetzner VM.
