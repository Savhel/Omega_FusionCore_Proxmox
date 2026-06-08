#!/usr/bin/env bash
# Omega VM readiness watchdog : garde les VMs Omega locales PRÊTES pour les tests.
# Sur chaque nœud Proxmox, à chaque tick (timer systemd) il :
#   1. découvre les VMs gérées (liste explicite OU toutes les VMs taguées omega) ;
#   2. rend le profil CONFORME au démon Omega (maxcpus>1, hotplug cpu,disk,network,
#      virtio-balloon) — reconfigure + redémarre si besoin ;
#   3. DÉMARRE les VMs gérées éteintes (si autostart) ;
#   4. répare qemu-guest-agent dans l'invité (QGA) et reset les VMs bloquées.
# Aucune réparation manuelle nécessaire : l'agent maintient tout en continu.
set -euo pipefail

: "${OMEGA_QGA_WATCHDOG_VMIDS:=}"              # vide = VMs locales tagguees omega
# VMs d'INFRA (pfSense, DNS…) : gardées ALLUMÉES uniquement. AUCUNE reconfiguration
# (pas de ensure_conformant/cloud-init/QGA-repair) — ces VMs ne sont PAS des invités
# omega Debian ; les toucher (réécrire vCPU/balloon/description omega_*) les casserait.
: "${OMEGA_QGA_WATCHDOG_INFRA_VMIDS:=}"        # liste VMID infra : autostart-only
: "${OMEGA_QGA_WATCHDOG_ROOT_PASSWORD:=root}"
: "${OMEGA_QGA_WATCHDOG_FAILURE_THRESHOLD:=3}"
: "${OMEGA_QGA_WATCHDOG_RESET_STUCK:=0}"       # 1 = reset VM apres seuil si aucune IP/SSH
: "${OMEGA_QGA_WATCHDOG_LOG:=/var/log/omega/qga-watchdog.log}"
: "${OMEGA_QGA_WATCHDOG_STATE_DIR:=/var/lib/omega/qga-watchdog}"
: "${OMEGA_QGA_WATCHDOG_SSH_USER:=root}"
# Conformité profil Omega (vCPU hotplug + balloon).
: "${OMEGA_QGA_WATCHDOG_ENSURE_CONFORMANT:=1}" # 1 = corriger le profil non conforme
: "${OMEGA_QGA_WATCHDOG_VCPU_MAX:=4}"          # max vCPU hotpluggable visé lors d'une réparation
: "${OMEGA_QGA_WATCHDOG_BALLOON_MIN:=512}"     # balloon (RAM mini) MiB visé si absent
# Disque élastique : quand l'invité atteint le seuil, on agrandit scsi0 vers
# omega_disk_max_gib. À chaque déclenchement on donne la MOITIÉ du reste jusqu'au max ;
# quand il reste ≤ TAIL_GIB pour atteindre le max, on donne tout le reste (→ taille demandée).
: "${OMEGA_QGA_WATCHDOG_DISK_AUTOGROW:=1}"
: "${OMEGA_QGA_WATCHDOG_DISK_THRESHOLD_PCT:=85}"
: "${OMEGA_QGA_WATCHDOG_DISK_TAIL_GIB:=1}"
# Modèle CPU visé : kvm64 (ancien défaut) n'expose pas x86-64-v2 → images modernes KO.
# Si une VM est en kvm64/absent, on corrige la config (prend effet au prochain reboot ;
# le watchdog ne reboote PAS de lui-même). Mettre vide pour désactiver cette correction.
: "${OMEGA_QGA_WATCHDOG_CPU_TYPE:=x86-64-v2-AES}"
# Délai de grâce avant de (re)démarrer une VM trouvée éteinte : évite de perturber
# un test qui arrête volontairement une VM quelques secondes (stop+reconfigure+start).
# On ne démarre qu'une VM éteinte depuis AU MOINS ce délai (observée stoppée 2 ticks).
: "${OMEGA_QGA_WATCHDOG_STOPPED_GRACE_SECS:=150}"
# Démarrage auto des VMs gérées éteintes. Défaut 1 quand une liste VMIDS explicite
# est fournie (= VMs sélectionnées pour les tests), 0 en mode auto-découverte
# (évite d'allumer toute la flotte omega-taguée).
if [[ -n "${OMEGA_QGA_WATCHDOG_VMIDS}" ]]; then
    : "${OMEGA_QGA_WATCHDOG_AUTOSTART:=1}"
else
    : "${OMEGA_QGA_WATCHDOG_AUTOSTART:=0}"
