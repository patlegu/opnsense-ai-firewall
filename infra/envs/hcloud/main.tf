# ── infra/envs/hcloud — opnsense-ai-firewall (Hetzner Cloud) ────────────────
#
# Stack par défaut :
#   - 1 OPNsense cx23 (hub WireGuard, installation ISO + push config XML)
#   - N VMs Debian (cx23 par défaut) — peers WireGuard du mesh
#   - Optionnel : VMs LLM (llama-server + LoRA WireGuard)
#   - Optionnel : subnet vswitch pour serveurs dédiés Hetzner Robot
#
# Pré-requis sur la machine qui lance tofu :
#   - hcloud CLI (utilisé par module hcloud-opnsense via local-exec)
#   - Python venv avec httpx (pour wireguard-mesh — opnsense-wg-agent.py)
#   - HCLOUD_TOKEN + TF_HTTP_USERNAME / TF_HTTP_PASSWORD exportés (.env)
#
# Workflow :
#   bash scripts/init-secrets.sh --auto    # auto-générer secrets manquants
#   tofu init
#   tofu plan
#   tofu apply

terraform {
  required_providers {
    hcloud = { source = "hetznercloud/hcloud", version = "~> 1.49" }
    local  = { source = "hashicorp/local", version = "~> 2.5" }
    null   = { source = "hashicorp/null", version = "~> 3.2" }
  }

  # Backend = local par défaut (state dans infra/envs/hcloud/terraform.tfstate,
  # gitignoré). Pour basculer sur GitLab Managed Terraform State :
  #
  # 1. Trouver l'ID du projet GitLab opnsense-ai-firewall (Settings > General).
  # 2. Décommenter le bloc backend "http" ci-dessous, remplacer <PROJECT_ID>.
  # 3. Renseigner TF_HTTP_USERNAME / TF_HTTP_PASSWORD (PAT GitLab scope api).
  # 4. tofu init -migrate-state.
  #
  # backend "http" {
  #   address        = "https://gitlab.com/api/v4/projects/<PROJECT_ID>/terraform/state/hcloud"
  #   lock_address   = "https://gitlab.com/api/v4/projects/<PROJECT_ID>/terraform/state/hcloud/lock"
  #   unlock_address = "https://gitlab.com/api/v4/projects/<PROJECT_ID>/terraform/state/hcloud/lock"
  #   lock_method    = "POST"
  #   unlock_method  = "DELETE"
  #   retry_wait_min = 5
  # }
}

provider "hcloud" {
  # Si var.hcloud_token est vide, le provider hcloud lira HCLOUD_TOKEN de
  # l'environnement (chargé depuis `.env` à la racine via
  # `set -a && . ../../../.env && set +a`). Évite de dupliquer le secret
  # dans terraform.tfvars.
  token = var.hcloud_token != "" ? var.hcloud_token : null
}

locals {
  net_base        = "10.${var.instance_id}.0"
  opnsense_lan_ip = "${local.net_base}.2"
  hetzner_gateway = "${local.net_base}.1"
  lan_cidr        = "${local.net_base}.0/24"

  # AllowedIPs des VMs Debian — accès au mesh + LAN OPNsense
  vm_wg_allowed = ["10.10.0.0/24", local.lan_cidr]
}

# ── Clé SSH partagée ─────────────────────────────────────────────────────────
# Hetzner refuse les pubkey dupliquées (uniqueness_error). Si la même clé
# est déjà enregistrée (ex: importée par asp-forge), on la référence via
# data source au lieu d'en créer une nouvelle.
#
# Renseigner var.ssh_key_name_existing avec le nom Hetzner exact pour
# réutiliser. Sinon, vide = création d'une nouvelle clé.

data "hcloud_ssh_key" "existing" {
  count = var.ssh_key_name_existing != "" ? 1 : 0
  name  = var.ssh_key_name_existing
}

resource "hcloud_ssh_key" "kickstart" {
  count      = var.ssh_key_name_existing != "" ? 0 : 1
  name       = "${var.project_name}-forge-${var.instance_id}"
  # Seule la PREMIÈRE clé du tableau est enregistrée comme hcloud_ssh_key —
  # c'est celle qui sert au bootstrap (rescue mode). Les autres clés sont
  # injectées dans authorized_keys d'OPNsense via le config.xml du module
  # iac-modules (qui concatène ssh_public_key avec \n entre entrées).
  public_key = var.ssh_public_keys[0]
}

