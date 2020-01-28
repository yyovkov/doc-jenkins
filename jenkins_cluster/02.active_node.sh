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

echo "=== Setup Firewall ===="
sudo firewall-cmd --permanent --add-service=high-availability
sudo firewall-cmd --permanent --add-service=http
sudo firewall-cmd --permanent --add-service=https
sudo firewall-cmd --permanent --add-port=7789/tcp
sudo firewall-cmd --reload

echo "=== Setup selinux ==="
sudo setsebool httpd_can_network_connect 1 -P
sudo semanage permissive -a drbd_t

echo "=== Setup Cluster ==="
sudo useradd $JENKINS_USER
sudo mkdir -m 755 /var/cache/jenkins /var/lib/jenkins /var/log/jenkins 
sudo mkdir -m 700 ${JENKINS_USER_HOME}/.ssh
sudo mkdir -p /opt/jenkins/{etc,lib}
sudo chown ${JENKINS_USER}: ${JENKINS_USER_HOME}/.ssh

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
sudo drbdadm up jenkins
sudo drbdadm primary jenkins --force
sudo pvcreate /dev/drbd/by-res/jenkins/0
sudo vgcreate vg_jenkins /dev/drbd/by-res/jenkins/0
sudo lvcreate -L10G -n lv_lib vg_jenkins
sudo lvcreate -L2G -n lv_log vg_jenkins
sudo lvcreate -L2G -n lv_cache vg_jenkins
sudo lvcreate -L100M -n lv_ssh vg_jenkins
sudo lvcreate -L100M -n lv_nginx vg_jenkins
sudo mkfs.xfs /dev/vg_jenkins/lv_lib
sudo mkfs.xfs /dev/vg_jenkins/lv_log
sudo mkfs.xfs /dev/vg_jenkins/lv_cache
sudo mkfs.xfs /dev/vg_jenkins/lv_ssh
sudo mkfs.xfs /dev/vg_jenkins/lv_nginx
sudo vgchange -an vg_jenkins
sudo drbdadm secondary jenkins
sudo drbdadm down jenkins

echo "=== Setup LVM ==="
sudo cp /etc/lvm/lvmlocal.conf /etc/lvm/.orig_lvmlocal.conf
sudo tee /etc/lvm/lvmlocal.conf <<EOF
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

echo ${CLUSERPASS} | sudo passwd --stdin hacluster
sudo systemctl enable pcsd
sudo systemctl start pcsd

sudo pcs cluster auth -u hacluster -p ${CLUSERPASS} ${CLACTIVE_FQDN%%.*}
sudo pcs cluster setup --name ${CLNAME} --start --enable --encryption 1 ${CLACTIVE_FQDN%%.*}
sudo pcs property set no-quorum-policy=ignore
sudo pcs property set stonith-enabled=false

sudo pcs resource create jenkins-drbd ocf:linbit:drbd drbd_resource=jenkins
sudo pcs resource master master-jenkins-drbd jenkins-drbd master-max=1 master-node-max=1 clone-max=2 clone-node-max=1 notify=true
sudo pcs resource cleanup jenkins-drbd
sudo pcs resource create jenkins-vg ocf:heartbeat:LVM volgrpname=vg_jenkins exclusive=true
sudo pcs resource create jenkins-fs-cache ocf:heartbeat:Filesystem device=/dev/vg_jenkins/lv_cache directory=/var/cache/jenkins fstype=xfs
sudo pcs resource create jenkins-fs-lib ocf:heartbeat:Filesystem device=/dev/vg_jenkins/lv_lib directory=/var/lib/jenkins fstype=xfs
sudo pcs resource create jenkins-fs-log ocf:heartbeat:Filesystem device=/dev/vg_jenkins/lv_log directory=/var/log/jenkins fstype=xfs
sudo pcs resource create jenkins-fs-nginx ocf:heartbeat:Filesystem device=/dev/vg_jenkins/lv_nginx directory=/etc/nginx fstype=xfs
sudo pcs resource create jenkins-fs-ssh ocf:heartbeat:Filesystem device=/dev/vg_jenkins/lv_ssh directory=${JENKINS_USER_HOME}/.ssh fstype=xfs
sudo pcs resource create jenkins-ip ocf:heartbeat:IPaddr2 ip=${CLVIP} cidr_netmask=32 op monitor interval=30s
sudo pcs resource create jenkins-service lsb:jenkins --force
sudo pcs resource create jenkins-proxy ocf:heartbeat:nginx configfile=/etc/nginx/nginx.conf op monitor timeout="5s" interval="5s" --force
sudo pcs resource group add jenkins jenkins-vg jenkins-fs-cache jenkins-fs-lib jenkins-fs-ssh jenkins-fs-log jenkins-fs-nginx jenkins-ip jenkins-service jenkins-proxy
sudo pcs constraint colocation add jenkins master-jenkins-drbd INFINITY with-rsc-role=Master
sudo pcs constraint order promote master-jenkins-drbd then start jenkins

