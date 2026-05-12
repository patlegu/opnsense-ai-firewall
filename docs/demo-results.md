# Démo validation — `oaf-agent` en action

Traces réelles capturées le 2026-05-12 sur une VM OPNsense fraîchement
déployée par ce repo. Sert de preuve "ça marche" et de baseline pour
des évolutions futures (perf, couverture tools, etc.).

## Setup

| Item | Valeur |
| --- | --- |
| VM | Hetzner Cloud `cx33` (4 vCPU shared, 8 GB RAM, 80 GB SSD) |
| OS | OPNsense 26.1.6_2-amd64 (FreeBSD 14.3-RELEASE-p10) |
| llama-server | `b9000` (build du 2026-05-12, sha256 `eb2e9024…`) |
| Modèle | `patlegu/opnsense-agent-phi35-q4_k_m.gguf` (merged Phi-3 mini + LoRA OPNsense, 2.4 GB) |
| Service | rc.d `llama` daemon(8), bind strict `127.0.0.1:8080` |
| API OPNsense | `127.0.0.1:4443` (auth Basic, user `breachsim` group admins) |
| Agent | Python 3.13, `/var/llm/agent/oaf_agent.py` + wrapper `/usr/local/bin/oaf-agent` |
| Latence inférence | ~10-30 s/requête (selon longueur du tool_call) |

## Test 1 — health combiné

```text
$ ssh -p 2222 root@$IP /bin/sh -c 'oaf-agent health'
[oaf] LLM_URL=http://127.0.0.1:8080
[oaf] llama-server : 200 {"status":"ok"}
[oaf] OPNSENSE_URL=https://127.0.0.1:4443
[oaf] OPNsense API OK : keys=['name', 'versions', 'updates']
```

Valide que les **deux** sous-systèmes répondent en local.

## Test 2 — lecture : show system information

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

Latence : 13 s. Le LoRA a généré le `tool_call` dans son `content` via
les special tokens `<|tool_calls|>...<|tool_response|>` que l'agent
extrait (`extract_tool_calls_from_content`).

## Test 3 — lecture : list cron jobs

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

Latence totale (`time`) : **10 s**. CPU client (Python) négligeable —
tout le coût est sur le serveur llama-server qui processse les ~256
tokens du tool_call.

## Test 4 — écriture : block IP avec confirmation

C'est le test qui prouve que le LLM **modifie réellement** les règles
pf, pas juste lit.

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

Trois choses critiques se passent ici :

1. **`scope_confirmed=True`** : le flag `--confirm` est requis pour
   tout tool marqué `mutating=True` dans `TOOLS_WHITELIST`. Sans, l'agent
   affiche `would_call: {...}` et sort en exit code 4 (dry-run).
2. **ARG_ADAPTERS** : le LoRA a généré `{"ip": "203.0.113.42",
   "description": "Blocked by OPNsense"}` (payload "training-style",
   simple). L'agent applique l'adapter `block_ip` qui projette ça vers
   le schema REST OPNsense complet (`{rule: {enabled, action,
   interface, direction, ipprotocol, protocol, source_net,
   destination_net, description}}`).
3. **OPNsense répond `{"result":"saved","uuid":"…"}`** : la règle a été
   persistée dans `config.xml`. Vérifiable sur l'UI : Firewall → Rules
   → WAN.

## Test 5 — tools hors whitelist (échec attendu)

Certains intents font produire au LoRA des noms de tools qu'on n'a pas
encore dans `TOOLS_WHITELIST` :

```text
$ oaf-agent ask "List all firewall rules"
2026-05-12 23:41:57,892 oaf-agent INFO tool_call extrait du content via special tokens
2026-05-12 23:41:57,892 oaf-agent ERROR tool 'list_firewall_states' hors whitelist

$ oaf-agent ask "List WireGuard peers"
2026-05-12 23:42:27,847 oaf-agent INFO tool_call extrait du content via special tokens
2026-05-12 23:42:27,847 oaf-agent ERROR tool 'get_wireguard_peers' hors whitelist
```

C'est **attendu et désiré** : la whitelist est un garde-fou. Le LoRA a
été entraîné sur 102 fonctions ; notre agent en expose une douzaine.
Au fil des tests on ajoute aux dicts `TOOLS_WHITELIST` + `TOOL_DESCRIPTIONS`
+ `ARG_ADAPTERS`.

À noter : `list_firewall_states` ≠ `list_firewall_rules`. La 1ère
inspecte les **états** pf (connexions traversées) ; la 2nde les
**règles** elles-mêmes. Le LoRA peut confondre selon la formulation
de l'intent.

## Mesures concrètes (à compléter — palier E.3)

Tests à faire pour quantifier l'impact "AI in firewall" :

- [ ] Latence p50/p95 d'inférence sur 50 intents lecture
- [ ] Latence p50/p95 sur 20 intents mutating
- [ ] Throughput pf (bande passante WAN ↔ LAN) **pendant** une
  inférence vs au repos — pour mesurer la contention CPU
- [ ] RSS de `llama-server` sous charge (vs au repos)
- [ ] Temps de chargement du modèle au boot (`service llama start` →
  `/health` répond OK)

Une fois ces mesures faites, on saura **où placer le seuil** où ça
casse vraiment (= une intent toutes les X secondes maxi pour préserver
la latence pf < Y ms).

## Lessons learned (pièges traversés pendant cette validation)

1. **Hetzner Cloud + FreeBSD via mfsBSD** → galère. Utiliser une VM
   libvirt sur <LIBVIRT_HOST> avec image FreeBSD CI officielle (cf.
   `docs/build-llama-freebsd.md`).
2. **llama.cpp b3813 sans `--jinja`** → `Unsupported param: tools` sur
   `/v1/chat/completions`. Bump à b9000.
3. **`$$VAR` dans templatefile Tofu** → reste `$$VAR` dans la sortie,
   bash interprète `$$` = PID. Utiliser `$VAR` (un seul `$`).
4. **`provisioner "file" source=dir/`** → casse sur les chains de
   symlinks SONAME. Préférer un tarball + tar-xzf remote.
5. **Binaire en cours d'exécution** → ETXTBSY au SCP. `service stop`
   avant.
6. **Python urllib + Content-Type: application/json sur GET** → 400
   côté OPNsense. Header conditionnel selon présence du body.
7. **LoRA produit ses tool_calls dans le content via special tokens**
   Phi-3 (`<|tool_calls|>...<|tool_response|>`), pas dans
   `message.tool_calls`. Parser le content côté agent.
8. **Schemas API OPNsense ≠ payload training LoRA**. Adapter
   nécessaire (`ARG_ADAPTERS`).
9. **API key et secret en clair désynchronisables** entre `config.xml`
   OPNsense et `terraform.tfvars`. Patcher `/conf/config.xml` via
   Python + `configctl webgui restart` quand ça arrive.
