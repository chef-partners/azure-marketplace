#! /bin/sh

# Install Prerequisites
apt-get update -y && sudo apt-get upgrade -y
apt-get install lvm2 xfsprogs sysstat atop jq zip -y

# Decode Parameters
VARS=`echo $2 | tee args_b64 | base64 --decode | tee args | jq -r '. | keys[] as $k | "\($k)=\"\(.[$k])\""'`
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
mkdir -p "${STARTERKITLOCATION}/extras"
mkdir -p "${STARTERKITLOCATION}/.chef"

CS_PASSWORD=`awk '/password/{print $3}' /root/automate-credentials.toml`
chef-server-ctl user-create admin Chef Admin nobody@example.com ${CS_PASSWORD} --filename "${STARTERKITLOCATION}/.chef/admin.pem"
chef-server-ctl grant-server-admin-permissions admin
chef-server-ctl org-create "${CHEFORG}" "${CHEFORGDESCRIPTION}" --association-user admin --filename "${STARTERKITLOCATION}/.chef/validation.pem"

# Create zip file
#

# Define some variables to be used in the configuration files
automate_url="https://${FQDN}"
chef_server_url="https://${FQDN}/organizations/${CHEFORG}"

# Create the knife.rb file
cat <<- EOF > "${STARTERKITLOCATION}/.chef/knife.rb"
current_dir = ::File.dirname(__FILE__)
log_level                 :info
log_location              \$stdout
node_name                 "admin"
client_key                ::File.join(current_dir, "admin.key")
validation_client_name    "${CHEFORG}-validator"
validation_key            ::File.join(current_dir, "validator.pem")
chef_server_url           "${chef_server_url}"
cookbook_path             [::File.join(current_dir, "../cookbooks")]
EOF

# Create the credentials file
cat <<- EOF > "${STARTERKITLOCATION}/credentials.txt"
Chef Server URL: ${chef_server_url}
User username: admin
User password: ${CS_PASSWORD}

Automate URL: ${automate_url}
Automate admin username: admin
Automate admin password: ${CS_PASSWORD}
EOF

# Zip up the Starter Kit location directory
cwd=$PWD
zip_filename="/home/${USERNAME}/starterkit-${CHEFORG}.zip"
cd $STARTERKITLOCATION
zip -r $zip_filename .
cd $cwd

# Upload zip file to Storage container
#

# get details about the zip file to upload
filename=$(basename ${zip_filename})
file_length=$(wc --bytes ${zip_filename} | awk '{ print $1 }')
file_type=$(file --mime-type -b ${zip_filename})
file_md5=$(md5sum -b ${zip_filename} | awk '{ print $1 }')

container_name="starterkits"

# Define values that are required for the headers
request_method="PUT"
request_date=$(TZ=GMT LC_ALL=en_US.utf8 date "+%a, %d %h %Y %H:%M:%S %Z")

# HTTP Request headers
x_ms_date="x-ms-date:${request_date}"
x_ms_version="x-ms-version:2019-02-02"
x_ms_blob_type="x-ms-blob-type:BlockBlob"

# Build the signature string
canonicalized_headers="${x_ms_blob_type}\n${x_ms_date}\n${x_ms_version}"
canonicalized_resource="/${SANAME}/${container_name}/${filename}"

#StringToSign = VERB + "\n" +
#               Content-Encoding + "\n" +
#               Content-Language + "\n" +
#               Content-Length + "\n" +
#               Content-MD5 + "\n" +
#               Content-Type + "\n" +
#               Date + "\n" +
#               If-Modified-Since + "\n" +
#               If-Match + "\n" +
#               If-None-Match + "\n" +
#               If-Unmodified-Since + "\n" +
#               Range + "\n" +
#               CanonicalizedHeaders +
#               CanonicalizedResource;
string_to_sign="${request_method}\n\n\n${file_length}\n\n${file_type}\n\n\n\n\n\n\n${canonicalized_headers}\n${canonicalized_resource}"

# Decode the Base64 encoded access key, convert to Hex.
decoded_hex_key="$(echo -n $SAACCESSKEY | base64 -d -w0 | xxd -p -c256)"

# Create the HMAC signature for the Authorization header
signature=$(printf "$string_to_sign" | openssl dgst -sha256 -mac HMAC -macopt "hexkey:$decoded_hex_key" -binary |  base64 -w0)

# Create the authorization header
authorization_header="Authorization: SharedKey $SANAME:$signature"

# Build the url that is to be used
url=$(printf "https://%s.blob.core.windows.net/%s/%s" $SANAME $container_name $filename)

curl -X $request_method \
     -T $zip_filename \
     -H "${x_ms_date}" \
     -H "${x_ms_version}" \
     -H "${x_ms_blob_type}" \
     -H "${authorization_header}" \
     -H "Content-Type: ${file_type}" \
     $url