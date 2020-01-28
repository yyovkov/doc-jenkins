#!/bin/bash

export CLVIP="192.168.2.201"
export CLVIP_FQDN="vip.castle.yyovkov.net"
export CLACTIVE_IP="192.168.2.114"
export CLACTIVE_FQDN="node-a.castle.yyovkov.net"
export CLPASSIVE_IP="192.168.2.115"
export CLPASSIVE_FQDN="node-b.castle.yyovkov.net"
export DRBD_PORT="7789"
export DRBD_HDD="/dev/vdb"
export CLNAME="jenkins"
export JENKINS_USER="jenkins"
export JENKINS_USER_HOME="/home/jenkins"
export ROOTVG=vg_$(hostname -s)
export CLUSERPASS="verystrongpass" # This one should finish in databag

echo "=== Install dbrb ==="
mkdir drbd
cd drbd
curl -O http://mirror.imt-systems.com/elrepo/elrepo/el7/x86_64/RPMS/drbd90-utils-9.1.0-1.el7.elrepo.x86_64.rpm
curl -O http://mirror.imt-systems.com/elrepo/elrepo/el7/x86_64/RPMS/kmod-drbd90-9.0.9-1.el7_4.elrepo.x86_64.rpm
curl -O http://mirror.imt-systems.com/elrepo/elrepo/el7/x86_64/RPMS/drbd90-utils-sysvinit-9.1.0-1.el7.elrepo.x86_64.rpm
sudo yum -y localinstall kmod-drbd90-9.0.9-1.el7_4.elrepo.x86_64.rpm \
        drbd90-utils-9.1.0-1.el7.elrepo.x86_64.rpm \
        drbd90-utils-sysvinit-9.1.0-1.el7.elrepo.x86_64.rpm

echo "=== Install other software ==="
sudo yum install -y epel-release
sudo yum install -y pacemaker pcs resource-agents policycoreutils-python nginx java-1.8.0-openjdk

echo "=== Setup firewall ==="
sudo firewall-cmd --permanent --add-service=high-availability
sudo firewall-cmd --permanent --add-service=http
sudo firewall-cmd --permanent --add-service=https
sudo firewall-cmd --permanent --add-port=7789/tcp
sudo firewall-cmd --reload


echo "=== Setup selinux ==="
sudo setsebool httpd_can_network_connect 1 -P
sudo semanage permissive -a drbd_t

echo "=== Create Disk partition ==="
alias parted="sudo parted -s -a optimal ${DRBD_HDD}"
parted mklabel msdos
parted mkpart primary 1 100%
parted set 1 lvm on

echo "=== Setup drbd resource ==="
sudo tee /etc/drbd.d/jenkins.res << EOF
resource jenkins {
    net {
        protocol C;
        after-sb-0pri discard-zero-changes;
        after-sb-1pri discard-secondary;
        after-sb-2pri disconnect;
    }
    meta-disk internal;
    device /dev/drbd0;
    disk ${DRBD_HDD}1;
    on ${CLACTIVE_FQDN%%.*} { address ${CLACTIVE_IP}:${DRBD_PORT}; }
    on ${CLPASSIVE_FQDN%%.*} { address ${CLPASSIVE_IP}:${DRBD_PORT}; }
}
EOF
sudo drbdadm --force create-md jenkins


echo "=== Setup LVM ==="
sudo cp /etc/lvm/lvmlocal.conf /etc/lvm/.orig_lvmlocal.conf
sudo tee /etc/lvm/lvmlocal.conf <<-EOF
global {
        use_lvmetad = 0
}

activation {
        volume_list = [ "${ROOTVG}" ]
}

devices {
        write_cache_state = 0
}
local {
}
EOF
sudo systemctl disable lvm2-lvmetad.service
sudo systemctl stop lvm2-lvmetad.service


echo "=== Cluster setup ==="
echo ${CLUSERPASS} | sudo passwd --stdin hacluster
sudo systemctl enable pcsd
sudo systemctl start pcsd

sudo useradd $JENKINS_USER
sudo mkdir -m 755 /var/cache/jenkins /var/lib/jenkins /var/log/jenkins
sudo mkdir -m 700 ${JENKINS_USER_HOME}/.ssh
sudo mkdir -p /opt/jenkins/{etc,lib}
sudo chown ${JENKINS_USER}: ${JENKINS_USER_HOME}/.ssh

sudo cp /home/yyovkov/jenkins_pacemaker/jenkins_init /etc/init.d/jenkins
sudo chmod 755 /etc/init.d/jenkins
sudo lvextend -L +2G /dev/vg_$(hostname -s)/lv_opt
sudo xfs_growfs /dev/vg_$(hostname -s)/lv_opt
sudo curl -Lo /opt/jenkins/lib/jenkins.war http://mirrors.jenkins.io/war-stable/latest/jenkins.war
sudo tee /opt/jenkins/etc/jenkins <<-EOF
JENKINS_HOME="/var/lib/jenkins"
JENKINS_JAVA_CMD=""
JENKINS_USER="${JENKINS_USER}"
JENKINS_JAVA_OPTIONS="-Djava.awt.headless=true -Djenkins.install.runSetupWizard=false -Dhudson.TcpSlaveAgentListener.hostName=${CLVIP_FQDN}"
JENKINS_PORT="8080"
JENKINS_LISTEN_ADDRESS="127.0.0.1"
JENKINS_HTTPS_PORT=""
JENKINS_HTTPS_KEYSTORE=""
JENKINS_HTTPS_KEYSTORE_PASSWORD=""
JENKINS_HTTPS_LISTEN_ADDRESS=""
JENKINS_DEBUG_LEVEL="5"
JENKINS_ENABLE_ACCESS_LOG="no"
JENKINS_HANDLER_MAX="100"
JENKINS_HANDLER_IDLE="20"
EOF
sudo tee /etc/logrotate.d/jenkins <<-'EOF'
/var/log/jenkins/jenkins.log /var/log/jenkins/access_log {
    compress
    dateext
    maxage 365
    rotate 99
    size=+4096k
    notifempty
    missingok
    create 644
    copytruncate
}
EOF