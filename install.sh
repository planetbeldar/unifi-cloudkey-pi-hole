#!/usr/bin/env bash

interactive="false"

while [ "$1" != "" ]; do
  case "$1" in
  -i | --interactive)
    interactive="true"
    ;;
  esac
  shift
done

apt-get() {
  local dpkg_options=$([[ $interactive != "true" ]] && echo '-o Dpkg::Options::=--force-confold')
  local apt_get_options=$([[ $interactive != "true" ]] && echo "--yes")
  DEBIAN_FRONTEND=noninteractive command apt-get -o Dpkg::Options::=--force-overwrite $dpkg_options $apt_get_options "$@"
}

uninstall_unifi() {
  systemctl stop unifi ubnt-systemhub
  dpkg -P unifi cloudkey-webui ubnt-freeradius-setup freeradius-ldap freeradius-common freeradius-utils libfreeradius2 freeradius php5-cli php5-common php5-fpm php5-json ubnt-unifi-setup
  dpkg -P unattended-upgrades # for some reason, the upgrade of this package sometimes halts the process, install later on.
}

update_deb_sources() {
  rm /etc/apt/sources.list
  rm /etc/apt/sources.list.d/*

  echo "deb http://deb.debian.org/debian bullseye main contrib non-free
deb-src http://deb.debian.org/debian bullseye main contrib non-free

deb http://deb.debian.org/debian-security/ bullseye-security main contrib non-free
deb-src http://deb.debian.org/debian-security/ bullseye-security main contrib non-free

deb http://deb.debian.org/debian bullseye-updates main contrib non-free
deb-src http://deb.debian.org/debian bullseye-updates main contrib non-free" > /etc/apt/sources.list

  echo "deb https://deb.nodesource.com/node_16.x bullseye main" > /etc/apt/sources.list.d/nodesource.list
}

update_dist() {
  echo '* libraries/restart-without-asking boolean true' | debconf-set-selections # make services restart automatically during upgrades
  apt-key adv --keyserver keyserver.ubuntu.com --recv-keys 648ACFD622F3D138 0E98404D386FA1D9 605C66F00D6C9793 112695A0E562B32A 54404762BBB6E853
  apt-get update
  apt-get install apt
  apt-get install curl dh-python e2fsprogs findutils liblocale-gettext-perl libpython2.7 libpython2.7-minimal libpython2.7-stdlib libtext-charwidth-perl libtext-iconv-perl perl perl-base python2.7 python2.7-minimal python3-six
  apt-get upgrade
  apt-get upgrade --with-new-pkgs
}

install_pihole() {
  curl -sSL https://install.pi-hole.net | bash
}

setup_services() {
  service nginx stop
  systemctl stop systemd-resolved
  systemctl mask systemd-resolved nginx

  systemctl start lighttpd
  systemctl status lighttpd

  echo "[Resolve]
DNS=1.1.1.1
DNSStubListener=no" > /etc/systemd/resolved.conf

  hostnamectl set-hostname UniFi-CloudKey-Pi-hole
  pihole -r
  apt-get install unattended-upgrades apt-listchanges # reinstall
}

install_unbound() {
  apt-get install unbound
  systemctl disable unbound-resolvconf.service
  curl -sSL https://raw.githubusercontent.com/planetbeldar/unifi-cloudkey-pi-hole/main/unbound-pi-hole.conf > /etc/unbound/unbound.conf.d/pi-hole.conf
  service unbound restart
  echo 'edns-packet-max=1232' > /etc/dnsmasq.d/99-edns.conf # tell FTL to use same limit as specified in unbound config
  sed -i '/^server=/d' /etc/dnsmasq.d/01-pihole.conf && echo 'server=127.0.0.1#5335' >> /etc/dnsmasq.d/01-pihole.conf
  sed -i '/^PIHOLE_DNS_[0-9]=/d' /etc/pihole/setupVars.conf && echo 'PIHOLE_DNS_1=127.0.0.1#5335' >> /etc/pihole/setupVars.conf
  service pihole-FTL restart
}

main() {
  if [[ $interactive == "true" ]]; then
    printf "Run the install script? (y/N)"
    read -rsn1 install && echo
    [[ ! "$install" =~ ^[Yy]$ ]] && exit 0
  fi

  echo "Checking for root user"
  if [[ "${EUID}" -ne 0 ]]; then
    # when run via curl piping
    if [[ "$0" == "bash" ]]; then
        # Download the install script and run it with admin rights
        exec curl -sSL https://raw.githubusercontent.com/planetbeldar/unifi-cloudkey-pi-hole/main/install.sh | sudo bash "$@"
    else
        # when run via calling local bash script
        exec sudo bash "$0" "$@"
    fi

    exit $?
  fi

  while [[ -n $(systemctl | grep unifi.service | grep activating) ]]; do
    echo -ne "Waiting for unifi to get up and running.. \r"
    sleep 5
  done
  echo && echo "Uninstalling packages"
  uninstall_unifi
  echo "Updating debian sources"
  update_deb_sources
  echo "Running dist upgrade"
  update_dist
  echo "Running Pi-hole installation script (use eth0)"
  install_pihole
  echo "Setting up services"
  setup_services

  printf "Install and configure unbound as your upstream DNS? (Y/n)"
  read -rsn1 install_unbound && echo
  if [[ $install_unbound =~ ^[Yy]$ ]]; then
    echo "Installing and configuring unbound"
    install_unbound
  fi

  echo "Done, please reboot the system."
}

main "$@"