fi

mkdir -p "$(dirname "$OMEGA_QGA_WATCHDOG_LOG")" "$OMEGA_QGA_WATCHDOG_STATE_DIR"
log() { printf '%s %s\n' "$(date -Is)" "$*" | tee -a "$OMEGA_QGA_WATCHDOG_LOG"; }

have() { command -v "$1" >/dev/null 2>&1; }

vmids_to_scan() {
    if [[ -n "$OMEGA_QGA_WATCHDOG_VMIDS" ]]; then
        tr ',' '\n' <<<"$OMEGA_QGA_WATCHDOG_VMIDS" | awk 'NF'
        return
    fi
    qm list 2>/dev/null | awk 'NR>1 {print $1}' | while read -r vmid; do
        cfg="$(qm config "$vmid" 2>/dev/null || true)"
        printf '%s\n' "$cfg" | grep -q '^template: 1' && continue
        tags="$(printf '%s\n' "$cfg" | sed -n 's/^tags: //p')"
        desc="$(printf '%s\n' "$cfg" | sed -n 's/^description: //p')"
        if printf '%s\n%s\n' "$tags" "$desc" | grep -Eq '(^|[;, ])omega([;, ]|$)|omega_'; then
            echo "$vmid"
        fi
    done
}

qga_ok() {
    local vmid="$1"
    qm guest cmd "$vmid" ping >/dev/null 2>&1 || qm agent "$vmid" ping >/dev/null 2>&1
}

vm_status() {
    qm status "$1" 2>/dev/null | awk '{print $2}'
}

# La VM est-elle hébergée sur CE nœud ? (qm start/status/set n'agissent qu'en local)
vm_is_local() {
    qm list 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "$1"
}

vm_mac() {
    qm config "$1" 2>/dev/null | sed -n 's/^net0: virtio=\([^,]*\).*/\1/p' | head -1 | tr 'A-F' 'a-f'
}

vm_ip_from_neigh() {
    local mac="$1"
    [[ -n "$mac" ]] || return 1
    ip neigh | awk -v mac="$mac" 'tolower($0) ~ mac && $1 !~ /^fe80/ && $1 !~ /^169\.254\./ {print $1; exit}'
}

failure_file() { printf '%s/%s.failures\n' "$OMEGA_QGA_WATCHDOG_STATE_DIR" "$1"; }

failure_count() {
    local f; f="$(failure_file "$1")"
    [[ -s "$f" ]] && cat "$f" || echo 0
}

set_failure_count() {
    printf '%s\n' "$2" >"$(failure_file "$1")"
}

clear_failure() {
    rm -f "$(failure_file "$1")"
}

# Le snippet (volid storage:snippets/fichier) est-il présent sur CE nœud ?
snippet_present_local() {
    local volid="$1" storage file
    storage="${volid%%:*}"
    file="${volid##*/}"
    [[ -n "$file" ]] || return 1
    # Chemins snippets connus : 'local' → /var/lib/vz/snippets ; autres → /mnt/pve/<st>/snippets
    [[ -f "/var/lib/vz/snippets/${file}" ]] && return 0
    [[ -f "/mnt/pve/${storage}/snippets/${file}" ]] && return 0
    return 1
}