locals {
  ssh_key_id = var.ssh_key_name_existing != "" ? data.hcloud_ssh_key.existing[0].id : hcloud_ssh_key.kickstart[0].id

  # String multi-lignes passée à l'iac-modules — devient N lignes dans
  # /root/.ssh/authorized_keys d'OPNsense via le template config.xml.
  ssh_authorized_keys_joined = join("\n", var.ssh_public_keys)
}

# ── Réseau privé Hetzner ─────────────────────────────────────────────────────

module "network" {
  source = "git::ssh://git@gitlab.com/llm_tests/iac-modules.git//hcloud/network?ref=v0.5.0"

  project_name   = var.project_name
  instance_id    = var.instance_id
  network_zone   = var.network_zone
  opnsense_ip    = local.opnsense_lan_ip
  vswitch_id     = var.vswitch_id
  vswitch_subnet = var.vswitch_subnet
}

# ── OPNsense (hub) ───────────────────────────────────────────────────────────

module "opnsense" {
  source = "git::ssh://git@gitlab.com/llm_tests/iac-modules.git//hcloud/opnsense?ref=v0.5.0"

  project_name      = var.project_name
  instance_id       = var.instance_id
  opnsense_hostname = var.opnsense_hostname
  opnsense_domain   = var.opnsense_domain

  # Pas d'alias_ip dans le subnet vswitch : Hetzner refuse d'attacher des
  # ressources Cloud à un subnet vswitch. Le trafic des serveurs dédiés
  # transite via la route 0.0.0.0/0 → opnsense_lan_ip déjà définie sur le
  # hcloud_network. OPNsense voit le trafic sur vtnet1 / 10.1.0.2.
  # lan_alias_ips = var.vswitch_id != 0 ? [var.opnsense_vswitch_ip] : []
  server_type    = var.opnsense_server_type
  location       = var.location
  ssh_key_id     = local.ssh_key_id
  ssh_public_key = local.ssh_authorized_keys_joined
  network_id     = module.network.network_id
  hcloud_token   = var.hcloud_token

  opnsense_image_url = var.opnsense_image_url
  snapshot_name      = var.opnsense_snapshot_name

  root_hash  = var.opnsense_root_hash
  api_key    = var.opnsense_api_key
  api_secret = var.opnsense_api_secret

  lan_ip          = local.opnsense_lan_ip
  lan_prefix      = 24
  lan_dhcp_from   = "${local.net_base}.200"
  lan_dhcp_to     = "${local.net_base}.254"
  api_port        = var.opnsense_api_port
  ssh_port        = var.opnsense_ssh_port
  hetzner_gateway = local.hetzner_gateway
  lan_cidr        = local.lan_cidr

  # Active 51820/UDP côté firewall pour le mesh WG (mais WG hub setup via mesh module)
  wg_enabled     = var.wg_enabled
  honeypot_ports = []

  depends_on = [module.network]
}

# ── VMs Debian Red Team (peers WG) ───────────────────────────────────────────
#
# Définies via var.debian_vms — map dont chaque entrée crée une VM.
# Si wg_enabled, chaque VM doit avoir wg_ip + wg_privkey + wg_pubkey
# pré-générés (wg genkey | tee >(wg pubkey)).

module "debian" {
  source   = "git::ssh://git@gitlab.com/llm_tests/iac-modules.git//hcloud/debian?ref=v0.5.0"
  for_each = nonsensitive(var.debian_vms)

  name             = "${var.project_name}-${each.key}"
  role             = each.value.role
  server_type      = each.value.server_type
  location         = each.value.location
  ssh_key_id       = local.ssh_key_id
  ssh_public_key   = local.ssh_authorized_keys_joined
  vm_username      = var.vm_username
  vm_password_hash = var.vm_password_hash

  network_id          = module.network.network_id
  private_ip          = each.value.private_ip
  public_ipv4_enabled = each.value.public_ipv4_enabled

  extra_packages = each.value.extra_packages
  extra_runcmd   = each.value.extra_runcmd

