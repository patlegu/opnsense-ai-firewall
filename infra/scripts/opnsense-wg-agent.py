#!/usr/bin/env python3
"""
opnsense-wg-agent.py — Configure le module WireGuard d'OPNsense via l'agent LoRA.

Même interface que opnsense-wg-setup.py, mais les opérations setup-server et
add-peer transitent par le LoRA WireGuard (llama-server) qui génère le tool_call,
lequel est ensuite exécuté contre l'API OPNsense.

Flux :
    CLI args → CAP packet → agent WireGuard (LoRA) → tool_call → OPNsense API

Les sous-commandes list et apply appellent OPNsense directement (pas d'inférence).

Usage :
    python3 infra/scripts/opnsense-wg-agent.py list
    python3 infra/scripts/opnsense-wg-agent.py setup-server --privkey KEY --pubkey KEY
    python3 infra/scripts/opnsense-wg-agent.py add-peer --name asp-llm-soc --pubkey KEY --ip 10.10.0.11/32
    python3 infra/scripts/opnsense-wg-agent.py apply
"""

import argparse
import asyncio
import json
import os
import sys
from pathlib import Path

env_file = Path(__file__).parent.parent.parent / ".env"
if env_file.exists():
    for line in env_file.read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, _, v = line.partition("=")
            os.environ.setdefault(k.strip(), v.strip())

import httpx  # noqa: E402

# ── Config ────────────────────────────────────────────────────────────────────

OPNSENSE_IP     = os.getenv("BREACH_OPNSENSE_IP", "192.168.21.1")
OPNSENSE_PORT   = os.getenv("BREACH_OPNSENSE_PORT", "4443")
OPNSENSE_KEY    = os.getenv("BREACH_OPNSENSE_API_KEY", "")
OPNSENSE_SECRET = os.getenv("BREACH_OPNSENSE_API_SECRET", "")
LLAMA_URL       = os.getenv("BREACH_VM_URL", "http://192.168.51.10:8080")
LLAMA_API_KEY   = os.getenv("BREACH_VM_API_KEY", "")
# BREACH_BYPASS_LLM=1 : court-circuite le LoRA WireGuard pour setup-server
# et add-peer (les seules commandes qui passaient par _infer). Utilisé par le
# module Tofu wireguard-mesh pour éviter le chicken-and-egg LLM ↔ mesh au 1er
# apply (le LLM n'est pas encore reachable). Le LoRA reste utilisable pour
# les scénarios agentic complexes (incidents, troubleshooting interactif).
BYPASS_LLM      = os.getenv("BREACH_BYPASS_LLM", "0") == "1"

BASE_URL          = f"https://{OPNSENSE_IP}:{OPNSENSE_PORT}/api"
_WG_INSTANCE_NAME = "asp-mesh"


def _wg_lora_index() -> int:
    """Retourne l'index LoRA WireGuard depuis BREACH_VM_LORAS."""
    for part in os.getenv("BREACH_VM_LORAS", "").split(","):
        if "wireguard" in part and ":" in part:
            try:
                return int(part.split(":")[1].strip())
            except ValueError:
                pass
    return 1  # valeur par défaut connue


def _opnsense_client() -> httpx.AsyncClient:
    return httpx.AsyncClient(
        base_url=BASE_URL,
        auth=(OPNSENSE_KEY, OPNSENSE_SECRET),
        verify=False,
        timeout=15.0,
    )


# ── Inférence agent ───────────────────────────────────────────────────────────

SYSTEM_PROMPT = """Tu es un agent WireGuard. Tu reçois des directives structurées \
du coordinateur sous forme de paquets JSON (format CAP v1) et tu génères des appels d'API \
précis sous forme de tool_calls. Tu ne réponds jamais en langage naturel — uniquement des tool_calls.

Tu peux gérer deux types d'opérations WireGuard sur OPNsense :
1. add_wireguard_peer   — ajouter un peer (mesh ou restriction sécurité)
2. setup_wireguard_server — créer ou mettre à jour l'instance serveur WireGuard

Format attendu :
{"function": {"name": "add_wireguard_peer", "arguments": {"name": "...", "pubkey": "...", "tunneladdress": "10.10.0.x/32", "keepalive": 25}}}
{"function": {"name": "setup_wireguard_server", "arguments": {"name": "asp-mesh", "privkey": "...", "pubkey": "...", "tunneladdress": "10.10.0.1/24", "port": 51820}}}"""


