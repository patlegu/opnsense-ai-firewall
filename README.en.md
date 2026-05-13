# opnsense-ai-firewall

[🇫🇷 Français](README.md) · 🇬🇧 **English**

**Experimental** — deploys a Hetzner Cloud OPNsense VM with an
embedded LLM (FreeBSD-native `llama-server` + Phi-3 OPNsense LoRA)
that drives its own REST API from *inside* the VM. **No sidecar.**

> ⚠️ **Lab use only.** This topology is deliberately discouraged in
> production (see [`docs/why-not-in-prod.md`](docs/why-not-in-prod.md)
> for the 4 concrete reasons: attack surface, CPU contention,
> lifecycle drift, audit). The point of this repo is to **measure**
> how bad an idea this is and where the thresholds are.

## Status — proof-of-concept validated (May 2026)

| Component | Status |
| --- | --- |
| Native FreeBSD `llama-server` | ✅ Build `b9000` (see [`docs/build-logs/`](docs/build-logs/)) |
| `llama` rc.d service | ✅ Strict bind `127.0.0.1:8080`, daemon(8) |
| Local agent `oaf-agent` | ✅ Python 3.13, wrapper at `/usr/local/bin/oaf-agent` |
| Intent → tool_call → API (read) | ✅ `oaf-agent ask "Show system information"` → OPNsense JSON |
| Intent → tool_call → API (write) | ✅ `oaf-agent ask "Block IP 1.2.3.4 on WAN" --confirm` → pf rule created with UUID |
| Intent → response latency | ~10 s on cx33 (4 vCPU CPU-only) |
| `TOOLS_CATALOG` coverage | **101 / 102** canonical functions (verify v7) dispatched: 97 auto-resolved via `scripts/generate-tools-catalog.py` + 4 local overrides; only `import_alias` remains (no native OPNsense REST endpoint) |

Detailed demo and test logs: [`docs/demo-results.md`](docs/demo-results.md).

Forked from `kickstart-forge` (private Hetzner Cloud template).

> **Public GitHub note**: this repo depends on the private Tofu
> module `iac-modules` (hosted on a private GitLab) for the
> `hcloud/{network,opnsense,debian,agent}` + `wireguard-mesh` modules.
> Without access to that module, `tofu apply` won't run. The repo is
> published as a **pattern demonstration** (in-box LLM + local agent
> + tool-calling against the OPNsense API), not as a ready-to-run
> turnkey infrastructure. To reproduce fully, adapt the
> `source = "git::ssh://..."` blocks in `main.tf` to your own Tofu
> modules (the interface contracts are documented in
> `infra/envs/hcloud/variables.tf`).

## What you actually need to run the GGUF

**Three ingredients**, nothing more:

1. **An OPNsense VM** — any source, any host (Hetzner Cloud, local
   libvirt, bare-metal, home lab…). Recommended: 26.1.x amd64
   (FreeBSD 14). At least 8 GB of RAM to fit the model (~2.4 GB) +
   `pf` + the rest of the VM.
2. **`llama-server` compiled for FreeBSD** — binary + 6 `.so`
   embedded (`libllama`, `libggml*`, `libopenblas`, `libgfortran`,
   `libquadmath`). This is the main effort of the repo, see
   [`docs/build-llama-freebsd.md`](docs/build-llama-freebsd.md).
   Tag `llama.cpp` ≥ b9000 (for native `tools` support + `--jinja`).
