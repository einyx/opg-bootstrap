#!/bin/bash -eu

#
# bootstrap.sh
#
# The main tasks of this script are:
#
#   - Clean-up packages that are not needed any more;
#   - Setup host name, populate /etc/hosts, etc.;
#   - Setup device for the /srv mount point (move /tmp to /srv/tmp, etc.);
#   - Fix and format (use "btrfs") mount points for Docker;
#   - Setup device for the /data mount point;
#   - Add details (e.g. "Name" tag, etc.) that needed when an
#     instance is a part of the Amazon Auto Scaling Group;
#   - Populate Salt Master and/or Minion configuration (e.g. grains, etc.);
#   - Run Salt highstate (at the end).
#
# WARNING: This script is not idempotent, and it's only intended to
#          be run only during a first-boot of a particular node.
#

export PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

export DEBIAN_FRONTEND=noninteractive DEBIAN_PRIORITY=critical
export DEBCONF_NONINTERACTIVE_SEEN=true

readonly LOCK_FILE='/etc/os-bootstrap'
readonly EC2_METADATA_URL='http://169.254.169.254/latest/meta-data'

# Get current time.
readonly TIMESTAMP=$(TZ=UTC date +%s)

# Make sure files are 644 and directories are 755.
umask 022

# Check whether this script was already run?
if [[ -f $LOCK_FILE ]]; then
    echo 'Previous run has been detected, aborting ...'
    exit 1
fi
# Make sure that Minion will pick his new ID to
# advertise use after the new host name was set.
rm -f /etc/salt/minion_id

# Setup and/or correct current host name.
IP=$(curl -s ${EC2_METADATA_URL}/local-ipv4)
DOMAIN="${STACKNAME}.${DOMAIN}"
FQDN="${HOSTNAME}.${DOMAIN}"

HOSTS=( "$IP $FQDN $HOSTNAME" )
if [[ $ROLE == 'master' ]]; then
    # When on a Salt Master, then add alias
    # plus re-point at itself to run against.
    HOSTS[0]+=' salt'
    SALT_MASTER_IP='127.0.0.1'
else
    if [[ -z $SALT_MASTER_IP ]]; then
        echo "The 'SALT_MASTER_IP' environment variable has to be set, aborting..."
        exit 1
    fi
    # Add static entry for the Salt Master,
    # to *ensure* that we can always reach it,
    # despite DNS failure, etc.
    HOSTS+=( "$SALT_MASTER_IP salt" )
fi


cat <<EOF | sed -e '/^$/d' | tee /etc/hosts
127.0.0.1 localhost.localdomain localhost loopback
$(for e in "${HOSTS[@]}"; do
    echo "$e"
done)
EOF

chown root:root /etc/hosts
chmod 644 /etc/hosts

echo $HOSTNAME | tee \
    /proc/sys/kernel/hostname \
    /etc/hostname

chown root:root /etc/hostname
chmod 644 /etc/hostname

echo $DOMAIN | tee \
    /proc/sys/kernel/domainname

hostname -F /etc/hostname
service rsyslog restart


# Only needed when an instance is launched by
# the Amazon Auto Scaling Group automatically.
if [[ -z $EC2_AUTO_SCALING_GROUP ]]; then
    EC2_AUTO_SCALING_GROUP='no'
fi

# Check, if we need to wait for attached volume.
if [[ -z $EC2_WAIT_FOR_VOLUME ]]; then
    EC2_WAIT_FOR_VOLUME='no'
fi

# By default, we don't really want to disable
# the Docker service from running, unless told
# to do so explicitly.
if [[ -z $DISABLE_DOCKER ]]; then
    DISABLE_DOCKER='no'
fi

