# Why this setup MUST NOT go to production

This repo deliberately embeds a LLM inside the OPNsense VM, out of
curiosity. Here are **the four concrete reasons** why it's a bad
idea in prod, and why the "real" topology (LLM sidecar) remains
preferable.

## 1. Attack surface

A firewall must be minimalist. This repo adds on OPNsense:

- an ELF binary of **8.9 MB** (`/var/llm/bin/llama-server`)
- **6 shared libraries** (~36 MB cumulative) including OpenBLAS (28 MB)
- **Python 3.13** (~80 MB via pkg) + its stdlib ecosystem
- a daemonized rc.d `llama` service
- a REST API endpoint on `127.0.0.1:8080`

That's ~125 MB of code and one more subsystem to audit / patch /
monitor. Every CVE in llama.cpp, ggml, OpenBLAS, or Python becomes
your CVE. For comparison, minimal OPNsense = ~600 MB total.

Mitigation attempted in this repo: strict `127.0.0.1` bind (never
listened on WAN or LAN), service running as root without a privileged
wrapper, no public API. **But** an attacker who gets a local shell
on OPNsense has the whole toolkit at hand.

## 2. CPU contention during inference

An admin intent = **~10 s of inference** measured on `cx33` (4 vCPU
shared). During those 10 s:

- `llama-server` saturates the 4 vCPU at 100 % (BLAS + matmul)
- `pf` (the firewall) keeps filtering traffic, but under
  **contention** on those same cores

On a firewall that serves little traffic (lab, branch office with
no peaks), it's fine. On an edge router forwarding 500 Mbps:

- p99 forwarding latency goes off the rails during inference
- throughput can drop 20-40 % for the duration of the request
- TCP retransmissions pile up

Possible mitigation: `cpuset` to pin llama-server to a single core.
But then 7-10 tok/s become 2-3 tok/s → 30 s/intent. You degrade
either pf latency or the LLM. No CPU-only escape hatch.

See the perf measurements upcoming in tier E.3 of
[`demo-results.en.md`](demo-results.en.md) — section "Concrete measurements".

## 3. Incompatible lifecycle

OPNsense follows FreeBSD with a stable release cycle (1-2 per year).
llama.cpp **moves every day**:

- breaking ABI/GGUF format changes every ~2 months
- new quantization formats (Q4_K_M becomes obsolete, Q4_K_M_v2,
  etc.)
- support for new chat templates (cf. our move b3813 →
  b9000 for native `tools`)

If you deploy in prod today and don't touch it for 6 months, your
FreeBSD binary is frozen on b9000 while the LoRA you want to load
tomorrow won't be compatible anymore. This repo has a script
that rebuilds (`scripts/build-llama-freebsd.sh`) but it's still
**you** who owns the cadence.

On a sidecar VM/container, the LLM updates independently.
OPNsense stays OPNsense.

## 4. Audit & accountability

Firewalls get audited. When a rule changes, you need to know
**who** wrote it and **why**. With a LLM that modifies
`config.xml`:

- `<modified><time></modified>` says "modified by root"
- no trace of the original intent that triggered the change
- no four-eyes review (the LLM is not a signature)
- in case of an incident: "the LLM hallucinated a block on 8.8.8.8"
  is not an acceptable justification in compliance

Mitigation: we have the `--confirm` guardrail on the agent side +
audit log on the `oaf_agent.py` side. But that's still **operator**,
not an anti-malicious control or a legal audit trail.

The sidecar architecture allows you to:

- log the original intent + the human user who typed it
- generate the proposed rule + have it validated by a human via PR
- keep an immutable audit log outside the firewall

## In summary

This repo has **three valid uses**:

1. **Educational demo** — show that it's technically possible.
2. **Threshold measurement** — quantify "from when it breaks"
   to inform a future product (cf. tier E.3 perf measurements).
3. **Lab/research** — test new LoRAs, prompt formats, or
   in-box agent patterns.

And **no production use**. If you want this concept for real, look
at sidecar patterns: LLM on a dedicated VM separate from OPNsense,
vanilla OPNsense, audited API gateway between the two. A few internal
(private) implementations exist in the `*-forge` ecosystem; the public
pattern reproduces in ~50 lines of Tofu + a llama-server container
on a separate Debian VM.