async def _infer(cap: dict) -> dict | None:
    """Envoie un CAP au LoRA WireGuard, retourne le tool_call extrait ou None."""
    lora_index = _wg_lora_index()
    payload = {
        "messages": [
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user",   "content": json.dumps(cap, ensure_ascii=False)},
        ],
        "stream":      True,
        "max_tokens":  256,
        "temperature": 0.1,
        "top_p":       0.95,
        "lora_adapters": [{"id": lora_index, "scale": 1.0}],
    }

    full = ""
    print(f"  → agent WireGuard (LoRA index={lora_index}) ...", end=" ", flush=True)
    headers = {"Accept": "text/event-stream"}
    if LLAMA_API_KEY:
        headers["Authorization"] = f"Bearer {LLAMA_API_KEY}"
    async with httpx.AsyncClient(
        timeout=httpx.Timeout(connect=10, read=120, write=10, pool=10),
    ) as client:
        async with client.stream(
            "POST", f"{LLAMA_URL}/v1/chat/completions", json=payload,
            headers=headers,
        ) as resp:
            resp.raise_for_status()
            async for line in resp.aiter_lines():
                if not line.startswith("data:"):
                    continue
                raw = line[5:].strip()
                if raw == "[DONE]":
                    break
                try:
                    chunk = json.loads(raw)
                    token = chunk["choices"][0]["delta"].get("content", "")
                    if token:
                        full += token
                        if "<|im_end|>" in token or "<|endoftext|>" in token:
                            break
                except (json.JSONDecodeError, KeyError):
                    pass

    tool_call = _extract_tool_call(full)
    if tool_call:
        fn = tool_call.get("function", {}).get("name", "?")
        print(f"tool_call={fn}")
    else:
        print("aucun tool_call")
    return tool_call


def _extract_tool_call(text: str) -> dict | None:
    """Extrait un tool_call JSON de la réponse du modèle (objet, tableau, ou multiligne)."""
    stripped = text.strip()

    if stripped.startswith("["):
        try:
            arr = json.loads(stripped)
            if isinstance(arr, list) and arr:
                first = arr[0]
                if isinstance(first, dict) and "function" in first:
                    return first
        except json.JSONDecodeError:
            pass

    for line in reversed(stripped.splitlines()):
        line = line.strip()
        if line.startswith("{") and "function" in line:
            try:
                return json.loads(line)
            except json.JSONDecodeError:
                pass

    for start_char in ("{", "["):
        try:
            start = stripped.index(start_char)
            parsed = json.loads(stripped[start:])
            if isinstance(parsed, list) and parsed:
                parsed = parsed[0]
            if isinstance(parsed, dict) and "function" in parsed:
                return parsed
        except (ValueError, json.JSONDecodeError):
            pass

    return None


def _get_args(tool_call: dict) -> dict:
    fn_args = tool_call.get("function", {}).get("arguments", {})
    if isinstance(fn_args, str):
        return json.loads(fn_args)
    return fn_args


# ── Exécution OPNsense ────────────────────────────────────────────────────────

async def _execute_setup_server(args: dict) -> None:
    """Exécute setup_wireguard_server tool_call contre OPNsense."""
    name    = args.get("name", _WG_INSTANCE_NAME)
    privkey = args.get("privkey", "")
    pubkey  = args.get("pubkey", "")
    cidr    = args.get("tunneladdress", args.get("tunnel_cidr", "10.10.0.1/24"))
    port    = str(args.get("listen_port", args.get("port", 51820)))

    body = {"server": {
        "enabled":       "1",
        "name":          name,
        "privkey":       privkey,
        "pubkey":        pubkey,
        "port":          port,
        "tunneladdress": cidr,
        "dns":           "",
        "disableroutes": "0",
    }}

    async with _opnsense_client() as c:
        # Chercher UUID existant
        r = await c.get("/wireguard/server/searchServer")
        r.raise_for_status()
        uuid = next(
            (row["uuid"] for row in r.json().get("rows", []) if row.get("name") == name),
            None,
        )
        if uuid:
            r = await c.post(f"/wireguard/server/setServer/{uuid}", json=body)
            print(f"  Serveur '{name}' mis à jour (uuid={uuid[:8]})")
        else:
            r = await c.post("/wireguard/server/addServer", json=body)
            print(f"  Serveur '{name}' créé")
        r.raise_for_status()
        print(f"  → {r.json()}")