# Need to stop Salt services.
for s in salt-{minion,master}; do
    if [[ -f /etc/init/${s}.conf ]]; then
        service $s stop || true

        # Stop with extreme prejudice.
        if pgrep -f $s &>dev/null; then
            pkill -9 -f $s
        fi

        # Purge any keys and/or SSL certificates
        # that might have linger behind.
        rm -rf /etc/salt/pki/*
    fi
done

# Check, whether we are a Salt Master by any chance?
# Note: Checking for the "master" role is to make
# everything backward compatible.
if [[ $ROLE != "master" ]]; then
    SALT_MASTER='no'
    echo deb http://ppa.launchpad.net/saltstack/salt/ubuntu `lsb_release -sc` main | sudo tee /etc/apt/sources.list.d/saltstack.list
    wget -q -O- "http://keyserver.ubuntu.com:11371/pks/lookup?op=get&search=0x4759FA960E27C0A6" | sudo apt-key add -
    apt-get update && apt-get install -y salt-minion && service salt-minion start
fi
if [[ $ROLE == "master" ]]; then
    SALT_MASTER='yes'
    echo deb http://ppa.launchpad.net/saltstack/salt/ubuntu `lsb_release -sc` main | sudo tee /etc/apt/sources.list.d/saltstack.list
    wget -q -O- "http://keyserver.ubuntu.com:11371/pks/lookup?op=get&search=0x4759FA960E27C0A6" | sudo apt-key add -
    apt-get update && apt-get install -y salt-master salt-minion && service salt-master start && service salt-minion start && salt-call state.highstate
fi


# A list of required environment variables that have to
# be exported prior to executing this script.
REQUIRED=(
    DOMAIN
    ROLE
    ORGANISATION
    PROJECT
    STACKNAME
    ENVIRONMENT
    RELEASESTAGE
    BRANCH
)

if [[ $EC2_AUTO_SCALING_GROUP == 'no' ]]; then
    REQUIRED+=( HOSTNAME )
fi

# Check if environment variables are present and non-empty.
for v in ${REQUIRED[@]}; do
    eval VALUE='$'${v}
    if [[ -z $VALUE ]]; then
        echo "The '$v' environment variable has to be set, aborting..."
        exit 1
    fi
done

# Disable TCP segmentation offload (TSO).
ethtool -K eth0 tso off gso off

NETWORK_INTERFACES='/etc/network/interfaces'
if [[ -d /etc/network/interfaces.d ]]; then
    NETWORK_INTERFACES='/etc/network/interfaces.d/eth0.cfg'
fi

chown root:root $NETWORK_INTERFACES
chmod 644 $NETWORK_INTERFACES

# Apply if needed to make persistent.
if ! grep -q 'ethtool' $NETWORK_INTERFACES &>/dev/null; then
    cat <<'EOF' | tee -a $NETWORK_INTERFACES
post-up ethtool -K eth0 tso off gso off
EOF
fi

# Make sure that Minion will pick his new ID to
# advertise use after the new host name was set.
rm -f /etc/salt/minion_id

# Make sure to remove any cache left by Salt, etc.
rm -rf /var/{cache,log,run}/salt/*

# Whether the node has Docker installed.
DOCKER='no'
if docker --version &>/dev/null; then
    # Need to stop Docker in order to make sure that
    # the /srv/docker is not in use, as often "aufs"
    # and "devicemapper" drivers will be active on
    # boot causing "device or resource busy" errors.
    service docker stop || true

    # Disable the Docker service and switch it
    # off completely if requested to do so.
    if [[ $DISABLE_DOCKER == 'yes' ]]; then
        for f in /etc/init/docker.conf /etc/init.d/docker; do
            dpkg-divert --rename $f
        done

        update-rc.d -f docker disable || true
    else
        DOCKER='yes'
    fi
fi

# Scan SCSI bus to look for new devices.
for b in /sys/class/scsi_host/*/scan; do
    echo '- - -' > $b
done

# Refresh partition table for each block device.
for b in $(lsblk -dno NAME | awk '!/(sr.*|mapper)/ { print $1 }'); do
    sfdisk -R /dev/${b} 2> /dev/null || true