  # WG activé seulement si la VM a une privkey (cohérent avec module llm)
  wg_enabled         = var.wg_enabled && each.value.wg_privkey != ""
  wg_ip              = each.value.wg_ip
  wg_privkey         = each.value.wg_privkey
  wg_server_pubkey   = var.wg_server_pubkey
  wg_server_endpoint = "${module.opnsense.public_ip}:51820"
  wg_allowed_ips     = local.vm_wg_allowed

  depends_on = [module.network, module.opnsense]
}

# ── VMs LLM (llama-server + LoRA) ────────────────────────────────────────────
#
# Au moins 1 VM avec rôle "opnsense" est nécessaire pour piloter wireguard-mesh
# (LoRA WireGuard chargé sur cette VM, utilisé par opnsense-wg-agent.py).
# Variables clés par instance dans var.llm_vms :
#   role               : "opnsense" (LoRA WG), "soc", "renfort", ...
#   server_type        : cax21 (ARM, llama-server-aarch64) ou cx23 (x86)
#   llama_local_path   : binaire llama-server adapté à l'arch
#   gguf_local_path    : modèle GGUF (Qwen 3B Q4_KM par défaut)
#
# Les paths llama_*/gguf_* peuvent référencer asp-forge directement
# (/srv/asp-forge/llama-bin/, /srv/asp-forge/gguf/) — pas besoin de
# dupliquer les ~3 GB de binaires + modèles + LoRA.

module "llm" {
  source   = "git::ssh://git@gitlab.com/llm_tests/iac-modules.git//hcloud/agent?ref=v0.5.0"
  for_each = nonsensitive(var.llm_vms)

  project_name       = var.project_name
  role               = each.key
  pool_role          = each.value.pool_role
  server_type        = each.value.server_type
  location           = each.value.location
  ssh_key_id         = local.ssh_key_id
  vm_username        = var.vm_username
  vm_password_hash   = var.vm_password_hash
  ssh_public_key     = local.ssh_authorized_keys_joined
  llama_api_key      = each.value.llama_api_key
  llama_download_url = each.value.llama_download_url
  llama_local_path   = each.value.llama_local_path
  gguf_download_url  = each.value.gguf_download_url
  gguf_local_path    = each.value.gguf_local_path
  gguf_filename      = each.value.gguf_filename
  context_size       = each.value.context_size
  llama_port         = each.value.llama_port
  parallel           = each.value.parallel
  active_loras       = each.value.active_loras

  # Download via GitLab Generic Packages — libs en archive selon l'arch
  download_auth_header = var.llm_download_auth_header
  lora_download_urls   = var.llm_lora_download_urls
  libs_archive_url     = startswith(each.value.server_type, "cax") ? var.llm_libs_archive_url_aarch64 : var.llm_libs_archive_url_amd64
  network_id          = module.network.network_id
  private_ip          = each.value.private_ip
  public_ipv4_enabled = each.value.public_ipv4_enabled
  # WG activé seulement si la VM a une privkey (sinon cloud-init écrit un
  # wg0.conf invalide). Permet de créer la VM en phase 1 sans mesh, puis
  # de la rejoindre en phase 2 en remplissant les clés.
  wg_enabled         = var.wg_enabled && each.value.wg_privkey != ""
  wg_ip              = each.value.wg_ip
  wg_privkey         = each.value.wg_privkey
  wg_server_pubkey   = var.wg_server_pubkey
  wg_server_endpoint = "${module.opnsense.public_ip}:51820"

  depends_on = [module.network, module.opnsense]
}

# ── WireGuard mesh sur OPNsense ──────────────────────────────────────────────
# Configure le hub WG côté OPNsense (server + bootstrap) et ajoute chaque
# VM Debian comme peer. Idempotent. Nécessite que le module hcloud-opnsense
# ait fini son boot (depends_on transitif via opnsense.public_ip).

module "wireguard_mesh" {
  count  = var.wg_enabled ? 1 : 0
  source = "git::ssh://git@gitlab.com/llm_tests/iac-modules.git//wireguard-mesh?ref=v0.5.0"