3. **The merged Phi-3+LoRA GGUF**: [`patlegu/opnsense-agent-phi35-q4_k_m.gguf`](https://huggingface.co/patlegu/opnsense-agent-phi35/resolve/main/opnsense-agent-phi35-q4_k_m.gguf)
   on Hugging Face (~2.4 GB, Q4_K_M, already fused — no `--lora`
   needed).

Plus, on the OPNsense side, **Python 3.11+** (`pkg install python311`)
for the local agent. That's it.

With those 3 in place, the `intent → tool_call → OPNsense API`
pipeline works on any OPNsense. The Hetzner / Tofu infra further
down is **only an automation convenience**, not the core feature.

## Topology

```text
┌─────────────────────────────────────────────────┐
│  OPNsense 26.x (FreeBSD 14)                     │
│  ┌───────────────────────────────────────────┐  │
│  │ llama-server (FreeBSD native, b9000+)     │  │
│  │   bind 127.0.0.1:8080                     │  │
│  │   merged Phi-3 mini Q4_K_M + OPNsense LoRA│  │
│  └─────────────────┬─────────────────────────┘  │
│                    │ local HTTP                  │
│  ┌─────────────────▼─────────────────────────┐  │
│  │ local agent (Python 3.11)                 │  │
│  │   NL intent → tool_call (101/102)         │  │
│  │   → OPNsense API 127.0.0.1:4443           │  │
│  │   scope_confirmed guard on any mutating   │  │
│  └───────────────────────────────────────────┘  │
│                                                 │
│   pf · NAT · DHCP · DNS · …                     │
└─────────────────────────────────────────────────┘
```

No sidecar, no cleartext LLM traffic on the network, no external
port tied to the LLM (always `127.0.0.1`). The local agent and
`llama-server` share the same CPU/RAM as `pf`.

## Manual install on any OPNsense

If you already have an OPNsense up and the artefacts compiled
(see previous section):

```bash
# From your workstation
OPNSENSE_IP="<YOUR_OPNSENSE_IP>"

# 1. SCP the FreeBSD artefacts + agent
scp -P 2222 llama-bin/freebsd-amd64/llama-server \
            root@${OPNSENSE_IP}:/var/llm/bin/
scp -P 2222 llama-bin/freebsd-amd64/lib.tar.gz \
            root@${OPNSENSE_IP}:/tmp/
scp -P 2222 agent/oaf_agent.py agent/tools_catalog.py \
            root@${OPNSENSE_IP}:/var/llm/agent/

# 2. On the OPNsense VM: prepare, download the GGUF, configure rc.d
ssh -p 2222 root@${OPNSENSE_IP} /bin/sh <<'EOF'
set -e
mkdir -p /var/llm/{bin,lib,models,agent} /var/log/llama
tar -C /var/llm/lib -xzf /tmp/lib.tar.gz
chmod +x /var/llm/bin/llama-server
pkg install -y python311
fetch --no-verify-hostname \
    -o /var/llm/models/opnsense-agent-phi35-q4_k_m.gguf \
    https://huggingface.co/patlegu/opnsense-agent-phi35/resolve/main/opnsense-agent-phi35-q4_k_m.gguf
EOF

# 3. rc.d service + agent env (templates in infra/envs/hcloud/templates/)
#    Adapt rc-llama.tftpl and post-install-llm.sh.tftpl with your values,
#    push to /usr/local/etc/rc.d/llama + /etc/oaf-agent.env, then:
ssh -p 2222 root@${OPNSENSE_IP} 'service llama start && oaf-agent health'
```

Expected output:

```text
[oaf] llama-server : 200 {"status":"ok"}
[oaf] OPNsense API OK : keys=['name', 'versions', 'updates']
```

From there, `oaf-agent ask "Show system information"` returns OPNsense
JSON, `oaf-agent ask "Block IP 1.2.3.4 on WAN" --confirm` creates a
real `pf` rule. See [`docs/demo-results.md`](docs/demo-results.md) for
validation traces.

## Hetzner automation (Tofu, optional)

If you deploy on **Hetzner Cloud** and want everything in one command,
the Tofu code under `infra/envs/hcloud/` automates the steps above
(VM creation + SCP artefacts + rc.d + healthcheck). It **depends on
the private `iac-modules` module** (see the public-GitHub note at the
top), so reproducing it elsewhere requires adapting the module
sources. This is the "Hetzner lab" angle of the repo, not the core
feature.

<details>
<summary>Tofu Hetzner quickstart (expand)</summary>

```bash
# .env at the repo root
cat > .env <<'EOF'
HCLOUD_TOKEN=hcloud_xxxxx
EOF

# tfvars: deployment-specific secrets
cp infra/envs/hcloud/terraform.tfvars.example \
   infra/envs/hcloud/terraform.tfvars
# Fill in ssh_public_keys, vm_password_hash, etc.
bash scripts/init-secrets.sh --auto

# Build llama.cpp FreeBSD (one-time)
bash scripts/build-llama-freebsd.sh root@<FREEBSD_VM_IP>

# Deploy
set -a && . .env && set +a
cd infra/envs/hcloud && tofu init && tofu apply
```

</details>

## Components

| Component | Default |
| --- | --- |
| VM | `cx33` (4 vCPU / 8 GB) |
| OS | OPNsense 26.1.x amd64 (FreeBSD 14) |
| Base LLM | `microsoft/Phi-3-mini-4k-instruct-gguf` Q4_K_M (~2.5 GB) |
| LoRA | [`patlegu/opnsense-agent-phi35`](https://huggingface.co/patlegu/opnsense-agent-phi35) (~480 MB, merged) |
| Runtime | `llama-server`, compiled natively for FreeBSD (stage B) |
| LLM port | `127.0.0.1:8080` (never exposed on WAN) |
| OPNsense API port | `4443` (WAN, restricted by alias) |
| OPNsense SSH port | `2222` (never 22 — reserved for Cowrie if T-Pot is added later) |

## Security — non-goals

This repo **does NOT try to**:

- make OPNsense a production-grade system with an embedded LLM;
- shrink the attack surface added by `llama-server`;
- guarantee pf latency under LLM load;
- audit the agent → API call chain (every mutating action goes
  through a `scope_confirmed` flag, but that is just an operator
  guardrail, not an anti-malicious control).

If you want this topology in production, look at the
"sidecar VM + vanilla OPNsense" patterns — much saner. Some
implementations exist (private) in the internal `*-forge` ecosystem;
the public pattern boils down to: a Debian VM with `llama-server`,
plus a Python agent talking to the OPNsense API over HTTPS.

## Documentation

- [`docs/why-not-in-prod.md`](docs/why-not-in-prod.md) — the 4
  concrete reasons (in French)
- [`docs/build-llama-freebsd.md`](docs/build-llama-freebsd.md) —
  native FreeBSD compilation (stage B, in French)
- [`docs/embedded-llm.md`](docs/embedded-llm.md) — rc.d service +
  local agent architecture (in French)
- [`docs/demo-results.md`](docs/demo-results.md) — real-world demo
  traces (read + write, in French)
- [`docs/access-credentials.md`](docs/access-credentials.md) —
  inherited from kickstart: secrets / SSH / OPNsense API (in French)

> The detailed documentation is currently in French. Translation
> requests welcome — open an issue if a specific doc is blocking you.

## Origin

Spawned from `kickstart-forge` (internal template) using the
`*-forge` naming convention (3-letter prefix = `oaf`). Everything
that is not specific to the in-box LLM comes from the kickstart;
LLM-specific code lives in `docs/embedded-llm.md` and the
`opnsense_llm_*` Tofu variables.
