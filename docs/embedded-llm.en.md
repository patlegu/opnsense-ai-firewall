# LLM embedded in OPNsense — service architecture

> **Audience**: operator who has deployed the repo (`tofu apply`
> succeeded) and wants to understand what runs in the OPNsense VM,
> how it talks to the local API, and where the guardrails are.

## Overview

Inside the OPNsense VM (FreeBSD 14), three things:

```text
┌────────────────────── OPNsense (FreeBSD) ──────────────────────┐
│                                                                 │
│  ┌─────────────────────────────┐                                │
│  │  llama-server               │  bind 127.0.0.1:8080           │
│  │  /var/llm/bin/llama-server  │  ─────────────────────► HTTP   │
│  │  LD_LIBRARY_PATH=/var/llm/lib                                │
│  │  -m /var/llm/models/phi-3-mini-4k-q4.gguf                    │
│  │  --lora /var/llm/models/opnsense-agent-phi35.gguf            │
│  │  --ctx-size 4096                                             │
│  └──────────────┬──────────────┘                                │
│                 │                                               │
│                 │  /v1/chat/completions                         │
│                 │  (OpenAI tool-calling format)                 │
│                 │                                               │
│  ┌──────────────▼──────────────────────────────────────────┐    │
│  │  local agent  (/var/llm/agent/oaf_agent.py)             │    │
│  │  - builds a CAP v1 packet from the NL intent            │    │
│  │  - calls llama-server to get the tool_call              │    │
│  │  - filters via TOOLS_WHITELIST                          │    │
│  │  - checks scope_confirmed for mutating tools            │    │
│  │  - dispatches to the local OPNsense API                 │    │
│  └──────────────┬──────────────────────────────────────────┘    │
│                 │                                               │
│                 │  HTTPS 127.0.0.1:4443                         │
│                 │  Basic auth = key:secret                      │
│                 │                                               │
│  ┌──────────────▼──────────────────────────────────────────┐    │
│  │  OPNsense REST API (/api/cron/..., /api/firewall/..., …)│    │
│  │  → side effects on pf / NAT / VPN / Suricata / etc.     │    │
│  └─────────────────────────────────────────────────────────┘    │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

## Components

### 1. `llama-server` (rc.d service `llama`)

Managed by `/usr/local/etc/rc.d/llama` (generated at `tofu apply`
from the template `templates/rc-llama.tftpl`).

```sh
service llama status
service llama start
service llama stop
service llama restart
tail -f /var/log/llama/server.log
```

PID in `/var/run/llama.pid`. Daemonized via `daemon(8)` from the
FreeBSD base system — no supervisord, no systemd.

### 2. GGUF models

| File | Origin | Size |
| --- | --- | --- |
| `/var/llm/models/phi-3-mini-4k-q4.gguf` | `microsoft/Phi-3-mini-4k-instruct-gguf` Q4_K_M | ~2.4 GB |
| `/var/llm/models/opnsense-agent-phi35.gguf` | `patlegu/opnsense-agent-phi35` | ~480 MB |

Downloaded by the `post-install-llm.sh` script (generated at tofu
apply) via base system `fetch(1)`. The initial download takes 1-2
min on the Hetzner Helsinki network.

### 3. Local Python agent (`oaf_agent.py`)

Lives at `/var/llm/agent/oaf_agent.py` (deployed by milestone C). No
external deps — stdlib + Python 3.11 (already on OPNsense via `pkg`).

Usage:

```sh
# smoke test: llama-server + OPNsense API reachable
python3 /var/llm/agent/oaf_agent.py health

# read-only intent (no --confirm required)
python3 /var/llm/agent/oaf_agent.py ask "List all scheduled cron jobs"

# mutating intent (fails without --confirm, prints dry-run)
python3 /var/llm/agent/oaf_agent.py ask "Block IP 203.0.113.42 on WAN"

