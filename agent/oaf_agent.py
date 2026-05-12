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
import re
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

# ── Catalogue des outils ─────────────────────────────────────────────────────
#
# Sémantique :
#   - CATALOG : noms sur lesquels le LoRA a été entraîné, avec leur
#     (method, endpoint, mutating). Auto-généré depuis le repo
#     cyber-agent-engine par scripts/generate-tools-catalog.py.
#     Tout nom HORS de ce catalog = hallucination → rejet.
#   - KNOWN_UNMAPPED : noms reconnus par le LoRA mais sans endpoint
#     mappé côté client OPNsense — l'agent log clairement qu'il connaît
#     le tool mais ne sait pas le router (à compléter au cas par cas).
#   - BLACKLIST : opt-in opérateur via env OAF_BLACKLIST="a,b,c" ou
#     fichier /etc/oaf-agent.blacklist (un nom par ligne). Permet de
#     restreindre le périmètre runtime (mode read-only, démo non
#     disruptive…) sans toucher au catalog.
from tools_catalog import TOOLS_CATALOG, TOOL_DESCRIPTIONS, KNOWN_UNMAPPED  # noqa: E402


def _load_blacklist() -> set[str]:
    """Lit OAF_BLACKLIST (env, csv) + /etc/oaf-agent.blacklist (1/ligne)."""
    bl: set[str] = set()
    env = os.environ.get("OAF_BLACKLIST", "")
    bl.update(n.strip() for n in env.split(",") if n.strip())
    try:
        with open("/etc/oaf-agent.blacklist", encoding="utf-8") as f:
            bl.update(line.strip() for line in f if line.strip() and not line.startswith("#"))
    except FileNotFoundError:
        pass
    return bl


TOOLS_BLACKLIST: set[str] = _load_blacklist()


# ── Modèles légers ──────────────────────────────────────────────────────────