echo "=== Install Jenkins ==="
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
sudo chown ${JENKINS_USER}: /var/cache/jenkins /var/lib/jenkins /var/log/jenkins ${JENKINS_USER_HOME}/.ssh
sudo chmod 700 ${JENKINS_USER_HOME}/.ssh
sudo pcs resource cleanup jenkins-service

echo "=== Install NGINX ==="
sudo cp /home/yyovkov/jenkins_pacemaker/mime.types /etc/nginx/mime.types
sudo mkdir /etc/nginx/ssl
sudo openssl req -subj "/CN=${CLVIP_FQDN}/O=My Company Name LTD./C=US" \
    -new -newkey rsa:2048 -days 365 -nodes -x509 \
    -keyout /etc/nginx/ssl/${CLVIP_FQDN}.key \
    -out /etc/nginx/ssl/${CLVIP_FQDN}.crt
sudo tee /etc/nginx/nginx.conf <<-'EOF'
user nginx;
worker_processes auto;
error_log /var/log/nginx/error.log;
pid /run/nginx.pid;

events {
    worker_connections 1024;
}

http {
    log_format  main  '$remote_addr - $remote_user [$time_local] "$request" '
                      '$status $body_bytes_sent "$http_referer" '
                      '"$http_user_agent" "$http_x_forwarded_for"';

    access_log  /var/log/nginx/access.log  main;

    sendfile            on;
    tcp_nopush          on;
    tcp_nodelay         on;
    keepalive_timeout   65;
    types_hash_max_size 2048;

    include             /etc/nginx/mime.types;
    default_type        application/octet-stream;

    server {
        listen       80 default_server;
        server_name  ${CLVIP_FQDN};

        proxy_set_header Host $host:$server_port;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        location ~ /jnlpJars/(slave|jenkins-cli).jar$ {
            proxy_pass http://127.0.0.1:8080$request_uri;
        }

        location / {
                return 301 https://$host$request_uri;
        }

    }

    server {
        listen       443 ssl http2 default_server;
        listen       [::]:443 ssl http2 default_server;
        server_name  ${CLVIP_FQDN};
        root         /usr/share/nginx/html;

       ssl_certificate "/etc/nginx/ssl/${CLVIP_FQDN}.crt";
       ssl_certificate_key "/etc/nginx/ssl/${CLVIP_FQDN}.key";
       ssl_session_cache shared:SSL:1m;
       ssl_session_timeout  10m;
       ssl_ciphers HIGH:!aNULL:!MD5;
       ssl_prefer_server_ciphers on;

        location / {
            proxy_set_header Host $host:$server_port;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
            proxy_pass http://127.0.0.1:8080;

            proxy_http_version 1.1;
            proxy_request_buffering off;
            proxy_buffering off; # Required for HTTP-based CLI to work over SSL
            # workaround for https://issues.jenkins-ci.org/browse/JENKINS-45651
            add_header 'X-SSH-Endpoint' '${CLVIP_FQDN}:30022' always;
        }

       error_page 404 /404.html;
           location = /40x.html {
       }

       error_page 500 502 503 504 /50x.html;
           location = /50x.html {
       }
   }

}
EOF
sudo sed -i -e "s/\${CLVIP_FQDN}/${CLVIP_FQDN}/g" /etc/nginx/nginx.conf
sudo restorecon -R /etc/nginx
sudo pcs resource cleanup jenkins-proxy

echo "=== Add passive node ==="
sudo pcs cluster auth -u hacluster -p ${CLUSERPASS} ${CLPASSIVE_FQDN%%.*}
sudo pcs cluster --name jenkins node add --start --enable ${CLPASSIVE_FQDN%%.*}