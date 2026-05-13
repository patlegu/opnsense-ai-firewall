# Credentials & access — kickstart-forge

Summary of URLs, SSH tunnels, accounts and tokens for the lab
services. **Dynamic** secrets (hashes, tokens generated at install
time) are referenced by their **source** (encrypted tfvars or
file on the VM) — not included in clear here so the doc can be
versioned.

> Scope kickstart-forge: OPNsense + LLM VMs (llama-server) + Debian
> VMs. No T-Pot / Wazuh / OpenCTI here (cf. purpleteam-forge
> for these components).

---

## Access topology

```text
Internet
  │
  ▼  WAN OPNsense (public Hetzner IP)
┌──────────────────────────────────────────────────────────────┐
│ OPNsense firewall — 10.{instance_id}.0.2 — port 2222 SSH    │
│                                          / 4443 API HTTPS    │
│  ├─ LLM opnsense  10.X.0.10  (llama-server 8080 + LoRA WG)  │
│  └─ Debian VMs    10.X.0.50+                                │
└──────────────────────────────────────────────────────────────┘
```

No VM behind OPNsense has a public IP by default
(`public_ipv4_enabled = false`). Access via:

- **SSH**: `ssh -J root@<opnsense_public>:2222 redteam@<priv_ip>` (ProxyJump)
- **Web UI**: `ssh -L <port_local>:<priv_ip>:<port_service> root@<opnsense_public> -p 2222 -N` then browser to `http://localhost:<port_local>`

`<opnsense_public>` is the public Hetzner IP assigned to the
OPNsense VM (varies per instance). Retrievable via:

```bash
tofu output -raw opnsense_public_ip
```

---

## OPNsense

| Item               | Value / Source                                  |
|--------------------|-------------------------------------------------|
| **Web UI**         | `https://<opnsense_public>:4443`                |
| **API**            | `https://<opnsense_public>:4443/api`            |
| **SSH**            | `ssh -p 2222 root@<opnsense_public>`            |
| User               | `root`                                          |
| Password           | hash in `terraform.tfvars` → `opnsense_root_hash`. Cleartext = passed to `openssl passwd -6` during the `init-secrets.sh` run (to be saved outside the repo, e.g.: 1Password). |
| API key            | `terraform.tfvars` → `opnsense_api_key`         |
| API secret         | `terraform.tfvars` → `opnsense_api_secret_plain`|

⚠️ **SSH port 2222** (not 22). Port 22 is kept free for a
Cowrie honeypot if you attach T-Pot later (cf. ptm-forge).

If forgotten → re-extract from the encrypted tfvars:

```bash
sops --decrypt /srv/_AI/kickstart-forge/infra/envs/hcloud/terraform.tfvars.sops \
  | grep -E "opnsense_(root|api)"
```

---

## LLM VMs (llama-server + LoRA)

| Item               | Value                                                            |
|--------------------|------------------------------------------------------------------|
| **SSH ProxyJump**  | `ssh -J root@<opnsense_public>:2222 redteam@10.X.0.10`           |
| **API endpoint**   | `http://10.X.0.10:8080` (from the LAN or via WG mesh 10.10.0.10) |
| API key (Bearer)   | `tfvars → llm_vms.opnsense.llama_api_key`                        |
| Active LoRAs       | `tfvars → llm_vms.opnsense.active_loras`                         |
| Linux user         | `redteam` (or whatever `vm_username` defines)                    |
| Linux password     | hash in `tfvars → vm_password_hash` (common to all VMs)          |

SSH tunnel if you want to hit the LLM from your laptop:

```bash
ssh -L 8090:10.X.0.10:8080 root@<opnsense_public> -p 2222 -N
# Then:
curl -H "Authorization: Bearer $LLAMA_API_KEY" \
  http://localhost:8090/v1/chat/completions \
  -d '{"model": "qwen2.5-3b", "messages": [...]}'
```

---

## Debian VMs (WireGuard peers)

| Item               | Value                                                 |
|--------------------|-------------------------------------------------------|
| **SSH ProxyJump**  | `ssh -J root@<opnsense_public>:2222 redteam@<priv_ip>`|
| Linux user         | `redteam` (or `vm_username`)                          |
| Password           | hash in `tfvars → vm_password_hash`                   |
| WG mesh            | keys in `tfvars → debian_vms[<name>].wg_*`            |

Typical IPs (depending on the entries in `tfvars → debian_vms`,
examples from tfvars.example):

- `attacker-1` → `10.1.0.50` / WG `10.10.0.50`
- `c2-1`       → `10.1.0.51` / WG `10.10.0.51`

---

## WireGuard mesh — manual peer attach step

⚠️ **The wireguard-mesh module does NOT complete the peer attach
to the WireGuard instance on the OPNsense side.** It creates the
peers via API, but the **peer ↔ Server instance association**
must be done by hand once after each `tofu apply` that adds peers.

Procedure:

1. OPNsense Web UI → **VPN > WireGuard > Instances**
2. Edit instance `wg0` (10.10.0.1/24)
3. **Peers** section: select all the peers present (the
   names are `${project_name}-<entry>` — e.g.: `redteam-attacker-1`,
   `redteam-c2-1`, `redteam-llm-opnsense`)
4. **Save**, then **Apply**

Without this step, the peers exist but are not served by
the `wg0` interface → handshake impossible from the VM side.

Cf. operator memory: `feedback_opnsense_wg_peer_attach`.

---

## SSH tunnel recap (to launch in parallel)

A typical multi-forward tunnel for the kst scope:

```bash
ssh -p 2222 -N \
  -L 8090:10.X.0.10:8080  \
  -L 4443:10.X.0.2:4443   \
  root@<opnsense_public>
```

| Local            | Service                                  |
|------------------|------------------------------------------|
| `localhost:8090` | LLM llama-server API                     |
| `localhost:4443` | OPNsense API (alternative to direct WAN) |

---

## To harden before production

- **No TLS** on the llama-server API (Bearer token only) — access via SSH tunnel OK for lab, not for direct external exposure
- **`vm_password_hash`** common to all VMs — OK for Hetzner console fallback, but disable password login (`PasswordAuthentication no` in sshd_config) in prod
- **OPNsense API key** stored in clear in `terraform.tfvars` — encrypt with sops (`sops --encrypt terraform.tfvars > terraform.tfvars.sops`) and commit only the encrypted version