  project_name        = var.project_name
  opnsense_ip         = module.opnsense.public_ip
  opnsense_port       = tostring(var.opnsense_api_port)
  opnsense_api_key    = var.opnsense_api_key
  opnsense_api_secret = var.opnsense_api_secret_plain
  python_bin          = var.python_bin
  llama_url           = var.llama_url
  llama_loras         = var.llama_loras
  # Bearer token pour authentifier le script auprès de llama-server
  # (cohérent avec llama_api_key de la VM LLM "opnsense")
  llama_api_key = try(var.llm_vms["opnsense"].llama_api_key, "")

  server_privkey = var.wg_server_privkey
  server_pubkey  = var.wg_server_pubkey
  wg_cidr        = "10.10.0.1/24"
  wg_port        = 51820

  bootstrap_nat_src  = local.lan_cidr
  bootstrap_nat_dst  = "10.10.0.0/24"
  bootstrap_wg_iface = "wg0"

  peers = merge(
    {
      for k, v in nonsensitive(var.debian_vms) :
      k => { pubkey = v.wg_pubkey, wg_ip = v.wg_ip }
      if v.wg_pubkey != "" && v.wg_ip != ""
    },
    {
      for k, v in nonsensitive(var.llm_vms) :
      "llm-${k}" => { pubkey = v.wg_pubkey, wg_ip = v.wg_ip }
      if v.wg_pubkey != "" && v.wg_ip != ""
    },
  )

  depends_on = [module.opnsense, module.debian, module.llm]
}

# ── LLM EMBARQUÉ DANS OPNSENSE (caractéristique de ce repo) ─────────────────
#
# Après que le module hcloud-opnsense ait fini d'installer la VM, on SCP
# le binaire llama-server natif FreeBSD + ses libs + les scripts rc.d et
# post-install, puis on déclenche le post-install qui :
#   - télécharge la base Phi-3 GGUF et le LoRA depuis HuggingFace
#   - active et démarre le service llama (rc.d)
#   - poll /health pour valider que llama-server répond sur 127.0.0.1:8080
#
# Les triggers re-déclenchent ce null_resource si :
#   - le binaire local change (rebuild llama.cpp)
#   - les paramètres LLM changent (URLs, port, ctx_size)
#
# Pré-requis : llama-bin/freebsd-amd64/llama-server doit exister localement
# (palier B). Sinon, tofu apply fail-fast avec un message lisible.

locals {
  llm_bin_path   = "${path.module}/../../../llama-bin/freebsd-amd64/llama-server"
  llm_libs_path  = "${path.module}/../../../llama-bin/freebsd-amd64/lib"
  llm_agent_path = "${path.module}/../../../agent/oaf_agent.py"

  llm_rc_script = templatefile("${path.module}/templates/rc-llama.tftpl", {
    listen_addr   = var.opnsense_llm_listen_addr
    port          = var.opnsense_llm_port
    ctx_size      = var.opnsense_llm_ctx_size
    base_filename = var.opnsense_llm_base_filename
    lora_filename = var.opnsense_llm_lora_filename
  })

  llm_post_install = templatefile("${path.module}/templates/post-install-llm.sh.tftpl", {
    base_url      = var.opnsense_llm_base_url
    base_filename = var.opnsense_llm_base_filename
    lora_url      = var.opnsense_llm_lora_url
    lora_filename = var.opnsense_llm_lora_filename
    listen_addr   = var.opnsense_llm_listen_addr
    port          = var.opnsense_llm_port
  })
}

# Sentinelle qui échoue si le binaire FreeBSD est absent et que le LLM
# est activé. Évite un null_resource qui se vautre 5 min plus tard avec
# un message obscur.
resource "null_resource" "check_llama_binary" {
  count = var.opnsense_llm_enabled ? 1 : 0
  lifecycle {
    precondition {
      condition     = fileexists(local.llm_bin_path)
      error_message = "Binaire llama-server FreeBSD manquant à ${local.llm_bin_path}. Lancer 'bash scripts/build-llama-freebsd.sh root@<IP_VM_FREEBSD>' d'abord (voir docs/build-llama-freebsd.md), ou désactiver opnsense_llm_enabled=false."
    }
  }
}

