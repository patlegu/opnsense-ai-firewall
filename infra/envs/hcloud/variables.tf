variable "project_name" {
  description = "Préfixe utilisé pour les noms et labels Hetzner (network, server, ssh-key…). Override via TF_VAR_project_name dans .env."
  type        = string
  default     = "oaf"
}

variable "instance_id" {
  description = "Numéro d'instance (1-9) — détermine les CIDRs 10.{id}.0.0/24 et préfixe les noms"
  type        = number
  default     = 1
}

variable "network_zone" {
  description = "Zone réseau Hetzner (eu-central pour hel1/nbg1/fsn1)"
  type        = string
  default     = "eu-central"
}

variable "location" {
  description = "Datacenter Hetzner (hel1 = Helsinki par défaut)"
  type        = string
  default     = "hel1"
}

# ── vSwitch Hetzner Robot (serveurs dédiés) ──────────────────────────────────
# Désactivé par défaut. Pour activer :
#   1. Créer un vSwitch côté Robot Web (Server > vSwitches > Create)
#   2. Renseigner var.vswitch_id avec l'ID numérique
#   3. tofu apply → ajoute le subnet vswitch + alias_ip .254 sur OPNsense

variable "vswitch_id" {
  description = "ID numérique du vSwitch Hetzner Robot. 0 = désactivé."
  type        = number
  default     = 0
}

variable "vswitch_subnet" {
  description = "Plage IP du subnet vswitch (/24 dans le /20 du réseau)."
  type        = string
  default     = "10.1.1.0/24"
}

variable "opnsense_vswitch_ip" {
  description = "IP OPNsense .254 sur le subnet vswitch (gateway pour les serveurs dédiés). .1 = gateway Hetzner réservée."
  type        = string
  default     = "10.1.1.254"
}

# ── OPNsense ─────────────────────────────────────────────────────────────────

