#!/usr/bin/env python3
"""
oaf_agent.py — agent local OPNsense AI Firewall (palier D).

Vit DANS la VM OPNsense (FreeBSD). Pipeline minimaliste :

    intent NL  ─►  CAP v1 packet  ─►  llama-server local  ─►  tool_call
                                                                  │
                                                                  ▼
                                        OPNsense API 127.0.0.1:4443
                                              │
                                              ▼ (scope_confirmed guard)
                                          réponse JSON
                                              │
                                              ▼
                                       intent NL  ◄── llama-server (synth)

Pas de framework Python lourd : juste stdlib + httpx. Pas de chatbot,
pas d'OpenAI SDK. On parle à llama-server en /v1/chat/completions
(format OpenAI tool-calling), et à OPNsense en /api/<module>/...

Usage CLI (sur OPNsense, post-déploiement) :

    oaf-agent ask "List all scheduled cron jobs"
    oaf-agent ask "Block IP 203.0.113.42 on WAN" --confirm
    oaf-agent health

Le mode dry-run est par défaut sur les outils mutating (rules, NAT,
service restart) — l'opérateur doit ajouter --confirm pour scope_confirmed=true.
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import sys
import urllib.request
import urllib.error
from dataclasses import dataclass
from typing import Any

# ── Config (figée par le déploiement, surchargable par env) ─────────────────

LLM_URL = os.environ.get("OAF_LLM_URL", "http://127.0.0.1:8080")
OPNSENSE_URL = os.environ.get("OAF_OPNSENSE_URL", "https://127.0.0.1:4443")
OPNSENSE_KEY = os.environ.get("OAF_OPNSENSE_KEY", "")
OPNSENSE_SECRET = os.environ.get("OAF_OPNSENSE_SECRET", "")
DEFAULT_TIMEOUT = int(os.environ.get("OAF_TIMEOUT", "120"))

# Liste blanche de tools — n'importe quel autre tool_call est rejeté.
# Format : nom_outil → (méthode_http, chemin, est_mutating)
TOOLS_WHITELIST: dict[str, tuple[str, str, bool]] = {
    # Reads (passive, scope_confirmed pas requis)
    "get_cron_jobs": ("GET", "/api/cron/settings/searchJobs", False),
    "list_firewall_rules": ("GET", "/api/firewall/filter/get", False),
    "list_nat_rules": ("GET", "/api/firewall/source_nat/get", False),
    "list_wg_peers": ("GET", "/api/wireguard/server/get", False),
    "system_status": ("GET", "/api/diagnostics/system/system_information", False),
    # Mutating (scope_confirmed obligatoire)
    "block_ip": ("POST", "/api/firewall/filter/addRule", True),
    "schedule_cron_job": ("POST", "/api/cron/settings/addJob", True),
    "restart_unbound": ("POST", "/api/unbound/service/restart", True),
    "restart_suricata": ("POST", "/api/ids/service/restart", True),
}


# ── Modèles légers ──────────────────────────────────────────────────────────


@dataclass
class CAPPacket:
    """Coordinator-Agent Packet v1 — calque CAP v1 du SOC asp-forge."""

    directive: str
    entities: dict[str, list[str]]
    args: dict[str, Any]
    scope_confirmed: bool = False

    def to_messages(self) -> list[dict[str, Any]]:
        """Convertit le CAP en messages OpenAI-style pour llama-server."""
        return [
            {
                "role": "system",
                "content": (
                    "You are an OPNsense agent. Given a CAP v1 packet, "
                    "return EXACTLY ONE tool_call from the whitelist that "
                    "fulfills the directive. No prose, no markdown."
                ),
            },
            {
                "role": "user",
                "content": json.dumps(
                    {
                        "directive": self.directive,
                        "entities": self.entities,
                        "args": self.args,
                    },
                    ensure_ascii=False,
                ),
            },
        ]


# ── LLM client ──────────────────────────────────────────────────────────────


def call_llama(messages: list[dict[str, Any]], tools: list[dict[str, Any]]) -> dict[str, Any]:
    """POST sur le /v1/chat/completions du llama-server local."""
    payload = {
        "model": "phi-3-mini",  # libre — llama-server l'ignore
        "messages": messages,
        "tools": tools,
        "tool_choice": "auto",
        "temperature": 0.0,
    }
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        f"{LLM_URL}/v1/chat/completions",
        data=data,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=DEFAULT_TIMEOUT) as resp:
        return json.loads(resp.read().decode("utf-8"))


def whitelist_tools() -> list[dict[str, Any]]:
    """Convertit le TOOLS_WHITELIST en schéma OpenAI tools."""
    out = []
    for name in TOOLS_WHITELIST:
        out.append(
            {
                "type": "function",
                "function": {
                    "name": name,
                    "description": f"OPNsense action {name}",
                    "parameters": {"type": "object", "properties": {}, "required": []},
                },
            }
        )
    return out


# ── OPNsense client ─────────────────────────────────────────────────────────


def call_opnsense(method: str, path: str, body: dict[str, Any] | None = None) -> dict[str, Any]:
    """HTTPS local OPNsense API (127.0.0.1:4443) — auth Basic key:secret."""
    if not OPNSENSE_KEY or not OPNSENSE_SECRET:
        raise RuntimeError(
            "OAF_OPNSENSE_KEY / OAF_OPNSENSE_SECRET non définis dans l'environnement."
        )
    import base64
    import ssl

    url = f"{OPNSENSE_URL}{path}"
    headers = {
        "Authorization": "Basic " + base64.b64encode(
            f"{OPNSENSE_KEY}:{OPNSENSE_SECRET}".encode()
        ).decode(),
        "Content-Type": "application/json",
    }
    data = json.dumps(body).encode("utf-8") if body else None
    # 127.0.0.1 → cert self-signed accepté.
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    with urllib.request.urlopen(req, timeout=DEFAULT_TIMEOUT, context=ctx) as resp:
        return json.loads(resp.read().decode("utf-8"))


# ── Pipeline ────────────────────────────────────────────────────────────────


def run_intent(intent: str, scope_confirmed: bool = False) -> int:
    """intent NL → CAP → tool_call → API OPNsense → résultat."""
    logger = logging.getLogger("oaf-agent")

    # Étape 1 : on construit un CAP packet minimaliste à partir de l'intent.
    # Dans la vraie chaîne agentique (SOC), c'est le coordinator-pilot qui
    # produit le CAP. Ici, on dégrade : on enveloppe l'intent NL telle quelle
    # dans un CAP avec directive vide et entités vides — le LoRA fera le
    # mapping.
    cap = CAPPacket(directive=intent, entities={}, args={}, scope_confirmed=scope_confirmed)
    logger.info("CAP: %s", cap)

    # Étape 2 : appel llama-server.
    resp = call_llama(cap.to_messages(), whitelist_tools())
    try:
        message = resp["choices"][0]["message"]
    except (KeyError, IndexError) as e:
        logger.error("réponse llama-server malformée : %s", e)
        print(json.dumps(resp, indent=2))
        return 2

    tool_calls = message.get("tool_calls") or []
    if not tool_calls:
        logger.warning("pas de tool_call retourné ; réponse texte :")
        print(message.get("content") or "(vide)")
        return 1

    # Étape 3 : whitelist + scope_confirmed.
    tc = tool_calls[0]
    fn = tc["function"]["name"]
    args_raw = tc["function"].get("arguments", "{}")
    try:
        args = json.loads(args_raw) if isinstance(args_raw, str) else args_raw
    except json.JSONDecodeError:
        args = {}

    if fn not in TOOLS_WHITELIST:
        logger.error("tool '%s' hors whitelist", fn)
        return 3
    method, path, mutating = TOOLS_WHITELIST[fn]
    if mutating and not scope_confirmed:
        logger.error("tool '%s' est mutating, --confirm requis", fn)
        print(json.dumps({"would_call": {"tool": fn, "method": method, "path": path, "args": args}}, indent=2))
        return 4

    # Étape 4 : appel OPNsense local.
    logger.info("→ %s %s args=%s", method, path, args)
    result = call_opnsense(method, path, body=args if method != "GET" else None)
    print(json.dumps(result, indent=2, ensure_ascii=False))
    return 0


def health() -> int:
    """Smoke test : llama-server + OPNsense API joignables."""
    print(f"[oaf] LLM_URL={LLM_URL}")
    try:
        with urllib.request.urlopen(f"{LLM_URL}/health", timeout=5) as r:
            print(f"[oaf] llama-server : {r.status} {r.read(80).decode('utf-8', 'ignore').strip()}")
    except (urllib.error.URLError, OSError) as e:
        print(f"[oaf] llama-server INDISPONIBLE : {e}")
        return 1
    print(f"[oaf] OPNSENSE_URL={OPNSENSE_URL}")
    try:
        result = call_opnsense("GET", "/api/diagnostics/system/system_information")
        print(f"[oaf] OPNsense API OK : keys={list(result.keys())[:5]}")
    except (RuntimeError, urllib.error.URLError, OSError) as e:
        print(f"[oaf] OPNsense API INDISPONIBLE : {e}")
        return 1
    return 0


# ── CLI ─────────────────────────────────────────────────────────────────────


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="oaf-agent", description=__doc__.strip().splitlines()[0])
    parser.add_argument("--verbose", "-v", action="store_true")
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_ask = sub.add_parser("ask", help="exécuter une intent admin")
    p_ask.add_argument("intent", help="texte libre, ex: 'list cron jobs'")
    p_ask.add_argument(
        "--confirm",
        action="store_true",
        help="set scope_confirmed=true (requis pour les outils mutating)",
    )

    sub.add_parser("health", help="smoke test llama-server + OPNsense API")

    ns = parser.parse_args(argv)
    logging.basicConfig(
        level=logging.DEBUG if ns.verbose else logging.INFO,
        format="%(asctime)s %(name)s %(levelname)s %(message)s",
    )

    if ns.cmd == "health":
        return health()
    if ns.cmd == "ask":
        return run_intent(ns.intent, scope_confirmed=ns.confirm)
    return 2


if __name__ == "__main__":
    sys.exit(main())