@dataclass
class CAPPacket:
    """Coordinator-Agent Packet v1 — calque CAP v1 du SOC asp-forge."""

    directive: str
    entities: dict[str, list[str]]
    args: dict[str, Any]
    scope_confirmed: bool = False

    def to_messages(self) -> list[dict[str, Any]]:
        """Convertit le CAP en messages OpenAI-style pour llama-server.

        Format aligné sur ce sur quoi le LoRA opnsense-agent-phi35 a été
        entraîné : system prompt court + user.content en TEXTE NATUREL
        (pas JSON CAP). C'est ce qui produit le mieux des `tool_calls`
        structurés du modèle (sinon il a tendance à répondre en texte
        listant les noms d'outils candidats).
        """
        return [
            {
                "role": "system",
                "content": (
                    "You are an OPNsense agent. Choose the correct tool "
                    "from the provided list and call it with appropriate "
                    "arguments to fulfill the user's request."
                ),
            },
            {
                "role": "user",
                "content": self.directive,
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


# Overrides locaux : aliases / endpoints qu'on ajoute au catalog auto.
# Cas typiques :
#   - alias observé en sortie LoRA (ex: `diagnostics_cron` au lieu de
#     `get_cron_jobs` que le catalog ne contient pas)
#   - endpoint custom pour un wrapper haut niveau (`block_ip` qui passe
#     via `addRule` avec un payload qu'on adapte ensuite)
#
# Ces overrides COMPLÈTENT TOOLS_CATALOG (ils ne le remplacent pas).
TOOLS_LOCAL_OVERRIDES: dict[str, tuple[str, str, bool]] = {
    # Aliases vus en sortie LoRA mais hors catalog auto
    "diagnostics_cron": ("GET", "/api/cron/settings/searchJobs", False),
    "get_cron_jobs": ("GET", "/api/cron/settings/searchJobs", False),
    "list_cron_jobs": ("GET", "/api/cron/settings/searchJobs", False),
    "get_filter_rule": ("GET", "/api/firewall/filter/get", False),
    "list_firewall_rules": ("GET", "/api/firewall/filter/get", False),
    "wireguard_client_get_client_builder": ("GET", "/api/wireguard/client/get", False),
    "get_wireguard_clients": ("GET", "/api/wireguard/client/get", False),
    "get_wireguard_peers": ("GET", "/api/wireguard/server/get", False),
    "list_wg_peers": ("GET", "/api/wireguard/server/get", False),
    "system_status": ("GET", "/api/diagnostics/system/system_information", False),
    "get_system_information": ("GET", "/api/diagnostics/system/system_information", False),
    "list_firewall_states": ("GET", "/api/diagnostics/firewall/pf_states", False),
    "block_ip": ("POST", "/api/firewall/filter/addRule", True),
    "restart_unbound": ("POST", "/api/unbound/service/restart", True),
    "restart_suricata": ("POST", "/api/ids/service/restart", True),
}

# Catalog effectif = auto-généré + overrides locaux. C'est ce que
# l'agent utilise au dispatch.
TOOLS_EFFECTIVE: dict[str, tuple[str, str, bool]] = {
    **TOOLS_CATALOG,
    **TOOLS_LOCAL_OVERRIDES,
}

# Descriptions complétées : auto-générées du training + locales
TOOL_DESCRIPTIONS_LOCAL: dict[str, str] = {
    "diagnostics_cron": "Get list of all scheduled Cron jobs",
    "get_cron_jobs": "Get list of all scheduled Cron jobs",
    "list_cron_jobs": "Get list of all scheduled Cron jobs",
    "block_ip": "Block an IP address by creating a firewall filter rule",
    "list_firewall_states": "List active pf states (current connections)",
    "system_status": "Get OPNsense system information (hostname, version, uptime)",
}
TOOL_DESCRIPTIONS_EFFECTIVE: dict[str, str] = {**TOOL_DESCRIPTIONS, **TOOL_DESCRIPTIONS_LOCAL}


# Adaptateurs args : transforme le payload simple produit par le LoRA
# (aligné training, ex: {"ip": "1.2.3.4"}) en payload conforme au schema
# REST d'OPNsense (ex: {"rule": {action, interface, source_net, ...}}).
# Si un tool n'a pas d'adapter ici, les args du LoRA passent tels quels.
ARG_ADAPTERS: dict[str, Any] = {
    # block_ip → POST /api/firewall/filter/addRule
    # OPNsense attend une structure {"rule": {...}} avec au minimum les
    # champs action, interface, source_net (ou source.address), protocol.
    "block_ip": lambda args: {
        "rule": {
            "enabled": "1",
            "action": "block",
            "interface": args.get("interface", "wan"),
            "direction": "in",
            "ipprotocol": "inet",
            "protocol": "any",
            "source_net": args.get("ip") or args.get("source") or args.get("address", ""),
            "destination_net": "any",
            "description": args.get("description") or f"Blocked {args.get('ip','')} by oaf-agent",
        }
    },
}


def extract_tool_calls_from_content(content: str) -> list[dict[str, Any]]:
    """Extrait les tool_calls encapsulés dans des special tokens Phi-3.

    Le LoRA `opnsense-agent-phi35` a été entraîné avec un format custom
    où le tool_call est encadré par `<|tool_calls|>...<|tool_response|>`
    dans le content du message assistant. Le chat template par défaut de
    llama-server ne sait pas extraire ces tokens vers le champ structuré
    `message.tool_calls`, donc on parse manuellement le content.

    Format vu en production :

        <|tool_calls|>
        [{"id": "call_xxx", "type": "function",
          "function": {"name": "get_cron_jobs", "arguments": "{}"}}]
        <|tool_response|>
        ...

    Retourne la liste des tool_calls trouvés (en général 1), ou liste
    vide si aucun match.
    """
    # On capture le JSON entre <|tool_calls|> et le prochain marker
    # (<|tool_response|> ou fin du content).
    pattern = re.compile(
        r"<\|tool_calls\|>\s*(\[.*?\])\s*(?:<\|tool_response\|>|$)",
        re.DOTALL,
    )
    m = pattern.search(content)
    if not m:
        return []
    try:
        calls = json.loads(m.group(1))
        return calls if isinstance(calls, list) else []
    except json.JSONDecodeError:
        return []


def whitelist_tools() -> list[dict[str, Any]]:
    """Convertit TOOLS_EFFECTIVE en schéma OpenAI tools, blacklist filtrée.

    On envoie au LoRA seulement les tools dispatchables (catalog auto +
    overrides locaux) MOINS la blacklist opérateur. Le LoRA peut encore
    halluciner un nom hors de cette liste — on filtrera côté dispatch.
    """
    out = []
    for name in TOOLS_EFFECTIVE:
        if name in TOOLS_BLACKLIST:
            continue
        out.append(
            {
                "type": "function",
                "function": {
                    "name": name,
                    "description": TOOL_DESCRIPTIONS_EFFECTIVE.get(name, f"OPNsense action {name}"),
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
    }
    # Content-Type seulement si on envoie un body. OPNsense renvoie
    # HTTP 400 sur un GET qui porte Content-Type: application/json sans
    # body associé (alors que curl sans `-d` n'envoie pas ce header → 200).
    data = None
    if body is not None:
        data = json.dumps(body).encode("utf-8")
        headers["Content-Type"] = "application/json"
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

    # Fallback : le LoRA opnsense-agent-phi35 produit ses tool_calls dans
    # le content via les special tokens <|tool_calls|>...<|tool_response|>
    # (format training Phi-3). llama-server ne les extrait pas en
    # message.tool_calls, donc on parse manuellement.
    if not tool_calls:
        parsed = extract_tool_calls_from_content(message.get("content") or "")
        if parsed:
            tool_calls = parsed
            logger.info("tool_call extrait du content via special tokens")

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

    # Trois cas pour valider le tool_call :
    #   - dans TOOLS_EFFECTIVE → dispatchable
    #   - dans KNOWN_UNMAPPED  → connu du LoRA mais pas mappé côté agent
    #     (à compléter dans TOOLS_LOCAL_OVERRIDES)
    #   - sinon                 → hallucination LoRA
    if fn in TOOLS_BLACKLIST:
        logger.error("tool '%s' désactivé par l'opérateur (blacklist)", fn)
        return 5
    if fn not in TOOLS_EFFECTIVE:
        if fn in KNOWN_UNMAPPED:
            logger.error(
                "tool '%s' connu du LoRA mais sans endpoint mappé côté agent "
                "(à ajouter dans TOOLS_LOCAL_OVERRIDES de oaf_agent.py)",
                fn,
            )
            return 6
        logger.error("tool '%s' inconnu (hallucination, hors training LoRA)", fn)
        return 3
    method, path, mutating = TOOLS_EFFECTIVE[fn]
    if mutating and not scope_confirmed:
        logger.error("tool '%s' est mutating, --confirm requis", fn)
        print(json.dumps({"would_call": {"tool": fn, "method": method, "path": path, "args": args}}, indent=2))
        return 4

    # Étape 4 : adapter les args vers le schema attendu par l'API OPNsense.
    # Le LoRA produit des args "simples" alignés sur le format training (ex:
    # {ip, description}) mais l'API REST OPNsense attend des structures
    # plus complexes (ex: {rule: {action, interface, source_net, ...}}).
    # On applique un mapping par tool si nécessaire — sinon les args
    # passent tels quels.
    adapted = ARG_ADAPTERS.get(fn, lambda a: a)(args)
    if adapted is not args:
        logger.info("args adaptés (%s) : %s", fn, adapted)

    # Étape 5 : appel OPNsense local.
    logger.info("→ %s %s args=%s", method, path, adapted)
    result = call_opnsense(method, path, body=adapted if method != "GET" else None)
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
