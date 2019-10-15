#! /bin/sh

# Install Prerequisites
apt-get update -y && sudo apt-get upgrade -y
apt-get install lvm2 xfsprogs sysstat atop jq -y

# Decode Parameters
VARS=`echo $2 | base64 --decode | jq -r '. | keys[] as $k | "\($k)=\"\(.[$k])\""'`
for VAR in "$VARS"; do eval "$VAR"; done

# Mount 2nd disk
pvcreate -f /dev/sdc
vgcreate chef /dev/sdc
lvcreate -n hab -l 100%FREE chef
mkfs.xfs /dev/chef/hab
mkdir -p /hab
echo '/dev/chef/hab /hab xfs defaults 0 0' >> /etc/fstab
mount -a

# Apply System Tuning and persist configuration
echo 'vm.max_map_count=262144' >> /etc/sysctl.conf
echo 'vm.dirty_expire_centisecs=20000' >> /etc/sysctl.conf
sysctl -p

# Install Chef Automate

# curl -s -H Metadata:true "http://169.254.169.254/metadata/instance/compute/tags?api-version=2018-10-01&format=text" | grep -oP '(?<=\bx-fqdn:)[^;]+' > /tmp/fqdn
# FQDN=`cat /tmp/fqdn`
# echo ${FQDN}

cd /root
curl https://packages.chef.io/files/current/latest/chef-automate-cli/chef-automate_linux_amd64.zip | gunzip - > chef-automate && chmod +x chef-automate
./chef-automate init-config

echo '[erchef.v1.sys.data_collector]' >> config.toml
echo 'enabled = false' >> config.toml

/root/chef-automate deploy --fqdn ${FQDN} --product chef-server --product automate --accept-terms-and-mlsa

# Create first Chef Server admin user and first Chef Server org
STARTERKITLOCATION="/home/${USERNAME}/${CHEFORG}/starter-kit"
mkdir -p "${STARTERKITLOCATION}"

CS_PASSWORD=`awk '/password/{print $3}' /root/automate-credentials.toml`
chef-server-ctl user-create admin Chef Admin nobody@example.com ${CS_PASSWORD} --filename "${STARTERKITLOCATION}/admin.pem"
chef-server-ctl grant-server-admin-permissions admin
chef-server-ctl org-create "${CHEFORG}" "${CHEFORGDESCRIPTION}" --association-user admin --filename "${STARTERKITLOCATION}/validation.pem"

# Create zip file
#
# TODO

# Upload zip file to Keyvaule
#
# TODO