# Garantit que la VM peut DÉMARRER sur ce nœud : un cicustom qui référence un snippet
# absent localement (snippet local non partagé, après migration de nœud) bloque le start.
# On retire alors le cicustom (le bootstrap cloud-init est appliqué une seule fois ;
# les VMs Omega tournent sans cicustom après provisioning — cf. 3009/3010).
ensure_bootable() {
    local vmid="$1" cfg cic ref volid missing=0
    cfg="$(qm config "$vmid" 2>/dev/null || true)"
    cic="$(printf '%s\n' "$cfg" | sed -n 's/^cicustom: //p' | head -1)"
    [[ -n "$cic" ]] || return 0
    # cicustom = "user=local:snippets/a.yaml,meta=local:snippets/b.yaml,..."
    IFS=',' read -ra _refs <<< "$cic"
    for ref in "${_refs[@]}"; do
        volid="${ref#*=}"                       # local:snippets/xxx.yaml
        [[ "$volid" == *:snippets/* ]] || continue
        snippet_present_local "$volid" || { missing=1; break; }
    done
    if [[ "$missing" == 1 ]]; then
        qm set "$vmid" --delete cicustom >/dev/null 2>&1 \
            && log "vm=$vmid action=strip-cicustom reason=snippet_absent_local (VM rendue démarrable)"
    fi
}

# Garantit le RÉSEAU : une VM avec une IP statique cloud-init (ipconfig0) doit avoir
# son disque cloud-init (scsi1) — sinon DataSourceNone → pas d'IP/route dans l'invité.
# Recrée le disque manquant (config seule ; l'IP s'applique au prochain boot).
ensure_cloudinit_drive() {
    local vmid="$1" cfg ipcfg scsi1 storage
    cfg="$(qm config "$vmid" 2>/dev/null || true)"
    ipcfg="$(printf '%s\n' "$cfg" | sed -n 's/^ipconfig0: //p' | head -1)"
    [[ -n "$ipcfg" ]] || return 0                      # pas d'IP cloud-init → rien à garantir
    scsi1="$(printf '%s\n' "$cfg" | sed -n 's/^scsi1: //p' | head -1)"
    # Présent et non vide (pas "none,...") → OK (if/return = set -e safe)
    if [[ -n "$scsi1" && "$scsi1" != none* ]]; then return 0; fi
    # Choisir le stockage du disque système (même pool que scsi0), défaut stockage.ceph
    storage="$(printf '%s\n' "$cfg" | sed -n 's/^scsi0: //p' | head -1 | sed 's/:.*//')"
    storage="${storage:-${OMEGA_VM_STORAGE:-stockage.ceph}}"
    # Si le volume cloud-init existe déjà (config 'none' mais disque orphelin), le
    # ré-attacher ; sinon le créer via le mot-clé 'cloudinit'.
    local spec="${storage}:cloudinit"
    if pvesm list "$storage" 2>/dev/null | grep -q "vm-${vmid}-cloudinit"; then
        spec="${storage}:vm-${vmid}-cloudinit,media=cdrom"
    fi
    qm set "$vmid" --scsi1 "$spec" >/dev/null 2>&1 || true
    qm cloudinit update "$vmid" >/dev/null 2>&1 || true
    # Vérifier le résultat réel (qm set peut renvoyer non-zéro tout en attachant).
    local now; now="$(qm config "$vmid" 2>/dev/null | sed -n 's/^scsi1: //p' | head -1)"
    if [[ -n "$now" && "$now" != none* ]]; then
        log "vm=$vmid action=recreate-cloudinit-drive ok=$now (IP appliquée au prochain boot)"
    else
        log "vm=$vmid action=recreate-cloudinit-drive-FAILED spec=$spec"
    fi
}

stopped_file() { printf '%s/%s.stopped_since\n' "$OMEGA_QGA_WATCHDOG_STATE_DIR" "$1"; }

# Depuis combien de secondes la VM est-elle vue éteinte ? (0 si premier constat).
stopped_for_secs() {
    local f; f="$(stopped_file "$1")"
    if [[ -s "$f" ]]; then
        echo $(( $(date +%s) - $(cat "$f" 2>/dev/null || echo "$(date +%s)") ))
    else
        date +%s > "$f"   # marque le premier constat d'arrêt
        echo 0
    fi
}
clear_stopped() { rm -f "$(stopped_file "$1")"; }

# Rend le profil de la VM conforme au démon Omega : maxcpus>1, vcpus boot=1,
# hotplug cpu,disk,network, virtio-balloon actif. Reconfigure + (re)démarre si besoin.
# Retourne 0 si déjà conforme (aucun changement), 10 si elle a été reconfigurée.
ensure_conformant() {
    local vmid="$1"
    [[ "$OMEGA_QGA_WATCHDOG_ENSURE_CONFORMANT" == "1" ]] || return 0
    local cfg cores sockets vcpus hotplug balloon memory smp smp_max max_vcpus desired status desc description omega_min cpu_model
    cfg="$(qm config "$vmid" 2>/dev/null || true)"
    [[ -n "$cfg" ]] || return 0
    cpu_model="$(printf '%s\n' "$cfg" | awk '/^cpu:/{print $2}' | head -1)"   # vide = kvm64 (défaut Proxmox)
    cores="$(printf '%s\n' "$cfg" | awk '/^cores:/{print $2}' | head -1)";       cores="${cores:-1}"
    sockets="$(printf '%s\n' "$cfg" | awk '/^sockets:/{print $2}' | head -1)";   sockets="${sockets:-1}"
    vcpus="$(printf '%s\n' "$cfg" | awk '/^vcpus:/{print $2}' | head -1)";       vcpus="${vcpus:-0}"
    hotplug="$(printf '%s\n' "$cfg" | awk '/^hotplug:/{print $2}' | head -1)"
    balloon="$(printf '%s\n' "$cfg" | awk '/^balloon:/{print $2}' | head -1)";   balloon="${balloon:-0}"
    memory="$(printf '%s\n' "$cfg" | awk '/^memory:/{print $2}' | head -1)";     memory="${memory:-2048}"
    description="$(printf '%s\n' "$cfg" | awk -F': ' '$1=="description"{print $2; exit}')"
    # Plancher DÉCLARATIF : omega_min_vcpus de la description fait autorité (défaut 1),
    # borné au plafond topologique cores×sockets. C'est aussi le nb de vCPU au boot.
    omega_min="$(printf '%s\n' "$description" | grep -o 'omega_min_vcpus=[0-9]*' | head -1 | cut -d= -f2)"
    [[ "$omega_min" =~ ^[0-9]+$ && "$omega_min" -ge 1 ]] || omega_min=1
    (( omega_min > cores * sockets )) && omega_min=$(( cores * sockets ))
    max_vcpus=$(( cores * sockets ))
    smp="$(qm showcmd "$vmid" --pretty 2>/dev/null | grep -- '-smp' | head -1 || true)"
    smp_max="$(printf '%s\n' "$smp" | sed -n 's/.*maxcpus=\([0-9][0-9]*\).*/\1/p' | head -1)"
    # IMPORTANT : si le QEMU EN COURS expose déjà maxcpus>cores×sockets (hotplug actif,
    # ou test vCPU en train de manipuler la config), c'est la valeur runtime qui fait foi.
    # Sans ça, on reconfigurerait à tort une VM conforme EN PLEIN TEST (race destructrice).
    if [[ "$smp_max" =~ ^[0-9]+$ && "$smp_max" -gt "$max_vcpus" ]]; then
        max_vcpus="$smp_max"
    fi

    local cpu_ok=0 balloon_ok=0 vcpus_ok=0 cpumodel_ok=0
    # Conforme si le QEMU en cours a maxcpus>1 et hotplug cpu. (VM arrêtée : pas de smp →
    # on retombe sur cores×sockets via max_vcpus, ce qui est correct.)
    [[ "$max_vcpus" -gt 1 && ",${hotplug:-}," == *,cpu,* ]] && cpu_ok=1
    # Modèle CPU : kvm64 (ou absent → kvm64) n'expose pas x86-64-v2 (kafka & co échouent).
    # On ne corrige QUE kvm64/absent ; tout autre choix explicite (host, Skylake…) est respecté.
    # Si la correction est désactivée (CPU_TYPE vide), on considère conforme.
    if [[ -z "$OMEGA_QGA_WATCHDOG_CPU_TYPE" ]] || { [[ -n "$cpu_model" && "$cpu_model" != "kvm64" ]]; }; then
        cpumodel_ok=1
    fi
    # Élasticité : la VM doit BOOTER avec exactement omega_min_vcpus vCPU en ligne
    # (le champ Proxmox `vcpus:` = plancher lu par le daemon). vcpus=cores (legacy)
    # fige min=max → AUCUN downscale. On exige donc `vcpus == omega_min`.
    [[ "$vcpus" == "$omega_min" ]] && vcpus_ok=1
    # balloon=0 ou absent → pas de virtio-balloon → 'info balloon' échoue. On veut >0.
    [[ "$balloon" =~ ^[0-9]+$ && "$balloon" -gt 0 ]] && balloon_ok=1

    # Métadonnées de description exigées par le test de conformité 30 (description déjà lue).
    local disk_max gpu_vram meta_ok=0
    disk_max="$(printf '%s\n' "$description" | grep -o 'omega_disk_max_gib=[0-9]*' | head -1 | cut -d= -f2)"
    gpu_vram="$(printf '%s\n' "$description" | grep -o 'omega_gpu_vram_mib=[0-9]*' | head -1 | cut -d= -f2)"
    [[ -n "$disk_max" && -n "$gpu_vram" \
       && "$description" == *omega_min_vcpus=* && "$description" == *omega_max_vcpus=* ]] && meta_ok=1

    # Tout bon (CPU hotplug + modèle CPU + vcpus boot + balloon + métadonnées) → rien à faire.
    if [[ "$cpu_ok" == 1 && "$cpumodel_ok" == 1 && "$vcpus_ok" == 1 && "$balloon_ok" == 1 && "$meta_ok" == 1 ]]; then
        return 0
    fi

    desired="$OMEGA_QGA_WATCHDOG_VCPU_MAX"; [[ "$desired" =~ ^[0-9]+$ && "$desired" -gt 1 ]] || desired=4
    [[ "$max_vcpus" -gt "$desired" ]] && desired="$max_vcpus"
    local b="$balloon"; [[ "$balloon_ok" == 1 ]] || b="$OMEGA_QGA_WATCHDOG_BALLOON_MIN"
    disk_max="${disk_max:-20}"; gpu_vram="${gpu_vram:-0}"
    desc="omega_min_vcpus=${omega_min} omega_max_vcpus=${desired} omega_memory_min_mib=${b} omega_memory_max_mib=${memory} omega_disk_max_gib=${disk_max} omega_gpu_vram_mib=${gpu_vram}"

    # CAS LÉGER : CPU + balloon conformes ; seuls vcpus(boot) et/ou la description
    # divergent. Correction EN PLACE sans redémarrage (vcpus=omega_min en live +
    # métadonnées) → ne perturbe ni la charge ni les tests. Le daemon re-synchronise min.
    if [[ "$cpu_ok" == 1 && "$balloon_ok" == 1 ]]; then
        local fixed=()
        if [[ "$vcpus_ok" != 1 ]]; then
            qm set "$vmid" --vcpus "$omega_min" >/dev/null 2>&1 && fixed+=("vcpus=${omega_min}")
        fi
        if [[ "$cpumodel_ok" != 1 ]]; then
            # Corrige la config (prend effet au PROCHAIN reboot — on ne reboote pas ici).
            qm set "$vmid" --cpu "$OMEGA_QGA_WATCHDOG_CPU_TYPE" >/dev/null 2>&1 \
                && fixed+=("cpu=${OMEGA_QGA_WATCHDOG_CPU_TYPE}@next-reboot")
        fi
        if [[ "$meta_ok" != 1 ]]; then
            qm set "$vmid" --description "$desc" >/dev/null 2>&1 && fixed+=("metadata")
        fi
        [[ ${#fixed[@]} -gt 0 ]] && log "vm=$vmid action=fix-light (${fixed[*]} — sans redémarrage)"
        return 0
    fi

    log "vm=$vmid conformite=KO (max_vcpus=$max_vcpus hotplug='${hotplug:-}' smp_max='${smp_max:-?}' balloon=$balloon) action=reconfigure cores=$desired balloon=$b"
    status="$(vm_status "$vmid" || true)"
    [[ "$status" == "running" ]] && { qm stop "$vmid" >/dev/null 2>&1 || qm stop "$vmid" --skiplock 1 >/dev/null 2>&1 || true; sleep 3; }
    local cpu_arg=(); [[ -n "$OMEGA_QGA_WATCHDOG_CPU_TYPE" && "$cpumodel_ok" != 1 ]] && cpu_arg=(--cpu "$OMEGA_QGA_WATCHDOG_CPU_TYPE")
    qm set "$vmid" \
        --cores "$desired" --sockets 1 --vcpus "$omega_min" \
        --hotplug cpu,disk,network --numa 0 \
        --balloon "$b" \
        --agent enabled=1 \
        "${cpu_arg[@]}" \
        --description "$desc" >/dev/null 2>&1 || { log "vm=$vmid action=reconfigure-failed"; return 0; }
    return 10
}

install_guest_repair() {
    local vmid="$1" ip="$2" pass_q
    have sshpass || { log "vm=$vmid qga=bad action=skip reason=sshpass_absent"; return 1; }
    printf -v pass_q '%q' "$OMEGA_QGA_WATCHDOG_ROOT_PASSWORD"
    sshpass -p "$OMEGA_QGA_WATCHDOG_ROOT_PASSWORD" ssh \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=8 \
        "${OMEGA_QGA_WATCHDOG_SSH_USER}@${ip}" 'bash -s' <<'GUEST'
set -e
export DEBIAN_FRONTEND=noninteractive
if command -v apt-get >/dev/null 2>&1; then
    apt-get update
    apt-get install -y qemu-guest-agent openssh-server
fi
install -d -m 0755 /usr/local/sbin /etc/systemd/system /etc/ssh/sshd_config.d
cat >/etc/ssh/sshd_config.d/99-omega-root-login.conf <<'EOF'
PermitRootLogin yes
PasswordAuthentication yes
KbdInteractiveAuthentication yes
EOF
cat >/usr/local/sbin/omega-qga-ensure <<'EOF'
#!/bin/sh
LOG=/var/log/omega-qga-ensure.log
{
echo "=== omega-qga-ensure $(date) ==="
if ! command -v qemu-ga >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update 2>/dev/null && apt-get install -y qemu-guest-agent 2>/dev/null || true
fi
systemctl unmask qemu-guest-agent.service qemu-guest-agent.socket 2>/dev/null || true
systemctl enable qemu-guest-agent.service 2>/dev/null || true
systemctl enable qemu-guest-agent.socket 2>/dev/null || true
i=0
while [ "$i" -lt 30 ]; do
    if [ -e /dev/virtio-ports/org.qemu.guest_agent.0 ]; then
        systemctl restart qemu-guest-agent.service 2>/dev/null || systemctl start qemu-guest-agent.service 2>/dev/null || true
        systemctl start qemu-guest-agent.socket 2>/dev/null || true
        break
    fi
    i=$((i+1))
    sleep 2
done
systemctl is-active qemu-guest-agent 2>/dev/null && echo "qemu-guest-agent ACTIF" || echo "qemu-guest-agent INACTIF"
} >>"$LOG" 2>&1
EOF
chmod 0755 /usr/local/sbin/omega-qga-ensure
cat >/etc/systemd/system/omega-qga-ensure.service <<'EOF'
[Unit]
Description=Omega - garantit qemu-guest-agent actif a chaque boot
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/omega-qga-ensure
RemainAfterExit=no
TimeoutStartSec=180

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now ssh 2>/dev/null || systemctl restart ssh 2>/dev/null || systemctl start ssh 2>/dev/null || true
systemctl unmask qemu-guest-agent.service qemu-guest-agent.socket 2>/dev/null || true
systemctl enable qemu-guest-agent.service qemu-guest-agent.socket 2>/dev/null || true
systemctl restart qemu-guest-agent.service 2>/dev/null || systemctl start qemu-guest-agent.service 2>/dev/null || true
systemctl enable --now omega-qga-ensure.service
systemctl is-active qemu-guest-agent
GUEST
}

scan_one() {
    local vmid="$1" status cfg agent mac ip failures
    # N'agir que sur les VMs locales (qm n'opère qu'en local ; en cluster une VMID
    # de la liste peut être hébergée par un autre nœud, dont le watchdog s'occupera).
    vm_is_local "$vmid" || return 0
    status="$(vm_status "$vmid" || true)"

    # 0. Démarrabilité + réseau : réparer cicustom dangling et disque cloud-init manquant.
    ensure_bootable "$vmid"
    ensure_cloudinit_drive "$vmid"

    if [[ "$status" == "running" ]]; then
        # VM en cours : seulement vérifier la conformité. Le fix smp_max garantit
        # qu'une VM saine (maxcpus>1, hotplug cpu, balloon>0) N'EST PAS touchée,
        # donc on ne perturbe jamais un test qui tourne dessus.
        clear_stopped "$vmid"
        ensure_conformant "$vmid" && true || true
        status="$(vm_status "$vmid" || true)"
    else
        # VM éteinte. Ne RIEN faire pendant le délai de grâce : un test peut l'avoir
        # arrêtée volontairement (stop+reconfigure+start en quelques secondes).
        [[ "$OMEGA_QGA_WATCHDOG_AUTOSTART" == "1" ]] || { clear_failure "$vmid"; return 0; }
        local down; down="$(stopped_for_secs "$vmid")"
        if [[ "$down" -lt "$OMEGA_QGA_WATCHDOG_STOPPED_GRACE_SECS" ]]; then
            log "vm=$vmid status=$status down=${down}s action=wait grace=${OMEGA_QGA_WATCHDOG_STOPPED_GRACE_SECS}s"
            return 0
        fi
        # Éteinte depuis assez longtemps → la rendre conforme puis la démarrer.
        ensure_conformant "$vmid" && true || true
        log "vm=$vmid status=$status down=${down}s action=start"
        qm start "$vmid" >/dev/null 2>&1 || log "vm=$vmid action=start-failed"
        sleep 5
        status="$(vm_status "$vmid" || true)"
    fi
    [[ "$status" == "running" ]] || { return 0; }
    clear_stopped "$vmid"

    cfg="$(qm config "$vmid" 2>/dev/null || true)"
    agent="$(printf '%s\n' "$cfg" | sed -n 's/^agent: //p')"
    if [[ "$agent" != *enabled=1* && "$agent" != "1" ]]; then
        qm set "$vmid" --agent enabled=1 >/dev/null 2>&1 || true
        log "vm=$vmid action=enable-proxmox-agent"
    fi

    if qga_ok "$vmid"; then
        clear_failure "$vmid"
        log "vm=$vmid qga=ok"
        return 0
    fi

    failures="$(( $(failure_count "$vmid") + 1 ))"
    set_failure_count "$vmid" "$failures"
    mac="$(vm_mac "$vmid")"
    ip="$(vm_ip_from_neigh "$mac" || true)"
    log "vm=$vmid qga=bad failures=$failures ip=${ip:-none} action=repair-attempt"

    if [[ -n "$ip" ]] && install_guest_repair "$vmid" "$ip"; then
        sleep 3
        if qga_ok "$vmid"; then
            clear_failure "$vmid"
            log "vm=$vmid qga=repaired ip=$ip"
            return 0
        fi
        log "vm=$vmid qga=still-bad-after-repair ip=$ip"
    fi

    if [[ "$OMEGA_QGA_WATCHDOG_RESET_STUCK" == "1" && "$failures" -ge "$OMEGA_QGA_WATCHDOG_FAILURE_THRESHOLD" ]]; then
        log "vm=$vmid action=reset reason=qga_stuck failures=$failures"
        qm reset "$vmid" >/dev/null 2>&1 || qm reboot "$vmid" >/dev/null 2>&1 || true
        set_failure_count "$vmid" 0
    fi
}

# VM d'INFRA : on la garde ALLUMÉE, point. Pas de conformité, pas de cloud-init,
# pas de réparation QGA (ce ne sont pas des invités omega Debian → on n'y touche pas
# la config). Sert pour pfSense, DNS, etc. dont dépend tout le réseau OMEGA.
scan_infra_one() {
    local vmid="$1" status down
    vm_is_local "$vmid" || return 0
    status="$(vm_status "$vmid" || true)"
    if [[ "$status" == "running" ]]; then
        clear_stopped "$vmid"
        return 0
    fi
    # Éteinte : grâce pour ne pas contrarier un arrêt volontaire (maintenance/migration).
    down="$(stopped_for_secs "$vmid")"
    if [[ "$down" -lt "$OMEGA_QGA_WATCHDOG_STOPPED_GRACE_SECS" ]]; then
        log "infra vm=$vmid status=$status down=${down}s action=wait grace=${OMEGA_QGA_WATCHDOG_STOPPED_GRACE_SECS}s"
        return 0
    fi
    log "infra vm=$vmid status=$status down=${down}s action=start (autostart-only, config intacte)"
    qm start "$vmid" >/dev/null 2>&1 || log "infra vm=$vmid action=start-failed"
    sleep 5
    [[ "$(vm_status "$vmid" || true)" == "running" ]] && clear_stopped "$vmid"
}

# Extrait le champ out-data d'un `qm guest exec` (JSON) — python3 présent sur Proxmox.
guest_exec_out() {  # <vmid> <cmd...>
    local vmid="$1"; shift
    qm guest exec "$vmid" --timeout 25 -- "$@" 2>/dev/null | python3 -c 'import sys,json
try:
    d=json.load(sys.stdin); sys.stdout.write((d.get("out-data") or "").strip())
except Exception: pass' 2>/dev/null
}

# Convertit une taille Proxmox ("size=20G", "3072M"…) en Gio entier (plancher).
_size_to_gib() {  # <NNN[KMGT]>
    local s="$1" num unit
    num="${s%[KMGTkmgt]}"; unit="${s: -1}"
    case "$unit" in
        T|t) awk -v n="$num" 'BEGIN{printf "%d", n*1024}' ;;
        G|g) awk -v n="$num" 'BEGIN{printf "%d", n}' ;;
        M|m) awk -v n="$num" 'BEGIN{printf "%d", n/1024}' ;;
        K|k) awk -v n="$num" 'BEGIN{printf "%d", n/1024/1024}' ;;
        *)   awk -v n="$num" 'BEGIN{printf "%d", n/1073741824}' ;;  # octets
    esac
}

