#!/usr/bin/perl
# proxmox_hook.pl — Hookscript Proxmox V3 pour omega-remote-paging
#
# Proxmox appelle ce script à chaque phase du cycle de vie d'une VM.
# Ce hook notifie le omega-daemon local qu'une VM démarre ou s'arrête.
#
# INSTALLATION :
#   1. Copier dans le répertoire snippets du stockage local Proxmox :
#      cp scripts/proxmox_hook.pl /var/lib/vz/snippets/omega-agent-hook.pl
#      chmod +x /var/lib/vz/snippets/omega-agent-hook.pl
#
#   2. Configurer la VM (via qm ou l'UI Proxmox) :
#      qm set {VMID} --hookscript local:snippets/omega-agent-hook.pl
#
#   3. Le omega-daemon doit tourner sur le nœud avec le canal de contrôle actif
#      sur le port 9300 (configurable via OMEGA_CONTROL_PORT).
#
# PHASES Proxmox disponibles :
#   pre-start   : avant le démarrage (QEMU pas encore lancé)
#   post-start  : après le démarrage (QEMU en cours, VMID connu)
#   pre-stop    : avant l'arrêt (propre ou SIGTERM)
#   post-stop   : après l'arrêt

use strict;
use warnings;

# Paramètres Proxmox
my ($vmid, $phase) = @ARGV;

# Configuration omega-daemon
my $OMEGA_CONTROL_HOST  = $ENV{OMEGA_CONTROL_HOST}  // "127.0.0.1";
my $OMEGA_CONTROL_PORT  = $ENV{OMEGA_CONTROL_PORT}  // "9300";
my $OMEGA_LOG_FILE      = $ENV{OMEGA_LOG_FILE}       // "/var/log/omega-hook.log";

sub log_msg {
    my ($level, $msg) = @_;
    my $ts = `date -u +"%Y-%m-%dT%H:%M:%SZ"`;
    chomp $ts;
    my $line = "[$ts] [$level] vmid=$vmid phase=$phase $msg\n";
    print STDERR $line;
    if (open my $fh, '>>', $OMEGA_LOG_FILE) {
        print $fh $line;
        close $fh;
    }
}

sub curl_post {
    my ($path, $body) = @_;
    my $url = "http://${OMEGA_CONTROL_HOST}:${OMEGA_CONTROL_PORT}${path}";
    my $cmd = qq(curl -s -f -X POST "$url" )
            . qq(-H 'Content-Type: application/json' )
            . qq(-d '$body' )
            . qq(--connect-timeout 2 --max-time 5 2>&1);
    my $result = `$cmd`;
    my $rc     = $? >> 8;
    return ($rc, $result);
}

sub curl_delete {
    my ($path) = @_;
    my $url = "http://${OMEGA_CONTROL_HOST}:${OMEGA_CONTROL_PORT}${path}";
    my $cmd = qq(curl -s -f -X DELETE "$url" --connect-timeout 2 --max-time 5 2>&1);
    my $result = `$cmd`;
    my $rc     = $? >> 8;
    return ($rc, $result);
}

# ─── Dispatch selon la phase ──────────────────────────────────────────────────

if ($phase eq 'post-start') {
    # La VM vient de démarrer — notifier omega-daemon pour commencer le monitoring
    log_msg("INFO", "VM démarrée — notification omega-daemon");

    # Configurer le polling balloon stats (toutes les 15s)
    my ($rc, $out) = curl_post(
        "/control/evict/$vmid",
        "{\"count\": 0}"  # count=0 → démarrer le monitoring sans éviction forcée
    );

    if ($rc == 0) {
        log_msg("INFO", "omega-daemon notifié (post-start ok)");
    } else {
        log_msg("WARN", "omega-daemon non joignable (port 9300) — monitoring désactivé : $out");
    }

    # Passer l'env OMEGA_VM_ID=vmid au processus agent s'il tourne séparément
    # (pour les déploiements où node-a-agent tourne à côté de omega-daemon)
    if (-x "/opt/omega-remote-paging/bin/node-a-agent") {
        my $peers = $ENV{OMEGA_PEERS} // "";
        my $stores = $ENV{OMEGA_STORES} // "127.0.0.1:9100,127.0.0.1:9101";
        log_msg("INFO", "démarrage node-a-agent pour vmid=$vmid (stores=$stores)");

        # Lance l'agent en mode daemon en arrière-plan
        my $cmd = sprintf(
            'OMEGA_VM_ID=%d /opt/omega-remote-paging/bin/node-a-agent '
          . '--vm-id %d --stores "%s" --mode daemon '
          . '>> /var/log/omega-agent-%d.log 2>&1 &',
            $vmid, $vmid, $stores, $vmid
        );
        system($cmd);
    }

} elsif ($phase eq 'pre-stop') {
    # La VM va s'arrêter — sauvegarder l'état avant de couper
    log_msg("INFO", "VM en arrêt — signalement omega-daemon");

    # Optionnel : on pourrait rapatrier toutes les pages distantes avant l'arrêt
    # pour éviter de les perdre. En V4 : on le signale juste.
    my ($rc, $out) = curl_post(
        "/control/evict/$vmid",
        "{\"count\": 0, \"vm_id\": $vmid}"
    );

    if ($rc != 0) {
        log_msg("WARN", "impossible de notifier omega-daemon (pre-stop) : $out");
    }

} elsif ($phase eq 'post-stop') {
    # La VM est arrêtée — nettoyer les pages distantes orphelines
    log_msg("INFO", "VM arrêtée — nettoyage des pages distantes");

    my ($rc, $out) = curl_delete("/control/pages/$vmid");

    if ($rc == 0) {
        log_msg("INFO", "pages distantes supprimées pour vmid=$vmid");
    } else {
        log_msg("WARN", "nettoyage pages échoué : $out");
    }

} elsif ($phase eq 'pre-start') {
    # Avant démarrage : vérifier que le omega-daemon est disponible
    log_msg("INFO", "pré-démarrage — vérification omega-daemon");

    my $check = `curl -s -f http://${OMEGA_CONTROL_HOST}:${OMEGA_CONTROL_PORT}/control/status \
                      --connect-timeout 1 2>/dev/null`;
    if ($? == 0) {
        log_msg("INFO", "omega-daemon disponible");
    } else {
        log_msg("WARN", "omega-daemon non joignable sur ${OMEGA_CONTROL_HOST}:${OMEGA_CONTROL_PORT}");
    }

} else {
    log_msg("DEBUG", "phase '$phase' ignorée");
}

exit 0;