done

# Select correct device for the extra attached ephemeral
# volume (usually mounted under the /srv mount point).
SERVICE_STORAGE='no'
SERVICE_STORAGE_DEVICES=()
SERVICE_STORAGE_DEVICES_COUNT=0

# Get the list of devices from Amazon ...
EPHEMERALS=($(
    curl -s ${EC2_METADATA_URL}/block-device-mapping/ | \
        awk '/ephemeral[[:digit:]]+/ { print }'
))

# ... and validate whether a particular device actually
# exists which is not always the case, as sometimes the
# meta-data service would return data where no actual
# device is present.
for d in "${EPHEMERALS[@]}"; do
    DEVICE=$(curl -s ${EC2_METADATA_URL}/block-device-mapping/${d})
    if [[ -n $DEVICE ]]; then
        # Try to detect the device, taking into
        # the account different naming scheme
        # e.g., /dev/sdb vs /dev/xvdb, etc.
        if [[ ! -b /dev/${DEVICE} ]]; then
            DEVICE=${DEVICE/sd/xvd}
            [[ -b /dev/${DEVICE} ]] || continue
        fi
    fi

    # Got a device? Great.
    SERVICE_STORAGE='yes'
    SERVICE_STORAGE_DEVICES+=( "/dev/${DEVICE}" )
done

# Make sure to sort the devices list.
SERVICE_STORAGE_DEVICES=($(
    printf '%s\n' "${SERVICE_STORAGE_DEVICES[@]}" | sort
))