variable "opnsense_server_type" {
  description = <<-EOT
    Type Hetzner OPNsense — DOIT être x86 (amd64). Pour ce repo, l'OPNsense
    embarque llama-server + LoRA Phi-3 in-box, donc il faut de la RAM :
      - cx33 : 4vCPU/8GB ~10€/mois (default, juste pour Phi-3 mini Q4)
      - cx43 : 8vCPU/16GB ~25€/mois (confortable, latence d'inférence réduite)
    cx23 (4GB) est trop juste pour faire tourner pf + llama-server simultanément.
  EOT
  type        = string
  default     = "cx33"
}

variable "opnsense_image_url" {
  description = "URL image OPNsense amd64 (.img.bz2). Variantes disponibles : nano (dual console serial+video), serial (serial only), vga (video only). Hetzner Console UI = émulation video, donc nano (dual) ou vga compatibles."
  type        = string
  default     = "https://mirror.ams1.nl.leaseweb.net/opnsense/releases/26.1.6/OPNsense-26.1.6-nano-amd64.img.bz2"
}

variable "opnsense_snapshot_name" {
  description = "ID ou nom d'un snapshot Hetzner OPNsense pré-configuré (ex: '378474881' partagé avec asp-forge). Si renseigné, prime sur opnsense_image_url — déploiement direct depuis snapshot, pas de rescue+dd. Évite les soucis console/loader.conf."
  type        = string
  default     = ""
}

variable "opnsense_api_port" {
  description = "Port HTTPS API OPNsense"
  type        = number
  default     = 4443
}

variable "opnsense_ssh_port" {
  description = "Port SSH OPNsense sur WAN"
  type        = number
  default     = 2222
}

variable "opnsense_hostname" {
  description = "Hostname OPNsense (champ <hostname> dans config.xml)"
  type        = string
  default     = "opnsense"
}

variable "opnsense_domain" {
  description = "Domaine OPNsense (champ <domain> dans config.xml)"
  type        = string
  default     = "lab.local"
}

# ── VMs Debian ──────────────────────────────────────────────────────────────

variable "debian_vms" {
  description = <<-EOT
    Map des VMs Debian à déployer comme peers WireGuard.

    Clé = nom court (devient $${project_name}-<key> côté Hetzner).
    Pour chaque VM :
      - role           : label (attacker, c2, recon, web, db, ...)
      - server_type    : cx23, cpx22, cx33, etc.
      - location       : hel1, fsn1, nbg1
      - private_ip     : IP statique dans 10.{instance_id}.0.0/24
      - wg_ip          : IP dans le mesh WG 10.10.0.0/24
      - wg_privkey/pubkey : paire générée par `wg genkey | tee >(wg pubkey)`
      - extra_packages : paquets apt supplémentaires
      - extra_runcmd   : commandes shell additionnelles au boot
  EOT
  type = map(object({
    role           = optional(string, "redteam")
    server_type    = optional(string, "cx23")
    location       = optional(string, "hel1")
    private_ip     = optional(string, "")
    wg_ip          = optional(string, "")
    wg_privkey     = optional(string, "")
    wg_pubkey      = optional(string, "")
    extra_packages = optional(list(string), [])
    extra_runcmd   = optional(list(string), [])
    # IP publique sur la VM (false = sortie via OPNsense uniquement, recommandé)
    public_ipv4_enabled = optional(bool, false)
  }))
  sensitive = true
  default   = {}
}

# ── VMs LLM (llama-server + LoRA WireGuard) ─────────────────────────────────

variable "llm_vms" {
  description = <<-EOT
    Map des VMs LLM (llama-server) à déployer.

    Optionnel — la mesh WG fonctionne sans LLM côté Tofu (BREACH_BYPASS_LLM=1).
    Le LoRA WireGuard reste utile pour des scénarios agentic post-déploiement.

    Pour chaque VM :
      - pool_role        : rôle libre (opnsense, soc, agent, ...)
      - server_type      : cax21 (ARM, plus économique) ou cx23 (x86)
      - location         : hel1, fsn1, nbg1
      - llama_api_key    : Bearer token (recommandé)
      - llama_download_url / gguf_download_url : URLs Generic Packages
      - llama_local_path / gguf_local_path : alternative SCP local
      - context_size     : taille contexte (4096 défaut)
      - parallel         : nb d'inférences simultanées (--parallel)
      - private_ip       : IP statique réseau privé (10.X.0.10+)
      - wg_ip / wg_privkey / wg_pubkey : pour intégration mesh WG
  EOT
  type = map(object({
    pool_role     = optional(string, "")
    server_type   = optional(string, "cax21")
    location      = optional(string, "hel1")
    llama_api_key = optional(string, "")
    # Soit URL (download depuis GitLab Generic Packages), soit local_path (SCP local).
    # Le 1er non-vide gagne côté module.
    llama_download_url = optional(string, "")
    llama_local_path   = optional(string, "")
    gguf_download_url  = optional(string, "")
    gguf_local_path    = optional(string, "")
    gguf_filename      = optional(string, "model.gguf")
    context_size       = optional(number, 4096)
    llama_port         = optional(number, 8080)
    parallel           = optional(number, 1)
    active_loras       = optional(list(string), [])
    private_ip         = optional(string, "")
    wg_ip              = optional(string, "")
    wg_privkey         = optional(string, "")
    wg_pubkey          = optional(string, "")
    # IP publique sur la VM (false = sortie via OPNsense uniquement, recommandé)
    public_ipv4_enabled = optional(bool, false)
  }))
  sensitive = true
  default   = {}
}

# Auth + URLs partagées pour le download des binaires/modèles depuis GitLab
# Generic Packages (uploadés par scripts/upload-llm-assets.sh).

variable "llm_download_auth_header" {
  description = "Header HTTP pour curl GitLab Generic Packages (ex: 'PRIVATE-TOKEN: glpat-xxx'). Vide = pas d'auth."
  type        = string
  sensitive   = true
  default     = ""
}

variable "llm_lora_download_urls" {
  description = "Map name → URL pour télécharger les LoRA. Doit contenir au moins les clés référencées par active_loras des llm_vms."
  type        = map(string)
  default     = {}
}

# ── LLM EMBARQUÉ DANS OPNSENSE (caractéristique de ce repo) ─────────────────
#
# Au lieu d'un sidecar VM, on push llama-server + base GGUF + LoRA
# directement sur la VM OPNsense (FreeBSD). Voir docs/embedded-llm.md
# pour les raisons d'être prudent.

variable "opnsense_llm_enabled" {
  description = "Activer le LLM in-box sur OPNsense (llama-server FreeBSD + base GGUF + LoRA Phi-3 OPNsense)."
  type        = bool
  default     = true
}

variable "opnsense_llm_base_url" {
  description = "URL HTTPS pour télécharger la base Phi-3 mini GGUF (Q4_K_M recommandé). Hugging Face direct ou miroir interne."
  type        = string
  default     = "https://huggingface.co/microsoft/Phi-3-mini-4k-instruct-gguf/resolve/main/Phi-3-mini-4k-instruct-q4.gguf"
}

variable "opnsense_llm_base_filename" {
  description = "Nom de fichier local pour la base GGUF (path effectif /var/llm/base.gguf <- ce filename)."
  type        = string
  default     = "phi-3-mini-4k-q4.gguf"
}

variable "opnsense_llm_lora_url" {
  description = "URL HTTPS pour télécharger le LoRA OPNsense (GGUF, déjà converti pour llama-server)."
  type        = string
  default     = "https://huggingface.co/patlegu/opnsense-agent-phi35/resolve/main/opnsense-agent-phi35-q4_k_m.gguf"
}

variable "opnsense_llm_lora_filename" {
  description = "Nom de fichier local pour le LoRA GGUF."
  type        = string
  default     = "opnsense-agent-phi35.gguf"
}

variable "opnsense_llm_server_binary" {
  description = "Chemin local (côté kickstart) vers le binaire llama-server compilé pour FreeBSD amd64. Sera SCP-uploadé sur OPNsense. À produire via scripts/build-llama-freebsd.sh — voir palier B."
  type        = string
  default     = "../../../llama-bin/freebsd-amd64/llama-server"
}

variable "opnsense_llm_libs_dir" {
  description = "Dossier local contenant les .so partagées FreeBSD requises par llama-server. Tar-gzipé puis extrait sur OPNsense."
  type        = string
  default     = "../../../llama-bin/freebsd-amd64/lib"
}

variable "opnsense_llm_listen_addr" {
  description = "Adresse d'écoute du llama-server sur OPNsense. 127.0.0.1 = jamais exposé WAN (recommandé)."
  type        = string
  default     = "127.0.0.1"
}

variable "opnsense_llm_port" {
  description = "Port d'écoute du llama-server sur OPNsense."
  type        = number
  default     = 8080
}

variable "opnsense_llm_ctx_size" {
  description = "Taille de contexte. 4096 = max de Phi-3 mini 4k. Baisser à 2048 si manque de RAM."
  type        = number
  default     = 4096
}

# ── WireGuard mesh ───────────────────────────────────────────────────────────

variable "wg_enabled" {
  description = "Activer le mesh WireGuard OPNsense ↔ VMs Debian. Default false : sécurise le 1er tofu apply à froid (OPNsense pas encore initialisé, pas de clé WG, etc.). Bascule à true en phase 2 une fois les wg_pubkey/wg_privkey générés."
  type        = bool
  default     = false
}

variable "wg_server_privkey" {
  description = "Clé privée WG du hub OPNsense (10.10.0.1) — wg genkey"
  type        = string
  sensitive   = true
  default     = ""
}

variable "wg_server_pubkey" {
  description = "Clé publique WG du hub OPNsense — echo PRIVKEY | wg pubkey"
  type        = string
  default     = ""
}

# ── Credentials sensibles ────────────────────────────────────────────────────

variable "ssh_public_key" {
  description = "Clé SSH publique (authorized_keys root OPNsense + VMs Debian/LLM)"
  type        = string
}

variable "ssh_key_name_existing" {
  description = "Nom d'une clé SSH déjà enregistrée côté Hetzner (vu via 'hcloud ssh-key list'). Si renseigné, on la réutilise au lieu de créer une nouvelle (Hetzner refuse les pubkey dupliquées). Vide = création d'une nouvelle clé '$${project_name}-forge-<instance_id>'."
  type        = string
  default     = ""
}

variable "vm_username" {
  description = "Nom d'utilisateur créé sur les VMs Debian + LLM (cloud-init). Couplé à vm_password_hash."
  type        = string
  default     = "redteam"
}

variable "vm_password_hash" {
  description = "Hash SHA512 mot de passe pour vm_username — openssl passwd -6 'mdp'"
  type        = string
  sensitive   = true
}

variable "hcloud_token" {
  description = "Token API Hetzner Cloud (Read+Write — requis pour rescue mode + serveurs)"
  type        = string
  sensitive   = true
}

variable "opnsense_root_hash" {
  description = "Hash SHA512 mot de passe root OPNsense"
  type        = string
  sensitive   = true
}

variable "opnsense_api_key" {
  description = "Clé API OPNsense (80 chars hex — openssl rand -hex 40)"
  type        = string
  sensitive   = true
}

variable "opnsense_api_secret" {
  description = "Secret API OPNsense HASHÉ (openssl passwd -6 \"$SECRET\") — utilisé dans config.xml"
  type        = string
  sensitive   = true
}

variable "opnsense_api_secret_plain" {
  description = "Secret API OPNsense EN CLAIR — utilisé pour les calls HTTP du module wireguard-mesh"
  type        = string
  sensitive   = true
  default     = ""
}

# ── Module wireguard-mesh — accès LLM (script opnsense-wg-agent.py) ─────────

variable "python_bin" {
  description = "Binaire Python avec httpx installé (pour appeler l'API OPNsense). Path relatif résolu depuis infra/envs/hcloud (cwd de tofu) — la venv créée par scripts/setup-wsl.sh est à la racine du repo."
  type        = string
  default     = "../../../.venv/bin/python3"
}

variable "llama_url" {
  description = "URL du llama-server (LoRA WireGuard) — accédé par opnsense-wg-agent.py pour générer les calls API"
  type        = string
  default     = "http://192.168.51.10:8080"
}

variable "llama_loras" {
  description = "Mapping LoRA index — format 'name:idx,name:idx'"
  type        = string
  default     = "opnsense:0,wireguard:1,crowdsec:2"
}