# Disque élastique : si l'invité dépasse le seuil, agrandit scsi0 vers omega_disk_max_gib.
# Règle : on donne la MOITIÉ du reste jusqu'au max ; s'il reste ≤ TAIL_GIB, on donne tout.
# À chaud (qm resize + growpart + resize2fs/xfs_growfs). Plafonné à la taille demandée
# à la création (omega_disk_max_gib) — jamais au-delà, jamais de réduction.
ensure_disk_headroom() {
    local vmid="$1"
    [[ "$OMEGA_QGA_WATCHDOG_DISK_AUTOGROW" == "1" ]] || return 0
    vm_is_local "$vmid" || return 0
    [[ "$(vm_status "$vmid" || true)" == "running" ]] || return 0
    local cfg disk_line cur_size cur_gib max_gib
    cfg="$(qm config "$vmid" 2>/dev/null || true)"
    [[ -n "$cfg" ]] || return 0
    disk_line="$(printf '%s\n' "$cfg" | sed -n 's/^scsi0: //p')"   # disque racine omega = scsi0
    cur_size="$(printf '%s' "$disk_line" | grep -oE 'size=[0-9]+[KMGT]?' | head -1 | cut -d= -f2)"
    [[ -n "$cur_size" ]] || return 0
    cur_gib="$(_size_to_gib "$cur_size")"
    max_gib="$(printf '%s\n' "$cfg" | grep -o 'omega_disk_max_gib=[0-9]*' | head -1 | cut -d= -f2)"
    [[ "$max_gib" =~ ^[0-9]+$ && "$max_gib" -gt 0 ]] || return 0
    [[ "$cur_gib" -lt "$max_gib" ]] || return 0   # déjà à la taille max demandée
    # usage % de la racine, lu DANS l'invité
    local use_pct
    use_pct="$(guest_exec_out "$vmid" df -P / | awk 'NR==2{gsub("%","",$5); print $5}')"
    [[ "$use_pct" =~ ^[0-9]+$ ]] || return 0
    [[ "$use_pct" -ge "$OMEGA_QGA_WATCHDOG_DISK_THRESHOLD_PCT" ]] || return 0
    # calcul de la croissance
    local remaining grow new_gib tail="$OMEGA_QGA_WATCHDOG_DISK_TAIL_GIB"
    remaining=$(( max_gib - cur_gib ))
    if [[ "$remaining" -le "$tail" ]]; then
        grow="$remaining"                 # reste ≤ queue → on donne tout (→ taille demandée)
    else
        grow=$(( (remaining + 1) / 2 ))   # la moitié du restant (arrondi supérieur)
    fi
    [[ "$grow" -ge 1 ]] || return 0
    new_gib=$(( cur_gib + grow ))
    log "vm=$vmid disk use=${use_pct}% cur=${cur_gib}G max=${max_gib}G reste=${remaining}G action=grow→${new_gib}G"
    if ! qm resize "$vmid" scsi0 "${new_gib}G" >/dev/null 2>&1; then
        log "vm=$vmid disk action=resize-failed"; return 0
    fi
    # Étend partition + système de fichiers en ligne (ext4 ou xfs).
    guest_exec_out "$vmid" sh -c \
        'echo 1 > /sys/class/block/sda/device/rescan 2>/dev/null; growpart /dev/sda 1 >/dev/null 2>&1; resize2fs /dev/sda1 >/dev/null 2>&1 || xfs_growfs / >/dev/null 2>&1; true' >/dev/null 2>&1
    local new_pct
    new_pct="$(guest_exec_out "$vmid" df -P / | awk 'NR==2{gsub("%","",$5); print $5}')"
    log "vm=$vmid disk grown→${new_gib}G new_use=${new_pct:-?}%"
}