# How may devices do we have at our disposal? This is
# needed to setup RAID (stripe) later.
SERVICE_STORAGE_DEVICES_COUNT=${#SERVICE_STORAGE_DEVICES[@]}

# Make sure "noop" scheduler is set. Alternatively,
# the "deadline" could be used to potentially reduce
# I/O latency in some cases. Also, set read-ahead
# value to double the default.
for d in "${SERVICE_STORAGE_DEVICES[@]}"; do
    echo 'noop' > /sys/block/${d##*/}/queue/scheduler
    blockdev --setra 512 $d
done

# Select correct device for the extra attached EBS-backed
# volume (usually mounted under the /data mount point).
DATA_STORAGE='no'
DATA_STORAGE_DEVICE='/dev/xvdh'
if [[ $EC2_WAIT_FOR_VOLUME == 'yes' ]]; then
    # Keep track of number of attempts.
    COUNT=0
    while [[ $DATA_STORAGE == 'no' ]]; do
        # Keep waiting up to 5 minutes (extreme case) for the volume.
        if (( $COUNT >= 60 )); then
            echo "Unable to find device $DATA_STORAGE_DEVICE, volume not attached?"
            break
        fi

        for d in /dev/{xvdh,sdh}; do
            if [[ -b $d ]]; then
                DATA_STORAGE='yes'
                DATA_STORAGE_DEVICE=$d
                break
            fi
        done

        COUNT=$(( $COUNT + 1 ))
        sleep 5
    done
fi

if [[ $EC2_AUTO_SCALING_GROUP == 'yes' ]]; then
    INSTANCE_ID=$(curl -s ${EC2_METADATA_URL}/instance-id)
    # Remove the instance ID prefix.
    HOSTNAME="${ROLE}-$(echo $INSTANCE_ID)"

    if [[ -z $HOSTED_ZONE_ID ]]; then
        echo "The 'HOSTED_ZONE_ID' environment variable has to be set, aborting..."
        exit 1
    fi
fi



# Remove anything that looks like a floppy drive.
sed -i -e \
    '/^.\+fd0/d;/^.\*floppy0/d' \
    /etc/fstab

# Re-format /etc/fstab to fix whitespaces there.
sed -i -e \
    '/^#/!s/\s\+/\t/g' \
    /etc/fstab

# Remove entries for the time being.
sed -i -e \
    '/^.*\/mnt/d;/^.*\/srv/d' \
    /etc/fstab

# Clean-up packages that are not needed.
{
    apt-get -y --force-yes purge parted
    apt-get -y --force-yes purge kpartx
    apt-get -y --force-yes purge '^ruby*'
    apt-get -y --force-yes purge '^libruby*'
} || true

apt-get -y --force-yes autoremove
apt-get clean

# Clean ...
rm -f \
    /var/log/dpkg.log \
    /var/log/dmesg.0 \
    /var/log/apt/*

if [[ $SERVICE_STORAGE == 'yes' ]]; then
    # Make sure that /mnt and /srv are not mounted.
    for d in /mnt /srv; do
        # Nothing of value should be there in these directories.
        if [[ -d $d ]]; then
            umount -f $d || true
            rm -rf ${d}/*
        else
            mkdir -p $d
        fi

        chown root:root $d
        chmod 755 $d
    done

    # Make sure that attached volume really
    # is not mounted anywhere.
    for d in "${SERVICE_STORAGE_DEVICES[@]}"; do
        if grep -q $d /proc/mounts &>/dev/null; then
            # Sort by length, in order to unmount longest path first.
            grep $d /proc/mounts | awk '{ print length, $2 }' | \
                sort -gr | cut -d' ' -f2- | xargs umount -f || true
        fi
    done

    # Should not be mounted at this stage.
    umount -f /tmp || true

    # Wipe any old file system signature, just in case.
    for d in "${SERVICE_STORAGE_DEVICES[@]}"; do
        wipefs -a$(wipefs -f &>/dev/null && echo 'f') $d
    done
fi

if [[ $DATA_STORAGE == 'yes' ]]; then
    # Make sure that /data is not mounted.
    if [[ -d /data ]]; then
        umount -f /data || true
        rm -rf /data/*
    else
        mkdir -p /data
    fi

    chown root:root /data
    chmod 755 /data

    # Wipe any old file system signature, just in case.
    wipefs -a$(wipefs -f &>/dev/null && echo 'f') \
           $DATA_STORAGE_DEVICE
fi

# Add support for the Copy-on-Write (CoW) file system
# using the "btrfs" over the default "aufs".
if [[ $DOCKER == 'yes' ]] && [[ $SERVICE_STORAGE == 'yes' ]]; then
    # Make sure that Docker is not running.
   if pgrep -f 'docker' &>/dev/null; then
        service docker stop || true
    fi

    # Make sure to install dependencies if needed.
    if ! dpkg -s btrfs-tools &>/dev/null; then
        apt-get -y --force-yes update
        apt-get -y --force-yes --no-install-recommends install btrfs-tools

        apt-mark manual btrfs-tools

        apt-get -y --force-yes clean all
    fi

    # Grab first device (to be used when mounting).
    DEVICE=${SERVICE_STORAGE_DEVICES[0]}

    # Create RAID0 if there is more than one device.
    if (( $SERVICE_STORAGE_DEVICES_COUNT > 1 )); then
        mkfs.btrfs -L '/srv' -d raid0 -f \
            $(printf '%s\n' "${SERVICE_STORAGE_DEVICES[@]}")
    else
        mkfs.btrfs -L '/srv' -f $DEVICE
    fi

    # Add extra volume.
    cat <<EOS | sed -e 's/\s\+/\t/g' | tee -a /etc/fstab
$DEVICE /srv btrfs defaults,noatime,recovery,space_cache,compress=lzo,nobootwait,comment=cloudconfig 0 2
EOS

    mount /srv
    btrfs filesystem show /srv

    if (( $SERVICE_STORAGE_DEVICES_COUNT > 1 )); then
        # Make sure to initially re-balance stripes.
        btrfs filesystem balance /srv
    fi

    # Nothing of value should be there in these directories.
    for d in /var/lib/docker /srv/docker; do
        if [[ -d $d ]]; then
            umount -f $d || true
            rm -rf ${d}/*
        else
            mkdir -p $d
        fi

        chown root:root $d
        chmod 755 $d
    done

    # Move /tmp to /srv/tmp - hope, that there is not a lot
    # of data present in under /tmp already ...
    mkdir -p /srv/tmp
    chown root:root /srv/tmp
    chmod 1777 /srv/tmp

    # We need to use /var/tmp this time.
    rsync -avr -T /var/tmp /tmp/ /srv/tmp

    # Clean and correct permission.
    rm -rf /tmp/*
    chown root:root /tmp
    chmod 1777 /tmp

    # A bind-mount for the surrogate /tmp directory.
    cat <<'EOS' | sed -e 's/\s\+/\t/g' | tee -a /etc/fstab
/srv/tmp /tmp none bind 0 2
EOS

    # A bind-mount for the Docker root directory.
    cat <<'EOS' | sed -e 's/\s\+/\t/g' | tee -a /etc/fstab
/srv/docker /var/lib/docker none bind 0 2
EOS

    # Mount bind-mounts, etc.
    for d in /srv/{tmp,docker}; do
        mount $d
    done

    # Use "btrfs" over "aufs" by default as the solution
    # for the Copy-on-Write (CoW) file system.
    sed -i -e \
        's/.*DOCKER_OPTS="\(.*\)"/DOCKER_OPTS="\1 --ipv6=false -s btrfs"/g' \
        /etc/default/docker

    service docker restart
fi

# This is the no Copy-on-Write (CoW) case. There are images
# without Docker installed available for use, but we want to
# move /tmp to /srv/tmp to get extra space, etc.
if [[ $DOCKER == 'no' ]] && [[ $SERVICE_STORAGE == 'yes' ]]; then
    # Grab first device (to be overridden later, if needed).
    DEVICE=${SERVICE_STORAGE_DEVICES[0]}

    # Create RAID0 if there is more than one device.
    if (( $SERVICE_STORAGE_DEVICES_COUNT > 1 )); then
        # Override the device that will be used when mounting.
        DEVICE='/dev/md0'

        # Make sure to install dependencies if needed.
        if ! dpkg -s mdadm &>/dev/null; then
            apt-get -y --force-yes update
            apt-get -y --force-yes --no-install-recommends install mdadm

            apt-mark manual mdadm

            apt-get -y --force-yes clean all
        fi

        # There is no point in monitoring a stripe (RAID0) array.
        service mdadm stop || true

        sed -i -e \
            's/.*AUTOCHECK.*/AUTOCHECK=false/g' \
            /etc/default/mdadm

        sed -i -e \
            's/.*START_DAEMON.*/START_DAEMON=false/g' \
            /etc/default/mdadm

        chown root:root /etc/default/mdadm
        chmod 644 /etc/default/mdadm

        update-rc.d -f mdadm disable || true

        # Stop any RAID array that might be running,
        # although there should be no arrays present.
        if [[ -b /dev/md0 ]]; then
            rm -f /etc/mdadm/mdadm.conf

            for o in --stop --remove; do
                mdadm $o --force $DEVICE || true
            done

            mdadm --zero-superblock \
                  $(printf '%s\n' "${SERVICE_STORAGE_DEVICES[@]}") || true
        fi

        mdadm --create --verbose $DEVICE --level=stripe --chunk=256 \
              --raid-devices=${SERVICE_STORAGE_DEVICES_COUNT} \
              $(printf '%s\n' "${SERVICE_STORAGE_DEVICES[@]}")

        # Activate device immediately.
        mdadm --readwrite $DEVICE || true

        mdadm --detail $DEVICE

        # Set read-ahead that makes sense for RAID device.
        blockdev --setra 65536 $DEVICE

        # Populate the /etc/mdadm/mdadm.conf file.
        cat <<'EOF' | tee /etc/mdadm/mdadm.conf
DEVICE /dev/sd*[0-9] /dev/xvd*[0-9]
CREATE owner=root group=disk mode=0660 auto=yes
HOMEHOST <system>
MAILADDR root
EOF
        mdadm --detail --scan >> /etc/mdadm/mdadm.conf

        chown root:root /etc/mdadm/mdadm.conf
        chmod 644 /etc/mdadm/mdadm.conf

        # Make sure to load driver on boot.
        update-initramfs -u -k all

        cat /proc/mdstat
    fi

    # By default, the attached volume is formatted with ext3.
    mkfs.ext4 -L '/srv' -m 0 -O dir_index,sparse_super $DEVICE

    # Add extra volume.
    cat <<EOS | sed -e 's/\s\+/\t/g' | tee -a /etc/fstab
$DEVICE /srv ext4 defaults,noatime,barrier=0,data=writeback,errors=remount-ro,nobootwait,comment=cloudconfig 0 2
EOS

    mount /srv
    tune2fs -l $DEVICE

    # Move /tmp to /srv/tmp - hope, that there is not a lot
    # of data present in under /tmp already ...
    mkdir -p /srv/tmp
    chown root:root /srv/tmp
    chmod 1777 /srv/tmp

    # We need to use /var/tmp this time.
    rsync -avr -T /var/tmp /tmp/ /srv/tmp

    # Clean and correct permission.
    rm -rf /tmp/*
    chown root:root /tmp
    chmod 1777 /tmp

    # A bind-mount for the surrogate /tmp directory.
    cat <<'EOS' | sed -e 's/\s\+/\t/g' | tee -a /etc/fstab
/srv/tmp /tmp none bind 0 2
EOS

    # Mount bind-mounts, etc.
    mount /srv/tmp
fi

# Setup the /data mount point on a solid file system (XFS).
# Note: At the moment we do not setup any sort of RAID array
# and/or storage pools on the EBS volumes.
if [[ $DATA_STORAGE == 'yes' ]]; then
    # Make sure to install dependencies if needed.
    if ! dpkg -s xfsprogs &>/dev/null; then
        apt-get -y --force-yes update
        apt-get -y --force-yes --no-install-recommends install xfsprogs

        apt-mark manual xfsprogs

        apt-get -y --force-yes clean all
    fi

    # Clean any file system signatures.
    wipefs -a$(wipefs -f &>/dev/null && echo 'f') $DATA_STORAGE_DEVICE

    mkfs.xfs -q -L '/data' -f $DATA_STORAGE_DEVICE

    # Add extra volume.
    cat <<EOS | sed -e 's/\s\+/\t/g' | tee -a /etc/fstab
$DATA_STORAGE_DEVICE /data xfs defaults,noatime,nodiratime,nobarrier,comment=cloudconfig 0 2
EOS

    mount /data
    xfs_info $DATA_STORAGE_DEVICE
fi

chown root:root /etc/fstab
chmod 644 /etc/fstab

# Mount everything else ...
mount -a

[[ -d /etc/salt/minion.d ]] || mkdir -p /etc/salt/minion.d

chown root:root /etc/salt/minion.d
chmod 755 /etc/salt/minion.d

cat <<'EOF' | tee /etc/salt/minion.d/mine.conf
mine_interval: 5
mine_functions:
    status.uptime: []
    network.interfaces: []
    network.ip_addrs: []
EOF

chown root:root /etc/salt/minion.d/mine.conf
chmod 644 /etc/salt/minion.d/mine.conf

# Populate Salt Master configuration, if needed.
if [[ $SALT_MASTER == 'yes' ]]; then
    cat <<'EOF' | tee /etc/salt/master
open_mode: True
pillar_opts: True
file_roots:
  base:
    - /srv/salt
    - /srv/salt/_libs
    - /srv/salt-formulas
pillar_roots:
  base:
    - /srv/pillar
fileserver_backend:
  - roots
peer:
  .*:
    - grains.get
EOF

    chown root:root /etc/salt/master
    chmod 644 /etc/salt/master
else
    # Salt Master should not be running.
    service salt-master stop
fi

# Populate Salt Minion with grains.
cat <<EOF | tee /etc/salt/grains
provider: ec2
opg_provider: ec2
opg_role: $ROLE
opg_organisation: $ORGANISATION
opg_project: $PROJECT
opg_stackname: $STACKNAME
opg_environment: $ENVIRONMENT
opg_releasestage: $RELEASESTAGE
opg_branch: $BRANCH
opg_domain: $DOMAIN
EOF

# Add more grains (mainly about *this* EC2 instance)
# using the meta-data coming from the EC2 itself.
EC2_RESOURCES=(
    ami-id
    instance-id
    instance-type
    placement/availability-zone
    profile
    reservation-id
)

declare -A GRAINS=()
for s in ${EC2_RESOURCES[@]}; do
    KEY=${s/-/_}
    KEY=${KEY##*/}

    VALUE=$(curl -s ${EC2_METADATA_URL}/${s})

    if [[ $KEY == 'availability_zone' ]]; then
        GRAINS['region']=$(echo $VALUE | sed 's/\w$//')
    fi

    GRAINS[$KEY]=$VALUE
done

if [[ -f /etc/os-release-ec2 ]]; then
    # Use sub-shell, don't pollute current environment.
    GRAINS['source_ami_id']=$(source /etc/os-release-ec2; echo $BUILDER_SOURCE_AMI)
fi

cat <<EOF | sed -e '/^$/d' | tee -a /etc/salt/grains
ec2:
$(for k in ${!GRAINS[@]}; do
    printf "%4s%s: %s\n" "" "$k" "${GRAINS[$k]}";
  done)
EOF

# Add version grain about Docker and/or Docker Compose (if present).
if [[ $DOCKER == 'yes' ]]; then
    DOCKER_VERSION=$(docker --version 2>/dev/null | awk '{ print $3 }' | tr -d ',')
    cat <<EOF | tee -a /etc/salt/grains
docker:
$(printf "%4sversion: %s" "" "$DOCKER_VERSION")
EOF

    if docker-compose --version &>/dev/null; then
        COMPOSE_VERSION=$(docker-compose --version 2>/dev/null | awk '{ print $2 }')
    cat <<EOF | tee -a /etc/salt/grains
docker_compose:
$(printf "%4sversion: %s" "" "$COMPOSE_VERSION")
EOF
    fi
fi

# Automatically update *this* instance "Name" tag
# to match chosen convention and for convenience,
# plus install a set of utility scripts to provide
# automatic addition of DNS entries to the relevant
# zone in Route53.
if [[ $EC2_AUTO_SCALING_GROUP == 'yes' ]]; then
    # Extract the region name.
    REGION=$(
        curl -s ${EC2_METADATA_URL}/placement/availability-zone | \
            sed -e 's/\w$//'
    )

    # Update the tag (previously set by
    # the virtue of inheritance from the
    # Auto Scaling Group.
    if aws --version &>/dev/null; then
        # Try to set the "Name" tag few times,
        # as this is not very reliable, sadly.
        for n in {1..5}; do
            # This initially tends to be empty.
            # It takes a bit of time for Amazon
            # services to propagate information.
            INSTANCE_NAME_TAG=$(
                aws --color=off ec2 describe-tags \
                    --query 'Tags[*].Value' \
                    --filters "Name=resource-id,Values=${INSTANCE_ID}" 'Name=key,Values=Name' \
                    --region $REGION --output text 2>/dev/null
            )

            [[ $INSTANCE_NAME_TAG == $FQDN ]] && break

            # Add and/or update the "Name" tag.
            aws ec2 create-tags \
                --tag "Key=Name,Value=${FQDN}" \
                --resources $INSTANCE_ID --region $REGION

            # Allow for some grace time ...
            sleep $(( 1 * $n ))
        done

        # Make sure to extract ID, as it might
        # be provided as the Amazon Resource
        # Name (ARN) and only ID is needed.
        HOSTED_ZONE_ID=${HOSTED_ZONE_ID##*/}

        # Store details are will absolutely
        # never change, but leave out the
        # IP and instance "Name" tag to
        # by resolved on-the-fly later.
        cat <<EOF | tee /etc/default/route53
TTL=300
HOSTED_ZONE_ID=${HOSTED_ZONE_ID}
INSTANCE_ID=${INSTANCE_ID}
REGION=${REGION}
EOF

        chown root:root /etc/default/route53
        chmod 644 /etc/default/route53
    fi
fi

# Modern version of ZeroMQ supports TCP Keep Alive,
# thus we explicitly enable it on Linux (disabled by
# default).
sed -i -e \
    's/.*tcp_keepalive:.*/tcp_keepalive: True/g' \
    /etc/salt/minion

sed -i -e \
    's/.*tcp_keepalive_idle:.*/tcp_keepalive_idle: 300/g' \
    /etc/salt/minion

chown -R root:root /etc/salt

find /etc/salt -type f | xargs -i'{}' chmod 644 '{}'
find /etc/salt -type d | xargs -i'{}' chmod 755 '{}'

# More restrictive permissions for certificates.
find /etc/salt/pki -type f | xargs -i'{}' chmod 600 '{}'
find /etc/salt/pki -type d | xargs -i'{}' chmod 700 '{}'



# Check whether there is a connectivity with the
# Salt Master by checking both ports on which it
# should listen (4505 and 4506).
MASTER_RESPONSES=()

# Wait total of 10 seconds.
for n in {1..10}; do
    for p in 4505 4506; do
        if nc -z -w 3 $SALT_MASTER_IP $p &> /dev/null; then
            MASTER_RESPONSES+=( $p )
        fi
    done

    (( ${#MASTER_RESPONSES[@]} >= 2 )) && break

    # Allow for some grace time ...
    sleep $(( 1 * $n ))
done

# Do not attempt to run the Salt highstate
# if the Salt Master is not responding.
if (( ${#MASTER_RESPONSES[@]} < 2 )); then
    echo "Unable to contact the Salt Master at $SALT_MASTER_IP, aborting..."
    exit 1
fi

# Empty output: `local: {}`
# Salt tools return no valid exit codes, thus we
# rely on the checksum of the empty output (above)
# for the comparison with an actual output later.
readonly EMPTY='d42e8de6c82135965ef26586786c4565'

# Check if we can query ourselves? We publish a job onto the queue from
# *this* node to request its ID back from the Salt Master. Provided, that
# the authentication and connection is established and working, then we
# should get a non-empty set of results back (a JSON document). Otherwise,
# try to re-run Salt highstate again to trigger Minion key registration, etc.
echo $HOSTNAME > /etc/salt/minion_id
OUTPUT=$(salt-call -l quiet --output=txt publish.publish $(cat /etc/salt/minion_id) grains.get id)
if [[ $(echo $OUTPUT | md5sum | awk '{ print $1 }') == $EMPTY ]]; then
    # Try a little nudge ...
    service salt-minion restart || true
    # Attempt to run second time ...
    salt-call -l debug state.highstate || true
fi


sleep 5
if [[ $SALT_MASTER == 'yes' ]]; then
    # Clean-up keys registered with bad host name.
    salt-key -L | egrep '^(ec2|ip|i)\-' | \
        xargs salt-key -y -d &>/dev/null || true

    service salt-master restart
    service salt-minion restart
fi
# Add a lock file to prevent subsequent runs.
cat <<EOF | tee $LOCK_FILE
TIMESTAMP=$TIMESTAMP
DATE="$(date -d @${TIMESTAMP})"
EOF

chown root:root $LOCK_FILE
chmod 644 $LOCK_FILE
