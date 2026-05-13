# opnsense-ai-firewall

[🇫🇷 Français](README.md) · 🇬🇧 **English**

**Experimental** — deploys a Hetzner Cloud OPNsense VM with an
embedded LLM (FreeBSD-native `llama-server` + Phi-3 OPNsense LoRA)
that drives its own REST API from *inside* the VM. **No sidecar.**

> ⚠️ **Lab use only.** This topology is deliberately discouraged in
> production (see [`docs/why-not-in-prod.en.md`](docs/why-not-in-prod.en.md)
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

Detailed demo and test logs: [`docs/demo-results.en.md`](docs/demo-results.en.md).

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
   [`docs/build-llama-freebsd.en.md`](docs/build-llama-freebsd.en.md).
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

## How it actually works (and where the LLM does the real work)

Fair question: *"the repo has a Python dispatcher, a catalog of
116 endpoints and payload adapters — what does the LLM actually
do?"*

The LLM does the **non-mechanical** part. The rest of the repo is
just the wiring between what the LoRA produces and the OPNsense
REST API. Full end-to-end example:

### Step 1 — Human writes a natural-language intent

```bash
oaf-agent ask "Block IP 1.2.3.4 on WAN" --confirm
```

### Step 2 — The Phi-3 LoRA does 4 non-trivial things

The agent sends to the LoRA:

- the text intent `"Block IP 1.2.3.4 on WAN"`
- the list of 116 available tools with their descriptions
  (`get_cron_jobs`, `add_filter_rule`, `block_ip`,
  `restart_unbound`, …)

The model (Phi-3 mini + `opnsense-agent-phi35` LoRA, fine-tuned
on ~13,700 intent → tool_call examples) produces:

```text
<|tool_calls|>
[{"id": "call_…",
  "type": "function",
  "function": {
    "name": "block_ip",
    "arguments": "{\"ip\": \"1.2.3.4\", \"interface\": \"wan\"}"
  }}]
```

These 4 decisions are **the interesting work**:

1. **Intent understanding** — "Block IP" means blocking, not
   adding an alias, not NAT, not a route. Distinguishing among
   ~10 OPNsense action families from a free-form sentence.
2. **Right tool selection** — among 116 tools in context, pick
   `block_ip` (and not raw `add_filter_rule`, nor `add_to_alias`).
   The LoRA learned that mapping during fine-tuning.
3. **Structured parameter extraction** — spot that `1.2.3.4` is
   the target IP, that `WAN` means the interface, and emit clean
   JSON. Non-trivial: the intent doesn't say `interface=wan`, the
   LoRA infers.
4. **OpenAI tool_call formatting** — emit the response in the
   structure the agent can parse. The LoRA respects the format
   it was trained on (Phi-3 special tokens `<|tool_calls|>` …
   `<|tool_response|>`).

### Step 3 — The plumbing (mechanical, this is the repo)

Once the `tool_call` is produced, the agent does **pure routing**,
no intelligence:

- Lookup in `TOOLS_EFFECTIVE["block_ip"]` →
  `("POST", "/api/firewall/filter/addRule", mutating=True)`
- `mutating=True` + `--confirm` present → proceed
- `ARG_ADAPTERS["block_ip"]({"ip": "1.2.3.4", ...})` produces the
  actual OPNsense payload:

```json
{"rule": {
  "enabled": "1", "action": "block", "interface": "wan",
  "direction": "in", "ipprotocol": "inet", "protocol": "any",
  "source_net": "1.2.3.4", "destination_net": "any",
  "description": "Blocked by oaf-agent"
}}
```

- HTTPS POST to `127.0.0.1:4443` with Basic auth
- OPNsense creates the `pf` rule and returns `{"result": "saved",
  "uuid": "..."}`

### Without the LoRA, doing the same thing by hand requires

1. Knowing that "blocking an IP" goes through the `firewall/filter`
   module, not `alias`, not `source_nat`.
2. Knowing the exact endpoint: `/api/firewall/filter/addRule`.
3. Knowing **every required field** of the schema (8 mandatory
   fields, including `direction` and `ipprotocol` which are not
   obvious).
4. Building the JSON manually.
5. Sending the curl with Basic auth and self-signed cert.

The LoRA does steps 1–4 from one sentence. That's what we embed
into the firewall — not a REST dispatcher.

### Why a LoRA and not a generic LLM?

A vanilla Phi-3 mini **wouldn't know** that OPNsense has a
`/api/firewall/filter/addRule` endpoint, or that a field is named
`source_net`. It would hallucinate plausible-looking but wrong
API calls. The LoRA was trained specifically on the 102 canonical
OPNsense functions (run v7: 102/102 validated) — that's the
**domain-specific knowledge** it brings.

It's also why a 3.8 B params model is enough: we don't need
general reasoning, just a reliable intent → tool_call mapping
within the OPNsense domain.

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
real `pf` rule. See [`docs/demo-results.en.md`](docs/demo-results.en.md) for
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

- [`docs/why-not-in-prod.en.md`](docs/why-not-in-prod.en.md) — the 4
  concrete reasons
- [`docs/build-llama-freebsd.en.md`](docs/build-llama-freebsd.en.md) —
  native FreeBSD compilation (stage B)
- [`docs/embedded-llm.en.md`](docs/embedded-llm.en.md) — rc.d service +
  local agent architecture
- [`docs/demo-results.en.md`](docs/demo-results.en.md) — real-world demo
  traces (read + write)
- [`docs/access-credentials.en.md`](docs/access-credentials.en.md) —
  inherited from kickstart: secrets / SSH / OPNsense API

> French versions are also available alongside (`docs/*.md`).

## Origin

Spawned from `kickstart-forge` (internal template) using the
`*-forge` naming convention (3-letter prefix = `oaf`). Everything
that is not specific to the in-box LLM comes from the kickstart;
LLM-specific code lives in `docs/embedded-llm.en.md` and the
`opnsense_llm_*` Tofu variables.