async def _execute_add_peer(args: dict) -> None:
    """Exécute add_wireguard_peer tool_call contre OPNsense."""
    name   = args.get("name", "")
    pubkey = args.get("pubkey", "")
    ip     = args.get("tunneladdress", args.get("tunnel_ip", ""))
    if ip and "/" not in ip:
        ip = f"{ip}/32"
    keepalive = str(args.get("keepalive", 25))

    body = {"client": {
        "enabled":       "1",
        "name":          name,
        "pubkey":        pubkey,
        "psk":           "",
        "tunneladdress": ip,
        "keepalive":     keepalive,
    }}

    async with _opnsense_client() as c:
        r = await c.get("/wireguard/client/searchClient")
        r.raise_for_status()
        existing_uuid = next(
            (row["uuid"] for row in r.json().get("rows", []) if row.get("name") == name),
            None,
        )
        if existing_uuid:
            r = await c.post(f"/wireguard/client/setClient/{existing_uuid}", json=body)
            print(f"  Peer '{name}' mis à jour (uuid={existing_uuid[:8]})")
        else:
            r = await c.post("/wireguard/client/addClient", json=body)
            print(f"  Peer '{name}' ajouté")
        r.raise_for_status()
        print(f"  → {r.json()}")


# ── Opérations directes (sans agent) ─────────────────────────────────────────

async def enable_wireguard() -> None:
    """Active globalement le module WireGuard côté OPNsense + reconfigure.

    Idempotent — relancé sans risque si déjà enabled.
    """
    async with _opnsense_client() as c:
        r = await c.get("/wireguard/general/get")
        r.raise_for_status()
        already = (r.json().get("general") or {}).get("enabled") == "1"
        if already:
            print("  WireGuard déjà enabled global ✓")
        else:
            r = await c.post("/wireguard/general/set",
                             json={"general": {"enabled": "1"}})
            r.raise_for_status()
            print(f"  enable: {r.json().get('result', r.text[:60])}")
        # Reconfigure pour démarrer le service si pas déjà
        r = await c.post("/wireguard/service/reconfigure")
        r.raise_for_status()
        print(f"  reconfigure: {r.json().get('result', r.text[:60])}")


async def add_firewall_pass_wan(port: int = 51820,
                                 description_tag: str = "ASP-WG") -> None:
    """Ajoute une pass rule firewall WAN UDP:port (idempotent par description).

    description_tag : utilisé comme marqueur pour détecter une rule existante
    et éviter les doublons aux runs successifs.
    """
    full_desc = f"{description_tag} {port}/udp"
    async with _opnsense_client() as c:
        r = await c.get("/firewall/filter/get")
        r.raise_for_status()
        rules = r.json().get("filter", {}).get("rules", {}).get("rule", {})
        # OPNsense 26.x peut renvoyer [] au lieu de {} si aucune rule
        if isinstance(rules, dict):
            for uuid, rule in rules.items():
                if isinstance(rule, dict) and full_desc in rule.get("description", ""):
                    print(f"  pass rule WAN udp:{port} déjà présente ({uuid[:8]})")
                    return
        body = {"rule": {
            "enabled":          "1",
            "action":           "pass",
            "interface":        "wan",
            "ipprotocol":       "inet",
            "protocol":         "UDP",
            "source_net":       "any",
            "destination_net":  "(self)",
            "destination_port": str(port),
            "description":      full_desc,
        }}
        r = await c.post("/firewall/filter/addRule", json=body)
        r.raise_for_status()
        uuid = r.json().get("uuid", "?")
        print(f"  pass rule WAN udp:{port} ajoutée (uuid={str(uuid)[:8]})")
        r2 = await c.post("/firewall/filter/apply")
        print(f"  filter apply: {r2.json().get('status', r2.text[:60])}")


