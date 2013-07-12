lang C
keyboard us
timezone US/Eastern
auth --useshadow --enablemd5
selinux --enforcing
firewall --enabled --service=ssh,mdns,https,http --port=8000:tcp,8443:tcp
bootloader --timeout=1 --append="acpi=force"
network --bootproto=dhcp --device=eth0 --onboot=on
services --enabled=network
part biosboot --fstype=biosboot --size=1 --ondisk sda
part / --size 4096 --fstype ext4 --ondisk sda
repo --name=fedora --mirrorlist=http://mirrors.fedoraproject.org/mirrorlist?repo=fedora-19&arch=x86_64 --excludepkgs=activemq
repo --name=updates --mirrorlist=http://mirrors.fedoraproject.org/mirrorlist?repo=updates-released-f19&arch=x86_64 --excludepkgs=activemq
repo --name=jenkins --baseurl=http://pkg.jenkins-ci.org/redhat --noverifyssl
repo --name=openshift-origin --baseurl=https://mirror.openshift.com/pub/origin-server/nightly/fedora-19/latest/x86_64/
repo --name=openshift-origin-deps --baseurl=https://mirror.openshift.com/pub/openshift-origin/fedora-19/x86_64/ --noverifyssl

%packages --nobase
setup
bash
bash-completion
net-tools
kernel
grub2
e2fsprogs
passwd
policycoreutils
chkconfig
rootfiles
yum
vim-minimal
acpid
lokkit
firewalld
binutils
dhclient
iputils
prelink
setserial
ed
kpartx
dmraid
mdadm
lvm2
tar
gzip
policycoreutils
checkpolicy
libselinux-python
libselinux
selinux-policy-targeted
-authconfig
-wireless-tools
-kbd
-usermode
-fedora-logos
-fedora-release-notes
generic-logos
vim
puppet
activemq
man
audit
mlocate
plymouth

avahi-cname-manager                 
openshift-origin-broker-util
openshift-origin-cartridge-abstract
openshift-origin-cartridge-cron 
openshift-origin-cartridge-diy  
openshift-origin-cartridge-mock     
openshift-origin-cartridge-mysql
openshift-origin-cartridge-perl
openshift-origin-cartridge-php  
openshift-origin-cartridge-ruby 
openshift-origin-msg-common         
openshift-origin-node-proxy         
openshift-origin-node-util          
openshift-origin-port-proxy         
openshift-origin-util               
pam_openshift.x86_64                       
rhc                                 
rubygem-openshift-origin-common     
rubygem-openshift-origin-console    
rubygem-openshift-origin-controller 
rubygem-openshift-origin-dns-avahi  
rubygem-openshift-origin-dns-route53                                          
rubygem-openshift-origin-node

zerofree
%end

%post
set -x
export PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

/bin/cat <<EOF> /etc/resolv.conf
nameserver 8.8.8.8
EOF

/bin/cat <<EOF> /etc/hostname
broker.openshift.local
EOF
/bin/hostname broker.openshift.local

/bin/puppet module install openshift/openshift_origin

/bin/cat <<EOF> /root/configure_origin.pp
class { 'openshift_origin' :
  node_fqdn                  => "broker.openshift.local",
  cloud_domain               => 'openshift.local',
  dns_servers                => ['8.8.8.8'],
  os_unmanaged_users         => [],
  enable_network_services    => true,
  configure_firewall         => true,
  configure_ntp              => true,
  configure_activemq         => true,
  configure_mongodb          => 'delayed',
  set_sebooleans             => 'delayed',
  configure_named            => false,
  configure_avahi            => true,
  configure_broker           => true,
  configure_node             => true,
  development_mode           => true,
  install_login_shell        => true,
  update_network_dns_servers => false,
  avahi_ipaddress            => '127.0.0.1',
  broker_dns_plugin          => 'avahi',
}
EOF

/bin/puppet apply --debug --verbose /root/configure_origin.pp
ln -sf /usr/lib/systemd/system/openshift-mongo-setup.service /etc/systemd/system/multi-user.target.wants/openshift-mongo-setup.service
ln -sf /usr/lib/systemd/system/openshift-selinux-setup.service /etc/systemd/system/multi-user.target.wants/openshift-selinux-setup.service
/sbin/sysctl enable network.service
/usr/bin/updatedb
%end