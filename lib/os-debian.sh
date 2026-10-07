#!/usr/bin/env bash
# Debian: skeleton only. Nothing here is implemented on purpose, because it
# could not be tested. Every function refuses with a clear message.
#
# Differences that have to be handled before this file can do real work:
#
# - Docker repository: the URL is https://download.docker.com/linux/debian
#   and uses Debian codenames (bookworm, trixie). The availability check from
#   os-ubuntu.sh has to point at the Debian tree.
# - Docker fallback packages: the distribution package names for the Compose
#   plugin differ from Ubuntu's `docker-compose-v2`.
# - unattended-upgrades: Debian uses Origins-Pattern entries
#   (origin=Debian,codename=${distro_codename},label=Debian-Security) instead
#   of Ubuntu's Allowed-Origins list, so the "are security updates enabled"
#   check has to look at a different key.
# - Logs: there is no classic /var/log/auth.log on a default Debian 12+
#   install (journald only). fail2ban needs the systemd backend and the
#   python3-systemd package to be present.
# - SSH: verify whether ssh.socket activation is used and what the unit is
#   called, instead of assuming the Ubuntu behaviour.
# - Default groups: verify that the `sudo` group exists and is enabled in
#   sudoers on minimal images.

if [[ -n "${VPS_STACK_OS_DEBIAN_LOADED:-}" ]]; then
    return 0
fi
VPS_STACK_OS_DEBIAN_LOADED=1

os_check_supported() {
    case "${OS_VERSION_ID}" in
        12 | 13) printf 'planned\n' ;;
        *) printf 'unsupported\n' ;;
    esac
}

_os_debian_not_implemented() {
    log_error "Debian: function $1 is not implemented (support is planned)."
    return 1
}

os_pkg_update() { _os_debian_not_implemented "os_pkg_update"; }
os_pkg_install() { _os_debian_not_implemented "os_pkg_install"; }
os_docker_repo_setup() { _os_debian_not_implemented "os_docker_repo_setup"; }
os_docker_install() { _os_debian_not_implemented "os_docker_install"; }
os_docker_conflicts() { _os_debian_not_implemented "os_docker_conflicts"; }
os_unattended_upgrades_setup() { _os_debian_not_implemented "os_unattended_upgrades_setup"; }
os_ssh_mode() { _os_debian_not_implemented "os_ssh_mode"; }
os_ssh_service() { _os_debian_not_implemented "os_ssh_service"; }
os_ssh_ports() { _os_debian_not_implemented "os_ssh_ports"; }
os_fail2ban_backend() { _os_debian_not_implemented "os_fail2ban_backend"; }
