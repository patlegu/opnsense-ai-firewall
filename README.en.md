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
| `TOOLS_CATALOG` coverage | 72 / ~370 LoRA-known functions (extensible via overrides; see `agents/opnsense/_*.py` in the training repo) |

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

## Topology

```text
Internet
    │
    ▼
┌───────────────────────────────────────────────────────┐
│  Hetzner Cloud — cx33 (8 GB) or cx43 (16 GB)          │
│                                                       │
│  ┌─────────────────────────────────────────────────┐  │
│  │  OPNsense 26.x (FreeBSD 14)                     │  │
│  │  ┌───────────────────────────────────────────┐  │  │
│  │  │ llama-server                              │  │  │
│  │  │   bind 127.0.0.1:8080                     │  │  │
│  │  │   Phi-3 mini Q4_K_M + opnsense_agent LoRA │  │  │
│  │  └─────────────────┬─────────────────────────┘  │  │
│  │                    │ local HTTP                  │  │
│  │  ┌─────────────────▼─────────────────────────┐  │  │
│  │  │ local agent (Python)                      │  │  │
│  │  │   intent → CAP v1 → tool_call             │  │  │
│  │  │   → OPNsense API 127.0.0.1:4443           │  │  │
│  │  │   scope_confirmed guard on any mutating   │  │  │
│  │  └───────────────────────────────────────────┘  │  │
│  │                                                 │  │
│  │   pf · NAT · DHCP · DNS · …                     │  │
│  └─────────────────────────────────────────────────┘  │
│                                                       │
└───────────────────────────────────────────────────────┘
```

No sidecar, no cleartext LLM traffic on the network, no external
port tied to the LLM (always `127.0.0.1`). The local agent and
`llama-server` share the same CPU/RAM as `pf`.

## Quickstart

```bash
# 1. Clone + secrets
git clone https://github.com/patlegu/opnsense-ai-firewall.git
cd opnsense-ai-firewall

# 1a. .env at the repo root — HCLOUD_TOKEN required, TF_HTTP_* if
#     GitLab Managed Terraform State backend is enabled.
cat > .env <<'EOF'
HCLOUD_TOKEN=hcloud_xxxxx
# TF_HTTP_USERNAME=patlegu
# TF_HTTP_PASSWORD=glpat-xxx
EOF

# 1b. tfvars: only deployment-specific secrets (hashes, public key,
#     OPNsense API). hcloud_token is NOT required here — it's read
#     from the HCLOUD_TOKEN environment variable (see 1a).
cp infra/envs/hcloud/terraform.tfvars.example \
   infra/envs/hcloud/terraform.tfvars
# Fill in: ssh_public_keys, vm_password_hash, opnsense_root_hash, …

bash scripts/init-secrets.sh --auto

# 2. Build llama.cpp for FreeBSD (stage B — one-time)
bash scripts/build-llama-freebsd.sh
# produces llama-bin/freebsd-amd64/{llama-server, lib/*.so}

# 3. Deploy
set -a && . .env && set +a   # load HCLOUD_TOKEN into Tofu's env
cd infra/envs/hcloud
tofu init && tofu apply

# 4. Verify the agent responds
ssh -p 2222 root@<OPNSENSE_IP> 'curl -s http://127.0.0.1:8080/health'
```

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