async def add_outbound_nat(src_net: str, dst_net: str,
                            interface: str = "wg0",
                            description_tag: str = "ASP-NAT-WG") -> None:
    """Ajoute une règle SNAT outbound pour router src_net → dst_net via interface.

    Permet à korrig (192.168.21.0/24) d'atteindre les peers WG (10.10.0.0/24)
    en source-NATant via wg0 — sinon les peers reçoivent un paquet avec
    src=192.168.21.x qui n'est pas dans leur AllowedIPs et la réponse est
    perdue (routing asymétrique).
    """
    full_desc = f"{description_tag} {src_net}->{dst_net}"
    async with _opnsense_client() as c:
        r = await c.get("/firewall/source_nat/get")
        r.raise_for_status()
        # Structure peut varier selon version : tester rules.rule ou directement rule
        data = r.json()
        rules_root = data.get("source_nat") or data.get("filter", {}).get("snatrules") or {}
        rules = rules_root.get("rule") or rules_root.get("rules", {}).get("rule", {})
        if isinstance(rules, dict):
            for uuid, rule in rules.items():
                if isinstance(rule, dict) and full_desc in rule.get("description", ""):
                    print(f"  outbound NAT {src_net}→{dst_net} déjà présent ({uuid[:8]})")
                    return
        body = {"rule": {
            "enabled":         "1",
            "interface":       interface,
            "ipprotocol":      "inet",
            "protocol":        "any",
            "source_net":      src_net,
            "destination_net": dst_net,
            "target":          "(self)",   # masquerade via l'IP de l'interface
            "description":     full_desc,
        }}
        r = await c.post("/firewall/source_nat/addRule", json=body)
        if r.status_code != 200:
            print(f"  ⚠ outbound NAT addRule HTTP {r.status_code}: {r.text[:200]}")
            return
        uuid = r.json().get("uuid", "?")
        print(f"  outbound NAT {src_net}→{dst_net} via {interface} ajouté ({str(uuid)[:8]})")
        r2 = await c.post("/firewall/source_nat/apply")
        print(f"  source_nat apply: {r2.json().get('status', r2.text[:60])}")


async def bootstrap(wg_port: int = 51820,
                     nat_src: str = "192.168.21.0/24",
                     nat_dst: str = "10.10.0.0/24",
                     wg_iface: str = "wg0") -> None:
    """Bootstrap complet OPNsense pour la mesh WireGuard :
       1. Enable global + reconfigure
       2. Pass rule WAN UDP:port
       3. Outbound NAT src_net → dst_net via wg_iface

    Idempotent : safe à ré-exécuter à chaque tofu apply.
    """
    print("── 1. Enable WireGuard global ─────────────────────")
    await enable_wireguard()
    print("\n── 2. Pass rule WAN UDP:%d ─────────────────────────" % wg_port)
    await add_firewall_pass_wan(wg_port)
    print("\n── 3. Outbound NAT %s → %s via %s ────────" % (nat_src, nat_dst, wg_iface))
    await add_outbound_nat(nat_src, nat_dst, wg_iface)
    print("\n✓ Bootstrap WireGuard terminé")


async def apply_config() -> None:
    async with _opnsense_client() as c:
        r = await c.post("/wireguard/service/reconfigure")
        r.raise_for_status()
        print(f"  WireGuard reconfigure : {r.json().get('status', r.text[:60])}")


async def list_config() -> None:
    async with _opnsense_client() as c:
        r = await c.get("/wireguard/server/searchServer")
        r.raise_for_status()
        servers = r.json().get("rows", [])
        print(f"── Serveurs WireGuard ({len(servers)}) ──────────────────────────────")
        for s in servers:
            status = "✓" if s.get("enabled") == "1" else "✗"
            print(f"  {status} [{s.get('uuid','')[:8]}] {s.get('name')} "
                  f"— {s.get('tunneladdress')} :{s.get('port')}")

        r = await c.get("/wireguard/client/searchClient")
        r.raise_for_status()
        peers = r.json().get("rows", [])
        print(f"── Peers ({len(peers)}) ─────────────────────────────────────────────")
        for p in peers:
            status = "✓" if p.get("enabled") == "1" else "✗"
            print(f"  {status} [{p.get('uuid','')[:8]}] {p.get('name'):<20} {p.get('tunneladdress')}")


