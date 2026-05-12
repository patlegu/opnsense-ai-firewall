output "opnsense_public_ip" {
  description = "IP publique WAN d'OPNsense (SSH/admin/API/WG endpoint)"
  value       = module.opnsense.public_ip
}

output "opnsense_url" {
  description = "URL UI OPNsense"
  value       = "https://${module.opnsense.public_ip}:${var.opnsense_api_port}"
}

output "opnsense_ssh" {
  description = "Commande SSH OPNsense"
  value       = "ssh -p ${var.opnsense_ssh_port} root@${module.opnsense.public_ip}"
}

output "debian_vms" {
  description = "Détails des VMs Debian créées (IP publique + WG IP)"
  value = {
    for k, m in nonsensitive(module.debian) :
    k => {
      name        = m.name
      ipv4_public = m.ipv4_public
      wg_ip       = m.wg_ip
      ssh         = "ssh ${var.vm_username}@${m.ipv4_public}"
    }
  }
}

output "summary" {
  value = <<-EOT
    kickstart-forge instance ${var.instance_id} (${var.location})
    ────────────────────────────────────────────────────────
    OPNsense
      Public IP : ${module.opnsense.public_ip}
      Web UI    : https://${module.opnsense.public_ip}:${var.opnsense_api_port}
      SSH       : ssh -p ${var.opnsense_ssh_port} root@${module.opnsense.public_ip}
      LAN IP    : 10.${var.instance_id}.0.2
      WG hub    : ${var.wg_enabled ? "10.10.0.1/24 (port 51820/udp)" : "désactivé"}

    Debian VMs (${length(nonsensitive(var.debian_vms))} déployée(s)) :
    %{~for k, m in nonsensitive(module.debian)}
      ${k}
        name    : ${m.name}
        public  : ${m.ipv4_public}
        wg      : ${m.wg_ip != "" ? m.wg_ip : "—"}
        ssh     : ssh ${var.vm_username}@${m.ipv4_public}
    %{~endfor}
  EOT
}
