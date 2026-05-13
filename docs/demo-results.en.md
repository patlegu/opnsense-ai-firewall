# Validation demo — `oaf-agent` in action

Real traces captured on 2026-05-12 on an OPNsense VM freshly deployed
by this repo. Serves as "it works" proof and as a baseline for future
evolution (perf, tools coverage, etc.).

## Setup

| Item | Value |
| --- | --- |
| VM | Hetzner Cloud `cx33` (4 vCPU shared, 8 GB RAM, 80 GB SSD) |
| OS | OPNsense 26.1.6_2-amd64 (FreeBSD 14.3-RELEASE-p10) |
| llama-server | `b9000` (build of 2026-05-12, sha256 `eb2e9024...`) |
| Model | `patlegu/opnsense-agent-phi35-q4_k_m.gguf` (merged Phi-3 mini + OPNsense LoRA, 2.4 GB) |
| Service | rc.d `llama` daemon(8), strict bind `127.0.0.1:8080` |
| OPNsense API | `127.0.0.1:4443` (Basic auth, user `breachsim` group admins) |
| Agent | Python 3.13, `/var/llm/agent/oaf_agent.py` + wrapper `/usr/local/bin/oaf-agent` |
| Inference latency | ~10-30 s/request (depending on tool_call length) |

## Test 1 — combined health

```text
$ ssh -p 2222 root@$IP /bin/sh -c 'oaf-agent health'
[oaf] LLM_URL=http://127.0.0.1:8080
[oaf] llama-server : 200 {"status":"ok"}
[oaf] OPNSENSE_URL=https://127.0.0.1:4443
[oaf] OPNsense API OK : keys=['name', 'versions', 'updates']
```

Validates that **both** subsystems respond locally.

## Test 2 — read: show system information

```text
$ oaf-agent ask "Show system information"
2026-05-12 23:36:45,123 oaf-agent INFO CAP: CAPPacket(directive='Show system information', ...)
2026-05-12 23:36:58,113 oaf-agent INFO tool_call extrait du content via special tokens
2026-05-12 23:36:58,113 oaf-agent INFO → GET /api/diagnostics/system/system_information args={}
{
  "name": "opnsense.lab.local",
  "versions": [
    "OPNsense 26.1.6_2-amd64",
    "FreeBSD 14.3-RELEASE-p10",
    "OpenSSL 3.0.20"
  ],
  "updates": "Click to check for updates."
}
```

Latency: 13 s. The LoRA generated the `tool_call` in its `content` via
the special tokens `<|tool_calls|>...<|tool_response|>` that the agent
extracts (`extract_tool_calls_from_content`).

## Test 3 — read: list cron jobs

```text
$ oaf-agent ask "List all scheduled cron jobs"
2026-05-12 23:38:30,419 oaf-agent INFO CAP: CAPPacket(directive='List cron jobs', ...)
2026-05-12 23:38:40,271 oaf-agent INFO tool_call extrait du content via special tokens
2026-05-12 23:38:40,271 oaf-agent INFO → GET /api/cron/settings/searchJobs args={}
{
  "rows": [],
  "rowCount": 0,
  "total": 0,
  "current": 1
}
       10.00 real         0.10 user         0.00 sys
```

Total latency (`time`): **10 s**. Client CPU (Python) negligible —
all the cost is on the llama-server side processing the ~256 tokens
of the tool_call.

## Test 4 — write: block IP with confirmation

This is the test that proves the LLM **actually modifies** pf rules,
not just reads.

```text
$ oaf-agent ask "Block IP 203.0.113.42 on WAN" --confirm
2026-05-12 23:42:27,946 oaf-agent INFO CAP: CAPPacket(directive='Block IP 203.0.113.42 on WAN', scope_confirmed=True)
2026-05-12 23:42:37,610 oaf-agent INFO tool_call extrait du content via special tokens
2026-05-12 23:42:37,611 oaf-agent INFO args adaptés (block_ip) : {'rule': {'enabled': '1', 'action': 'block', 'interface': 'wan', 'direction': 'in', 'ipprotocol': 'inet', 'protocol': 'any', 'source_net': '203.0.113.42', 'destination_net': 'any', 'description': 'Blocked by OPNsense'}}
2026-05-12 23:42:37,611 oaf-agent INFO → POST /api/firewall/filter/addRule args={'rule': {...}}
{
  "result": "saved",
  "uuid": "a17955a6-99d7-4994-afd9-8fc6d4af2146"
}
```