async def status_runtime() -> None:
    """État runtime — handshakes récents et octets échangés par peer.

    Équivaut à `wg show` côté OPNsense. Indique quels peers sont
    réellement connectés (handshake < 3 min = sain, > 3 min = KO).
    """
    import time
    async with _opnsense_client() as c:
        # Config statique d'abord
        await list_config()

        # Runtime — handshakes live
        r = await c.get("/wireguard/service/showhandshake")
        if r.status_code != 200:
            print(f"\n⚠ showhandshake API indisponible (code {r.status_code})")
            return
        data = r.json()
        rows = data.get("rows") or data.get("response") or []
        if not rows:
            print("\n── Handshakes ─────────────────────────────────────────────")
            print("  (aucun peer connecté — WG service peut être arrêté)")
            return

        print(f"\n── Handshakes runtime ({len(rows)}) ────────────────────────")
        now = time.time()
        for row in rows:
            # Format typique : {"name": "...", "latest-handshake": "unix_ts", ...}
            last = row.get("latest-handshake") or row.get("handshake")
            name = row.get("name") or row.get("peer", "?")
            if last and str(last).isdigit():
                age = now - int(last)
                status = "✓" if age < 180 else ("~" if age < 900 else "✗")
                mins = int(age // 60)
                print(f"  {status} {name:<25} last handshake {mins} min")
            else:
                print(f"  ? {name:<25} pas de handshake connu")


async def verify_peers() -> None:
    """Ping chaque peer via son IP tunnel pour vérifier la connectivité."""
    import subprocess
    async with _opnsense_client() as c:
        r = await c.get("/wireguard/client/searchClient")
        r.raise_for_status()
        peers = r.json().get("rows", [])

    print(f"── Verify routing ({len(peers)} peers) ─────────────────────")
    for p in peers:
        name  = p.get("name", "?")
        tunip = (p.get("tunneladdress") or "").split("/")[0]
        if not tunip:
            print(f"  ? {name:<25} pas d'IP tunnel configurée")
            continue
        try:
            result = subprocess.run(
                ["ping", "-c", "1", "-W", "2", tunip],
                capture_output=True, timeout=5,
            )
            ok = result.returncode == 0
            print(f"  {'✓' if ok else '✗'} {name:<25} {tunip:<15} "
                  f"{'joignable' if ok else 'TIMEOUT'}")
        except Exception as e:
            print(f"  ? {name:<25} {tunip:<15} erreur : {e}")


async def remove_peer(name: str) -> None:
    """Retire un peer WG via API OPNsense (match par name)."""
    async with _opnsense_client() as c:
        r = await c.get("/wireguard/client/searchClient")
        r.raise_for_status()
        matches = [
            p for p in r.json().get("rows", [])
            if p.get("name") == name
        ]
        if not matches:
            print(f"✗ Peer '{name}' introuvable")
            return
        for m in matches:
            uuid = m.get("uuid")
            d = await c.post(f"/wireguard/client/delClient/{uuid}")
            if d.status_code == 200 and d.json().get("result") == "deleted":
                print(f"  ✓ Peer {name} [{uuid[:8]}] retiré")
            else:
                print(f"  ✗ Échec retrait {name} [{uuid[:8]}] — {d.text[:80]}")


async def attach_all_peers_to_server() -> None:
    """Attache tous les clients WG existants à l'instance serveur asp-mesh.

    Sans cet attachement, OPNsense crée le peer (visible dans VPN > WireGuard
    > Peers) mais ne l'inclut pas dans la liste des peers acceptés par le
    serveur — handshake impossible. Idempotent : peut être ré-exécuté sans
    risque, attache les nouveaux peers et préserve les anciens.
    """
    async with _opnsense_client() as c:
        # 1. Lister tous les clients (peers)
        r = await c.get("/wireguard/client/searchClient")
        r.raise_for_status()
        client_uuids = [row["uuid"] for row in r.json().get("rows", []) if row.get("uuid")]
        if not client_uuids:
            print("  Aucun client à attacher")
            return

        # 2. Trouver le serveur asp-mesh
        r = await c.get("/wireguard/server/searchServer")
        r.raise_for_status()
        srv_row = next(
            (row for row in r.json().get("rows", []) if row.get("name") == _WG_INSTANCE_NAME),
            None,
        )
        if not srv_row:
            print(f"✗ Serveur '{_WG_INSTANCE_NAME}' introuvable — setup-server d'abord")
            sys.exit(1)
        srv_uuid = srv_row["uuid"]

        # 3. GET l'état complet du serveur (le format des peers est un dict
        # {uuid: {value, selected}} dans la réponse de getServer)
        r = await c.get(f"/wireguard/server/getServer/{srv_uuid}")
        r.raise_for_status()
        srv = r.json().get("server", {})

        peers_field = srv.get("peers", "")
        if isinstance(peers_field, dict):
            existing = {uuid for uuid, meta in peers_field.items()
                        if isinstance(meta, dict) and meta.get("selected")}
        else:
            existing = set(filter(None, str(peers_field).split(",")))

        new_set = set(client_uuids)
        if existing == new_set:
            print(f"  Tous les peers ({len(client_uuids)}) déjà attachés ✓")
            return

        # 4. Reconstruire un body simple pour setServer. OPNsense accepte
        # une CSV string pour le champ peers. Les autres champs nécessaires
        # sont récupérés depuis le getServer.
        def _scalar(d, key, default=""):
            v = d.get(key, default)
            if isinstance(v, dict):
                # OPNsense renvoie parfois {value: {selected: 1}} pour les enums
                sel = next((k for k, m in v.items()
                            if isinstance(m, dict) and m.get("selected")), default)
                return sel
            return v if v is not None else default

        body = {"server": {
            "enabled":       _scalar(srv, "enabled", "1"),
            "name":          _scalar(srv, "name", _WG_INSTANCE_NAME),
            "privkey":       _scalar(srv, "privkey"),
            "pubkey":        _scalar(srv, "pubkey"),
            "port":          str(_scalar(srv, "port", "51820")),
            "tunneladdress": _scalar(srv, "tunneladdress", "10.10.0.1/24"),
            "dns":           _scalar(srv, "dns", ""),
            "disableroutes": _scalar(srv, "disableroutes", "0"),
            "peers":         ",".join(sorted(new_set)),
        }}

        r = await c.post(f"/wireguard/server/setServer/{srv_uuid}", json=body)
        r.raise_for_status()
        added = new_set - existing
        removed = existing - new_set
        msg = f"  {len(new_set)} peer(s) attachés au serveur {_WG_INSTANCE_NAME}"
        if added:
            msg += f" (+{len(added)})"
        if removed:
            msg += f" (-{len(removed)})"
        print(msg)


def gen_wg_keypair() -> None:
    """Génère une paire de clés WireGuard locale (nécessite wg installé)."""
    import subprocess
    try:
        privkey = subprocess.check_output(
            ["wg", "genkey"], text=True,
        ).strip()
        pubkey = subprocess.check_output(
            ["wg", "pubkey"], input=privkey + "\n", text=True,
        ).strip()
    except FileNotFoundError:
        print("✗ commande 'wg' introuvable — apt install wireguard-tools", file=sys.stderr)
        sys.exit(1)
    print(f"privkey: {privkey}")
    print(f"pubkey:  {pubkey}")


async def service_control(action: str) -> None:
    """Contrôle du service WireGuard côté OPNsense via API.

    action ∈ {start, stop, restart, reconfigure, status}
    """
    endpoint = f"/wireguard/service/{action}"
    async with _opnsense_client() as c:
        if action == "status":
            r = await c.get(endpoint)
        else:
            r = await c.post(endpoint)
    print(f"{action}: HTTP {r.status_code} — {r.text[:200]}")


async def diagnose() -> None:
    """Diagnostic complet de la mesh WireGuard : service, config, peers, handshakes."""
    print("╔══════════════════════════════════════════════════════╗")
    print("║ Diagnostic WireGuard OPNsense                          ║")
    print("╚══════════════════════════════════════════════════════╝\n")

    async with _opnsense_client() as c:
        # 1. Service runtime
        print("── 1. Service runtime ─────────────────────────────────")
        r = await c.get("/wireguard/service/status")
        status = r.json().get("status", "?")
        print(f"   Status : {status}")
        if status != "running":
            print(f"   ⚠ Le service n'est pas en cours d'exécution")
            print(f"   → Tenter : wg-agent service start")

        # 2. Config générale
        print("\n── 2. Config générale ─────────────────────────────────")
        r = await c.get("/wireguard/general/get")
        gen = r.json().get("general", {})
        enabled = gen.get("enabled", "?")
        print(f"   Enabled global : {enabled}")
        if enabled != "1":
            print(f"   ⚠ WireGuard désactivé globalement")
            print(f"   → UI : VPN → WireGuard → Settings → cocher Enable + Save + Apply")

        # 3. Serveurs
        print("\n── 3. Serveur(s) WireGuard ────────────────────────────")
        r = await c.get("/wireguard/server/searchServer")
        servers = r.json().get("rows", [])
        if not servers:
            print("   ✗ Aucun serveur configuré")
        for s in servers:
            en = "✓" if s.get("enabled") == "1" else "✗"
            print(f"   {en} {s.get('name'):<20} {s.get('tunneladdress')} :{s.get('port')}")

        # 4. Peers
        print("\n── 4. Peers (clients) ─────────────────────────────────")
        r = await c.get("/wireguard/client/searchClient")
        peers = r.json().get("rows", [])
        if not peers:
            print("   ✗ Aucun peer configuré")
        for p in peers:
            en = "✓" if p.get("enabled") == "1" else "✗"
            print(f"   {en} {p.get('name'):<20} {p.get('tunneladdress')}")

        # 5. Handshakes live (endpoint manque parfois selon version OPNsense)
        print("\n── 5. Handshakes runtime ──────────────────────────────")
        try:
            r = await c.get("/wireguard/service/showhandshake")
            if r.status_code == 200:
                rows = r.json().get("rows") or r.json().get("response") or []
                if rows:
                    import time
                    now = time.time()
                    for row in rows:
                        name = row.get("name") or row.get("peer", "?")
                        last = row.get("latest-handshake") or row.get("handshake")
                        if last and str(last).isdigit():
                            age = now - int(last)
                            sym = "✓" if age < 180 else ("~" if age < 900 else "✗")
                            print(f"   {sym} {name:<20} dernier handshake il y a {int(age)}s")
                        else:
                            print(f"   ? {name:<20} pas de handshake connu")
                else:
                    print("   (aucun handshake — service peut-être arrêté)")
            else:
                print(f"   ⚠ /wireguard/service/showhandshake HTTP {r.status_code}")
        except Exception as e:
            print(f"   ⚠ handshake inaccessible : {e}")

    # 6. Test de connectivité UDP 51820 vers WAN
    print("\n── 6. Joignabilité UDP 51820 ──────────────────────────")
    import subprocess
    wan_ip = os.getenv("BREACH_WG_OPNSENSE_WAN_IP", "").strip()
    if not wan_ip:
        print("   (BREACH_WG_OPNSENSE_WAN_IP non défini — skip)")
    else:
        result = subprocess.run(
            ["nc", "-uvz", "-w", "2", wan_ip, "51820"],
            capture_output=True, text=True, timeout=5,
        )
        print(f"   nc -uvz {wan_ip} 51820 → {result.returncode}")
        if result.stderr:
            print(f"   {result.stderr.strip()}")

    print("\n──────────────────────────────────────────────────────")
    print("Suggestion : si status != running → service start")
    print("             si pas de handshake après 30s → vérifier firewall WAN OPNsense")
    print("             (pass rule UDP dport 51820)")


# ── Main ──────────────────────────────────────────────────────────────────────

async def main() -> None:
    parser = argparse.ArgumentParser(
        description="Configure WireGuard OPNsense mesh ASP via agent LoRA"
    )
    sub = parser.add_subparsers(dest="cmd")

    p_srv = sub.add_parser("setup-server", help="Créer/mettre à jour le serveur WireGuard")
    p_srv.add_argument("--privkey", required=True)
    p_srv.add_argument("--pubkey",  required=True)
    p_srv.add_argument("--cidr",    default="10.10.0.1/24")
    p_srv.add_argument("--port",    type=int, default=51820)

    p_peer = sub.add_parser("add-peer", help="Ajouter/mettre à jour un peer")
    p_peer.add_argument("--name",   required=True)
    p_peer.add_argument("--pubkey", required=True)
    p_peer.add_argument("--ip",     required=True)

    sub.add_parser("apply", help="Appliquer la configuration (reconfigure)")
    sub.add_parser("list",  help="Lister la configuration WireGuard (config statique)")
    sub.add_parser("status", help="État runtime : handshakes récents par peer")
    sub.add_parser("verify", help="Ping chaque peer via son IP tunnel (verify_routing)")
    sub.add_parser("genkey", help="Générer une paire de clés WireGuard localement")
    sub.add_parser("diagnose", help="Diagnostic complet : service, config, peers, handshakes")
    p_svc = sub.add_parser("service", help="Contrôle du service WireGuard (start/stop/restart/status/reconfigure)")
    p_svc.add_argument("action", choices=["start", "stop", "restart", "status", "reconfigure"])
    p_boot = sub.add_parser("bootstrap", help="Bootstrap complet OPNsense pour WG (idempotent) : enable + pass rule WAN + outbound NAT")
    p_boot.add_argument("--wg-port",  type=int, default=51820)
    p_boot.add_argument("--nat-src",  default="192.168.21.0/24", help="Subnet source à SNAT vers wg (défaut LAN korrig)")
    p_boot.add_argument("--nat-dst",  default="10.10.0.0/24",   help="Subnet WG cible")
    p_boot.add_argument("--wg-iface", default="wg0",            help="Interface WireGuard côté OPNsense")
    p_rm = sub.add_parser("remove-peer", help="Retirer un peer WireGuard par nom")
    p_rm.add_argument("--name", required=True)
    sub.add_parser("attach-peers", help="Attacher tous les clients WG existants à l'instance serveur (idempotent)")

    args = parser.parse_args()

    # genkey ne touche pas à OPNsense ni au LoRA — exécute en local directement.
    if args.cmd == "genkey":
        gen_wg_keypair()
        return

    if not OPNSENSE_KEY or not OPNSENSE_SECRET:
        print("✗ BREACH_OPNSENSE_API_KEY / BREACH_OPNSENSE_API_SECRET non définis dans .env")
        sys.exit(1)

    print(f"── OPNsense {OPNSENSE_IP}:{OPNSENSE_PORT}  agent {LLAMA_URL} ──────────")

    if args.cmd == "setup-server":
        if BYPASS_LLM:
            print("  (bypass LLM — appel direct API)")
            await _execute_setup_server({
                "name":          _WG_INSTANCE_NAME,
                "privkey":       args.privkey,
                "pubkey":        args.pubkey,
                "tunneladdress": args.cidr,
                "port":          args.port,
            })
        else:
            cap = {
                "directive": "setup_wireguard_server",
                "entities": {"HOSTNAME": ["opnsense"]},
                "context": {
                    "source":         "mesh_config",
                    "reason":         "wireguard_server_init",
                    "instance_name":  _WG_INSTANCE_NAME,
                    "server_privkey": args.privkey,
                    "server_pubkey":  args.pubkey,
                    "tunnel_cidr":    args.cidr,
                    "listen_port":    args.port,
                },
            }
            tool_call = await _infer(cap)
            if not tool_call:
                print("✗ L'agent n'a pas généré de tool_call — abandon")
                sys.exit(1)
            fn_name = tool_call.get("function", {}).get("name", "")
            if fn_name != "setup_wireguard_server":
                print(f"✗ Tool call inattendu : {fn_name}")
                sys.exit(1)
            await _execute_setup_server(_get_args(tool_call))

    elif args.cmd == "add-peer":
        ip_cidr = args.ip if "/" in args.ip else f"{args.ip}/32"
        if BYPASS_LLM:
            print("  (bypass LLM — appel direct API)")
            await _execute_add_peer({
                "name":      args.name,
                "pubkey":    args.pubkey,
                "tunnel_ip": ip_cidr,
                "keepalive": 25,
            })
        else:
            cap = {
                "directive": "add_wireguard_peer",
                "entities": {"IP_ADDRESS": [ip_cidr.split("/")[0]]},
                "context": {
                    "source":      "mesh_config",
                    "reason":      "wireguard_mesh_peer",
                    "peer_name":   args.name,
                    "peer_pubkey": args.pubkey,
                    "tunnel_ip":   ip_cidr,
                    "keepalive":   25,
                },
            }
            tool_call = await _infer(cap)
            if not tool_call:
                print("✗ L'agent n'a pas généré de tool_call — abandon")
                sys.exit(1)
            fn_name = tool_call.get("function", {}).get("name", "")
            if fn_name not in ("add_wireguard_peer", "add_wireguard_client"):
                print(f"✗ Tool call inattendu : {fn_name}")
                sys.exit(1)
            await _execute_add_peer(_get_args(tool_call))

    elif args.cmd == "apply":
        await apply_config()

    elif args.cmd == "list":
        await list_config()

    elif args.cmd == "status":
        await status_runtime()

    elif args.cmd == "verify":
        await verify_peers()

    elif args.cmd == "remove-peer":
        await remove_peer(args.name)

    elif args.cmd == "attach-peers":
        await attach_all_peers_to_server()

    elif args.cmd == "genkey":
        gen_wg_keypair()

    elif args.cmd == "diagnose":
        await diagnose()

    elif args.cmd == "service":
        await service_control(args.action)

    elif args.cmd == "bootstrap":
        await bootstrap(args.wg_port, args.nat_src, args.nat_dst, args.wg_iface)

    else:
        parser.print_help()


if __name__ == "__main__":
    import warnings
    warnings.filterwarnings("ignore")
    asyncio.run(main())
