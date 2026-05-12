# Credentials & accès — kickstart-forge

Récapitulatif des URLs, tunnels SSH, comptes et tokens pour les
services du lab. Les secrets **dynamiques** (hashes, tokens générés
à l'install) sont indiqués par leur **source** (tfvars chiffré ou
fichier sur la VM) — pas inclus en clair ici pour qu'on puisse
versionner le doc.

> Scope kickstart-forge : OPNsense + VMs LLM (llama-server) + VMs
> Debian. Pas de T-Pot / Wazuh / OpenCTI ici (cf. purpleteam-forge
> pour ces composants).

---

## Topologie d'accès

```text
Internet
  │
  ▼  WAN OPNsense (IP publique Hetzner)
┌──────────────────────────────────────────────────────────────┐
│ OPNsense firewall — 10.{instance_id}.0.2 — port 2222 SSH    │
│                                          / 4443 API HTTPS    │
│  ├─ LLM opnsense  10.X.0.10  (llama-server 8080 + LoRA WG)  │
│  └─ VMs Debian    10.X.0.50+                                │
└──────────────────────────────────────────────────────────────┘
```

Aucune VM derrière OPNsense n'a d'IP publique par défaut
(`public_ipv4_enabled = false`). Accès via :

- **SSH** : `ssh -J root@<opnsense_public>:2222 redteam@<priv_ip>` (ProxyJump)
- **UI Web** : `ssh -L <port_local>:<priv_ip>:<port_service> root@<opnsense_public> -p 2222 -N` puis navigateur sur `http://localhost:<port_local>`

`<opnsense_public>` est l'IP publique Hetzner attribuée à la VM
OPNsense (variable selon l'instance). Récupérable par :

```bash
tofu output -raw opnsense_public_ip
```

---

## OPNsense

| Item               | Valeur / Source                                 |
|--------------------|-------------------------------------------------|
| **Web UI**         | `https://<opnsense_public>:4443`                |
| **API**            | `https://<opnsense_public>:4443/api`            |
| **SSH**            | `ssh -p 2222 root@<opnsense_public>`            |
| User               | `root`                                          |
| Password           | hash dans `terraform.tfvars` → `opnsense_root_hash`. Clair = passé à `openssl passwd -6` lors du run de `init-secrets.sh` (à sauvegarder hors-repo, ex: 1Password). |
| API key            | `terraform.tfvars` → `opnsense_api_key`         |
| API secret         | `terraform.tfvars` → `opnsense_api_secret_plain`|

⚠️ **Port SSH 2222** (pas 22). Le port 22 reste libre pour un
honeypot Cowrie si tu adjoins T-Pot dans le futur (cf. ptm-forge).

Si oubli → ré-extraction depuis le tfvars chiffré :

```bash
sops --decrypt /srv/_AI/kickstart-forge/infra/envs/hcloud/terraform.tfvars.sops \
  | grep -E "opnsense_(root|api)"
```

---

## VMs LLM (llama-server + LoRA)

| Item               | Valeur                                                           |
|--------------------|------------------------------------------------------------------|
| **SSH ProxyJump**  | `ssh -J root@<opnsense_public>:2222 redteam@10.X.0.10`           |
| **API endpoint**   | `http://10.X.0.10:8080` (depuis le LAN ou via WG mesh 10.10.0.10) |
| API key (Bearer)   | `tfvars → llm_vms.opnsense.llama_api_key`                        |
| LoRAs actifs       | `tfvars → llm_vms.opnsense.active_loras`                         |
| User Linux         | `redteam` (ou ce que définit `vm_username`)                      |
| Linux password     | hash dans `tfvars → vm_password_hash` (commun à toutes les VMs)  |

Tunnel SSH si tu veux taper le LLM depuis ton laptop :

```bash
ssh -L 8090:10.X.0.10:8080 root@<opnsense_public> -p 2222 -N
# Puis :
curl -H "Authorization: Bearer $LLAMA_API_KEY" \
  http://localhost:8090/v1/chat/completions \
  -d '{"model": "qwen2.5-3b", "messages": [...]}'
```

---

## VMs Debian (peers WireGuard)

| Item               | Valeur                                                |
|--------------------|-------------------------------------------------------|
| **SSH ProxyJump**  | `ssh -J root@<opnsense_public>:2222 redteam@<priv_ip>`|
| User Linux         | `redteam` (ou `vm_username`)                          |
| Password           | hash dans `tfvars → vm_password_hash`                 |
| WG mesh            | clés dans `tfvars → debian_vms[<name>].wg_*`         |

IPs typiques (selon les entrées dans `tfvars → debian_vms`,
exemples du tfvars.example) :

- `attacker-1` → `10.1.0.50` / WG `10.10.0.50`
- `c2-1`       → `10.1.0.51` / WG `10.10.0.51`

---

## WireGuard mesh — étape manuelle d'attache des peers

⚠️ **Le module wireguard-mesh ne complète PAS l'attache des peers
à l'instance WireGuard côté OPNsense.** Il crée les peers via API,
mais l'**association peer ↔ instance Server** doit être faite à
la main une fois après chaque `tofu apply` qui ajoute des peers.

Procédure :

1. Web UI OPNsense → **VPN > WireGuard > Instances**
2. Éditer l'instance `wg0` (10.10.0.1/24)
3. Section **Peers** : sélectionner tous les peers présents (les
   noms sont `${project_name}-<entry>` — ex: `redteam-attacker-1`,
   `redteam-c2-1`, `redteam-llm-opnsense`)
4. **Save**, puis **Apply**

Sans cette étape, les peers existent mais ne sont pas servis par
l'interface `wg0` → handshake impossible côté VMs.

Cf. mémoire opérateur : `feedback_opnsense_wg_peer_attach`.

---

## Récap tunnels SSH (à lancer en parallèle)

Un tunnel multi-forward typique pour le scope kst :

```bash
ssh -p 2222 -N \
  -L 8090:10.X.0.10:8080  \
  -L 4443:10.X.0.2:4443   \
  root@<opnsense_public>
```

| Local            | Service                                  |
|------------------|------------------------------------------|
| `localhost:8090` | LLM llama-server API                     |
| `localhost:4443` | OPNsense API (alternative à direct WAN)  |

---

## À durcir avant production

- **Pas de TLS** sur l'API llama-server (Bearer token uniquement) — accès via tunnel SSH OK pour lab, pas pour exposition externe directe
- **`vm_password_hash`** commun à toutes les VMs — OK pour fallback console Hetzner, mais désactiver le password login (`PasswordAuthentication no` dans sshd_config) en prod
- **Clé API OPNsense** stockée en clair dans `terraform.tfvars` — chiffrer avec sops (`sops --encrypt terraform.tfvars > terraform.tfvars.sops`) et committer la version chiffrée uniquement