resource "null_resource" "embedded_llm" {
  count = var.opnsense_llm_enabled ? 1 : 0

  # Re-trigger si le binaire local change OU si les paramètres LLM changent.
  triggers = {
    binary_md5    = filemd5(local.llm_bin_path)
    agent_md5     = filemd5(local.llm_agent_path)
    rc_script_sha = sha256(local.llm_rc_script)
    post_inst_sha = sha256(local.llm_post_install)
    base_url      = var.opnsense_llm_base_url
    lora_url      = var.opnsense_llm_lora_url
    listen_addr   = var.opnsense_llm_listen_addr
    port          = var.opnsense_llm_port
    opnsense_ip   = module.opnsense.public_ip
  }

  connection {
    type        = "ssh"
    host        = module.opnsense.public_ip
    port        = var.opnsense_ssh_port
    user        = "root"
    private_key = file(pathexpand(var.ssh_private_key_path))
    timeout     = "5m"
  }

  # 1. Préparer l'arborescence /var/llm/{bin,lib,models,agent} +
  #    s'assurer que python3 est installé (l'agent local en a besoin).
  #    `pkg` est dans OPNsense ; python3 est en pkg "python311" (ou
  #    fallback "python3") et un symlink /usr/local/bin/python3 doit
  #    pointer dessus.
  provisioner "remote-exec" {
    inline = [
      "mkdir -p /var/llm/bin /var/llm/lib /var/llm/models /var/llm/agent /var/log/llama",
      "command -v python3 >/dev/null 2>&1 || pkg install -y python311 || pkg install -y python3",
    ]
  }

  # 2. SCP du binaire llama-server (FreeBSD amd64, compilé en palier B)
  provisioner "file" {
    source      = local.llm_bin_path
    destination = "/var/llm/bin/llama-server"
  }

  # 3. SCP du dossier lib/ (dossier complet, récursif)
  provisioner "file" {
    source      = "${local.llm_libs_path}/"
    destination = "/var/llm/lib"
  }

  # 4. SCP du rc.d script (rendu depuis template)
  provisioner "file" {
    content     = local.llm_rc_script
    destination = "/usr/local/etc/rc.d/llama"
  }

  # 5. SCP du script post-install (rendu depuis template)
  provisioner "file" {
    content     = local.llm_post_install
    destination = "/tmp/post-install-llm.sh"
  }

  # 6. SCP de l'agent local oaf_agent.py (palier D)
  provisioner "file" {
    source      = local.llm_agent_path
    destination = "/var/llm/agent/oaf_agent.py"
  }

  # 7. Fichier d'environnement /etc/oaf-agent.env consommé par le wrapper.
  #    Contient les credentials API OPNsense (clé + secret en clair) ;
  #    permissions 0600 root:wheel. Mode read-only une fois en place.
  provisioner "file" {
    content     = <<-EOT
      OAF_LLM_URL=http://${var.opnsense_llm_listen_addr}:${var.opnsense_llm_port}
      OAF_OPNSENSE_URL=https://127.0.0.1:${var.opnsense_api_port}
      OAF_OPNSENSE_KEY=${var.opnsense_api_key}
      OAF_OPNSENSE_SECRET=${var.opnsense_api_secret_plain}
    EOT
    destination = "/etc/oaf-agent.env"
  }

  # 8. Wrapper /usr/local/bin/oaf-agent : source /etc/oaf-agent.env puis
  #    exécute oaf_agent.py avec python3. Permet d'écrire simplement
  #    `oaf-agent ask "..."` sans avoir à exporter à la main.
  provisioner "file" {
    content     = <<-EOT
      #!/bin/sh
      set -a
      . /etc/oaf-agent.env
      set +a
      exec /usr/local/bin/python3 /var/llm/agent/oaf_agent.py "$@"
    EOT
    destination = "/usr/local/bin/oaf-agent"
  }

  # 9. chmod + exécution du post-install (download GGUF + start service + healthcheck)
  provisioner "remote-exec" {
    inline = [
      "chmod 600 /etc/oaf-agent.env",
      "chmod +x /var/llm/bin/llama-server /usr/local/etc/rc.d/llama /tmp/post-install-llm.sh /usr/local/bin/oaf-agent",
      "/tmp/post-install-llm.sh",
    ]
  }

  depends_on = [
    module.opnsense,
    null_resource.check_llama_binary,
  ]
}