main() {
    have qm || { log "qm absent; watchdog ignored"; exit 0; }
    # VMs d'infra (autostart-only) — traitées en premier : tout le réseau OMEGA en dépend.
    local infra_vmid
    if [[ -n "$OMEGA_QGA_WATCHDOG_INFRA_VMIDS" ]]; then
        for infra_vmid in $(tr ',' ' ' <<<"$OMEGA_QGA_WATCHDOG_INFRA_VMIDS"); do
            [[ "$infra_vmid" =~ ^[0-9]+$ ]] || continue
            scan_infra_one "$infra_vmid" || log "infra vm=$infra_vmid action=scan-error"
        done
    fi
    mapfile -t vmids < <(vmids_to_scan)
    if [[ "${#vmids[@]}" -eq 0 ]]; then
        [[ -n "$OMEGA_QGA_WATCHDOG_INFRA_VMIDS" ]] || log "no omega vm local"
        exit 0
    fi
    for vmid in "${vmids[@]}"; do
        [[ "$vmid" =~ ^[0-9]+$ ]] || continue
        # Une VMID listée à la fois en infra et en omega : on respecte l'infra (déjà gérée).
        [[ ",${OMEGA_QGA_WATCHDOG_INFRA_VMIDS}," == *",${vmid},"* ]] && continue
        scan_one "$vmid" || log "vm=$vmid action=scan-error"
        ensure_disk_headroom "$vmid" || log "vm=$vmid disk action=error"
    done
}

main "$@"