# Same, actually applied
python3 /var/llm/agent/oaf_agent.py ask "Block IP 203.0.113.42 on WAN" --confirm
```

Environment variables (defaults OK on a vanilla OPNsense):

| Var | Default | Role |
| --- | --- | --- |
| `OAF_LLM_URL` | `http://127.0.0.1:8080` | llama-server endpoint |
| `OAF_OPNSENSE_URL` | `https://127.0.0.1:4443` | OPNsense API endpoint |
| `OAF_OPNSENSE_KEY` | (to set) | OPNsense API key in clear |
| `OAF_OPNSENSE_SECRET` | (to set) | OPNsense API secret in clear |
| `OAF_TIMEOUT` | `120` | HTTP timeout (s) |

The `OAF_OPNSENSE_*` are to be set by the operator (never committed).
They correspond to the `opnsense_api_key` / `opnsense_api_secret_plain`
from `terraform.tfvars` (the operator already has them on their
deployment machine).

## Guardrails

### Catalog + blacklist (instead of a rigid whitelist)

Three filtering layers on the `oaf_agent.py` side:

1. **`TOOLS_CATALOG`** (generated): names the LoRA was trained on,
   with their `(method, endpoint, mutating)` extracted from the
   `cyber-agent-engine` repo. Produced by
   `scripts/generate-tools-catalog.py`. ~72 entries currently.
2. **`TOOLS_LOCAL_OVERRIDES`** (manual, in `oaf_agent.py`): aliases
   and endpoints not covered by the auto catalog — observed in LoRA
   output during tests (e.g.: `diagnostics_cron`,
   `wireguard_client_get_client_builder`, etc.).
3. **`TOOLS_BLACKLIST`** (operator runtime): opt-in via env
   `OAF_BLACKLIST="a,b,c"` or file `/etc/oaf-agent.blacklist` (1
   name per line). Allows a read-only / non-disruptive demo mode
   without touching the code. Tofu can populate this file via the
   `opnsense_llm_tools_blacklist` variable.

Three distinct exit codes on dispatch:

| Code | Meaning |
| --- | --- |
| `0` | Tool dispatched successfully |
| `3` | **Unknown** tool = LoRA hallucination (outside catalog + overrides) |
| `5` | Tool blacklisted by the operator |
| `6` | Tool **known** by the LoRA but with no mapped endpoint (to be added to `TOOLS_LOCAL_OVERRIDES`) |

Error `6` is useful in debug: it tells you "the LoRA is coherent but
the agent needs a new override entry".

To regenerate the catalog after evolution of the training set:

```bash
bash scripts/generate-tools-catalog.py
# emits agent/tools_catalog.py — commit the result
```

### scope_confirmed

Any tool marked `mutating=True` in `TOOLS_WHITELIST` requires
`--confirm` (which sets `scope_confirmed=true` in the CAP). Without
it, the agent prints a dry-run JSON and exits 4. This avoids "the
LoRA made me create 50 ghost rules".

It is an **operator guardrail**, not an anti-malicious control —
someone with SSH access to the VM can bypass. See CLAUDE.md on the
non-goal "security audit".

### Bind 127.0.0.1

`llama-server` listens **strictly** on `127.0.0.1:8080`. Port 8080 is
never opened on the OPNsense public IP, nor on the LAN. Verify after
deployment:

```sh
sockstat -4l | grep 8080
# expected: llama-server  *  127.0.0.1:8080  *.*
```

If you see `*:8080`, that's a bug — fix `opnsense_llm_listen_addr` in
the variables and redeploy.

## Known limitations

- **Inference latency on cx33 (8 GB shared)**: ~2-4 s for the initial
  prompt processing, then ~7-10 tokens/s in generation. An admin
  intent = **~10 s total** measured in the demo (see
  [`demo-results.en.md`](demo-results.en.md)). Not suitable for
  real-time pf decisions — it's admin assistance.
- **CPU contention**: during inference, the 4 vCPU are saturated.
  pf routing takes measurable latency (see milestone E for benches).
- **One intent at a time**: `llama-server` is in `--parallel 1` by
  default. Multiple admins asking questions = waiting queue. If you
  want multi-concurrent, increase `--parallel 2` at the cost of more
  RAM.
- **No conversational memory**: each `oaf-agent ask` is independent.
  No "now delete the rule you just created" — this is deliberate
  (KISS + stateless agent).