Three critical things happen here:

1. **`scope_confirmed=True`**: the `--confirm` flag is required for
   any tool marked `mutating=True` in `TOOLS_WHITELIST`. Without it,
   the agent prints `would_call: {...}` and exits with code 4
   (dry-run).
2. **ARG_ADAPTERS**: the LoRA produced `{"ip": "203.0.113.42",
   "description": "Blocked by OPNsense"}` (simple, "training-style"
   payload). The agent applies the `block_ip` adapter that projects
   it to the full OPNsense REST schema (`{rule: {enabled, action,
   interface, direction, ipprotocol, protocol, source_net,
   destination_net, description}}`).
3. **OPNsense responds `{"result":"saved","uuid":"…"}`**: the rule
   was persisted in `config.xml`. Verifiable in the UI: Firewall ->
   Rules -> WAN.

## Test 5 — tools outside whitelist (expected failure)

Some intents make the LoRA produce tool names we don't have in
`TOOLS_WHITELIST` yet:

```text
$ oaf-agent ask "List all firewall rules"
2026-05-12 23:41:57,892 oaf-agent INFO tool_call extrait du content via special tokens
2026-05-12 23:41:57,892 oaf-agent ERROR tool 'list_firewall_states' hors whitelist

$ oaf-agent ask "List WireGuard peers"
2026-05-12 23:42:27,847 oaf-agent INFO tool_call extrait du content via special tokens
2026-05-12 23:42:27,847 oaf-agent ERROR tool 'get_wireguard_peers' hors whitelist
```

This is **expected and desired**: the whitelist is a guardrail. The
LoRA was trained on 102 functions; our agent exposes about a dozen.
As tests progress we add to the `TOOLS_WHITELIST` + `TOOL_DESCRIPTIONS`
+ `ARG_ADAPTERS` dicts.

Note: `list_firewall_states` != `list_firewall_rules`. The first
inspects the pf **states** (traversed connections); the second the
**rules** themselves. The LoRA can confuse them depending on the
intent phrasing.

## Concrete measurements (to complete — milestone E.3)

Tests to do to quantify the "AI in firewall" impact:

- [ ] p50/p95 inference latency on 50 read intents
- [ ] p50/p95 latency on 20 mutating intents
- [ ] pf throughput (WAN <-> LAN bandwidth) **during** an inference
  vs at rest — to measure CPU contention
- [ ] `llama-server` RSS under load (vs at rest)
- [ ] Model loading time at boot (`service llama start` -> `/health`
  answers OK)

Once these measurements are done, we'll know **where to set the
threshold** where it really breaks (= one intent every X seconds max
to keep pf latency < Y ms).

## Lessons learned (pitfalls crossed during this validation)

1. **Hetzner Cloud + FreeBSD via mfsBSD** -> pain. Use a libvirt VM
   on <LIBVIRT_HOST> with the official FreeBSD CI image (see
   `docs/build-llama-freebsd.en.md`).
2. **llama.cpp b3813 without `--jinja`** -> `Unsupported param:
   tools` on `/v1/chat/completions`. Bump to b9000.
3. **`$$VAR` in Tofu templatefile** -> stays as `$$VAR` in the
   output, bash interprets `$$` = PID. Use `$VAR` (single `$`).
4. **`provisioner "file" source=dir/`** -> breaks on SONAME symlink
   chains. Prefer a tarball + remote tar-xzf.
5. **Binary running** -> ETXTBSY on SCP. `service stop` before.
6. **Python urllib + Content-Type: application/json on GET** -> 400
   on the OPNsense side. Conditional header depending on body
   presence.
7. **LoRA produces its tool_calls in the content via Phi-3 special
   tokens** (`<|tool_calls|>...<|tool_response|>`), not in
   `message.tool_calls`. Parse the content on the agent side.
8. **OPNsense API schemas != LoRA training payload**. Adapter
   required (`ARG_ADAPTERS`).
9. **API key and secret in clear can desync** between OPNsense
   `config.xml` and `terraform.tfvars`. Patch `/conf/config.xml`
   via Python + `configctl webgui restart` when that happens.
