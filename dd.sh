#!/bin/bash -ex
exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1
echo BEGIN

#let's add our hostname to /etc/hosts
IP=`ifconfig eth0 | awk '/inet addr/{print substr($2,6)}'`
AWS_HOSTNAME=`hostname`
HOSTNAME="${role}-$${AWS_HOSTNAME}"
echo "$${IP} $${HOSTNAME} ${role} $${AWS_HOSTNAME}" >> /etc/hosts

# common
apt-get -y --force-yes install apt-transport-https software-properties-common
apt-get update -y

# install docker
apt-get install -y wget
wget -qO- https://get.docker.com/ | sh
curl -L https://github.com/docker/compose/releases/download/${docker_compose_version}/docker-compose-`uname -s`-`uname -m` > /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose

# install shared tools
apt-get -y --force-yes install joe
apt-get -y --force-yes install git

# install salt
apt-get -y --force-yes install build-essential pkg-config swig
apt-get -y --force-yes install libyaml-0-2 libgmp10
apt-get -y --force-yes install python-dev libyaml-dev libgmp-dev libssl-dev
apt-get -y --force-yes install libzmq3 libzmq3-dev
apt-get -y --force-yes install procps pciutils
apt-get -y --force-yes install python-pip

pip install pyzmq m2crypto pycrypto gitpython psutil
pip install salt==${salt_version}

curl -o /etc/init/salt-minion.conf https://raw.githubusercontent.com/saltstack/salt/develop/pkg/salt-minion.upstart
mkdir -p /etc/salt
touch /etc/salt/minion
cat <<EOF >> /etc/salt/grains
opg-role: ${role}
EOF

start salt-minion

if [  "${is_saltmaster}" == "yes" ]; then
    curl -o /etc/init/salt-master.conf https://raw.githubusercontent.com/saltstack/salt/develop/pkg/salt-master.upstart
    cat <<EOF >> /etc/salt/master
auto_accept: True
file_roots:
  base:
    - /srv/salt
    - /srv/salt/_libs
    - /srv/salt-formulas
state_output: changes
EOF
    start salt-master
fi

echo END
