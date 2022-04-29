#!/usr/bin/env bash

debian_dist="bullseye"

while [ "$1" != "" ]; do
  case "$1" in
  --unattended)
    unattended="true"
    ;;
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
  # ubnt-systemhub service needs to start to make the CK LED stop blinking
  # systemctl stop unifi ubnt-systemhub
  # dpkg -P ubnt-systemhub
  dpkg -P unifi cloudkey-webui ubnt-freeradius-setup freeradius-ldap freeradius-common freeradius-utils libfreeradius2 freeradius php5-cli php5-common php5-fpm php5-json ubnt-unifi-setup
  # for some reason, the upgrade of this package sometimes halts the process, install later on.
  dpkg -P unattended-upgrades
}

update_deb_sources() {
  local _debian_dist=$1
  [[ -z $_debian_dist ]] && echo "Error, specify dist" && return
  rm /etc/apt/sources.list
  rm /etc/apt/sources.list.d/*

  echo "deb http://deb.debian.org/debian $_debian_dist main contrib non-free
deb-src http://deb.debian.org/debian $_debian_dist main contrib non-free

deb http://deb.debian.org/debian-security/ $_debian_dist-security main contrib non-free
deb-src http://deb.debian.org/debian-security/ $_debian_dist-security main contrib non-free

deb http://deb.debian.org/debian $_debian_dist-updates main contrib non-free
deb-src http://deb.debian.org/debian $_debian_dist-updates main contrib non-free" > /etc/apt/sources.list

  echo "deb https://deb.nodesource.com/node_16.x $_debian_dist main" > /etc/apt/sources.list.d/nodesource.list
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
  local _unattended=$([[ $1 -eq "true" ]] && echo '/dev/stdin --unattended')

  curl -sSL https://install.pi-hole.net | bash $_unattended
}

setup_services() {
  service nginx stop
  systemctl stop systemd-resolved
  systemctl mask systemd-resolved nginx

  # systemctl start lighttpd
  # systemctl status lighttpd

#   echo "[Resolve]
# DNS=1.1.1.1
# DNSStubListener=no" > /etc/systemd/resolved.conf
}

install_unbound() {
  local _unattended=$1

  apt-get install unbound
  systemctl disable unbound-resolvconf.service
  curl -sSL https://raw.githubusercontent.com/planetbeldar/unifi-cloudkey-pi-hole/main/unbound-pi-hole.conf > /etc/unbound/unbound.conf.d/pi-hole.conf
  service unbound restart
  echo 'edns-packet-max=1232' > /etc/dnsmasq.d/99-edns.conf # tell FTL to use same limit as specified in unbound config

  [[ $_unattended ]] && return; # dont touch config - this assumes you already provided the pi-hole config
  sed -i '/^server=/d' /etc/dnsmasq.d/01-pihole.conf && echo 'server=127.0.0.1#5335' >> /etc/dnsmasq.d/01-pihole.conf
  sed -i '/^PIHOLE_DNS_[0-9]=/d' /etc/pihole/setupVars.conf && echo 'PIHOLE_DNS_1=127.0.0.1#5335' >> /etc/pihole/setupVars.conf
}

configure_rev_server() {
  local cidr="$1"
  local dhcp_ip="$2"
  local domain="$3"

  [[ -z $cidr || -z $dhcp_ip ]] && echo "Error, no rev server configuration defined" && return

  sed -i '/^rev-server=/d' /etc/dnsmasq.d/01-pihole.conf
  echo "rev-server=$cidr,$dhcp_ip" >> /etc/dnsmasq.d/01-pihole.conf
  sed -i '/^REV_SERVER/d' /etc/pihole/setupVars.conf
  echo "REV_SERVER=true
REV_SERVER_CIDR=$cidr
REV_SERVER_TARGET=$dhcp_ip
REV_SERVER_DOMAIN=$domain" >> /etc/pihole/setupVars.conf
}

configure_allow_subnets() {
  sed -i '/^interface=/d' /etc/dnsmasq.d/01-pihole.conf
  echo 'interface=eth0' >> /etc/dnsmasq.d/01-pihole.conf
  sed -i '/^DNSMASQ_LISTENING=/d' /etc/pihole/setupVars.conf
  echo 'DNSMASQ_LISTENING=single' >> /etc/pihole/setupVars.conf
}

add_gravity_adlist() {
  local adlist="$1"
  local comment="$2"

  [[ -z $adlist ]] && echo "Error, no adlist to add" && return

  if [[ -z $(command -v sqlite3) ]]; then
    apt-get install sqlite3
  fi

  sqlite3 /etc/pihole/gravity.db "INSERT INTO adlist (address, comment) VALUES ('$adlist', '$comment');"
  pihole -g
}

is_dist() {
  local _debian_dist=$1
  [[ -z $_debian_dist ]] && echo "Error, needs to eat argument" && exit 1

  [[ -n $(hostnamectl | grep "$_debian_dist") ]] && echo "true"
}

is_installed() {
  local package=$1
  [[ -z $package ]] && return; # return if no argument

  [[ -n $(dpkg -l | grep "$package") ]] && echo "true"
}

prompt_match() {
  local prompt=$1
  local pattern=${2:-(.*)?}
  local instant=$3
  local options="-r$([[ $instant ]] && echo "sn1")"
  local input

  IFS= read -p "$prompt" "$options" input
  while [[ ! "$input" =~ $pattern ]]; do
    if [[ $instant ]]; then
      IFS= read "$options" input
    else
      IFS= read -p "$prompt" "$options" input
    fi
  done
  echo "$input"
}


main() {
  echo "Checking for root user"
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Please rerun script as root"
    exit 1
  fi

  local web_password=$(prompt_match "Password for Pi-hole web interface: ")
  local use_unbound=$(prompt_match "Install and configure unbound as your upstream DNS? (y/n)" [yYnN] 1) && echo
  local add_adlist=$(prompt_match "Add THE #ONE adlist - https://dbl.oisd.nl? (y/n)" [yYnN] 1) && echo

  # this can be configured by copying pi-hole config (setupVars.conf) before unattended install
  if [[ $unattended -ne "true" ]]; then
    local use_rev_server=$(prompt_match "Setup conditional forwarding? (y/n)" [yYnN] 1) && echo
    if [[ $use_rev_server =~ ^[Yy]$ ]]; then
      local cidr=$(prompt_match "Network CIDR: " ^[0-9.\/]*$)
      local dhcp_ip=$(prompt_match "DHCP IP: " ^[0-9.]*$)
      local domain=$(prompt_match "Domain (optional): " ^[a-zA-Z.-]*$)
    fi

    local allow_subnets=$(prompt_match "Allow subnets to use Pi-hole/dnsmasq? (y/n)" [yYnN] 1) && echo
  fi

  echo "Setting timezone"
  timedatectl set-timezone $(curl -sSL https://ipapi.co/timezone)

  while [[ -n $(systemctl | grep unifi.service | grep activating) ]]; do
    echo -ne "Waiting for the unifi service to get up and running.. \r"
    sleep 5
  done

  if [[ $(is_dist $debian_dist) ]]; then
    echo "Debian dist already upgraded to $debian_dist"
  else
    echo "\nUninstalling unifi packages"
    uninstall_unifi
    echo "Updating debian sources"
    update_deb_sources $debian_dist
    echo "Running dist upgrade"
    update_dist
  fi

  if [[ $use_unbound =~ ^[yY]$ ]]; then
    echo "Installing and configuring unbound"
    install_unbound $unattended
  fi
  echo "Running Pi-hole installation script"
  install_pihole $unattended
  echo "Setting up services"
  setup_services

  if [[ $use_rev_server =~ ^[yY]$ ]]; then
    echo "Configuring dnsmasq and pi-hole for conditional forwarding"
    configure_rev_server $cidr $dhcp_ip $domain
  fi

  if [[ $allow_subnets =~ ^[yY]$ ]]; then
    echo "Configuring dnsmasq and pi-hole to allow subnets"
    configure_allow_subnets
  fi

  if [[ $add_adlist =~ ^[yY]$ ]]; then
    echo "Installing adlist - https://dbl.oisd.nl"
    add_gravity_adlist "https://dbl.oisd.nl" "https://oisd.nl"
  fi

  if [[ -n $web_password ]]; then
    echo "Setting Pi-hole web interface password"
    pihole -a -p $web_password
  fi

  hostnamectl set-hostname UniFi-CloudKey-Pi-hole
  if [[ ! $(is_installed "unattended-upgrades") ]]; then
   apt-get install unattended-upgrades apt-listchanges
  fi

  # pihole -r
  service pihole-FTL restart
  echo "Done, please reboot the system."
}

main "$@"
