#!/bin/bash
#
# Little helper to setup a user namespace
# Assumes git and jq have already been installed,
# and that the $USER is 'ubuntu' with sudo with
# a standard k8s provisoiner home directory organization.
#

set -e

if [[ -z "$GEN3_NOPROXY" ]]; then
  export http_proxy=${http_proxy:-'http://cloud-proxy.internal.io:3128'}
  export https_proxy=${https_proxy:-'http://cloud-proxy.internal.io:3128'}
  export no_proxy=${no_proxy:-'localhost,127.0.0.1,169.254.169.254,.internal.io'}
fi

vpc_name=${vpc_name:-$1}
namespace=${namespace:-$2}
if [[ -z "$vpc_name" || -z "$namespace" || (! "$namespace" =~ ^[a-z][a-z0-9]*$) ]]; then
  echo "Usage: bash kube-dev-namespace.sh vpc_name namespace, namespace is alphanumeric"
  exit 1
fi

for checkDir in ~/"${vpc_name}" ~/"${vpc_name}_output"; do
  if [[ ! -d "$checkDir" ]]; then
    echo "ERROR: $checkDir does not exist"
    exit 1
  fi
done

if [[ $USER != "ubuntu" ]]; then
  echo "Run as the 'ubuntu' user on the k8s provisioner"
  exit 1
fi

# prepare a copy of the /home/ubuntu k8s workspace
if ! grep "^$namespace" /etc/passwd > /dev/null 2>&1; then
  sudo useradd -m -s /bin/bash -G ubuntu $namespace
fi
sudo chgrp ubuntu /home/$namespace
sudo chmod g+rwx /home/$namespace
sudo chgrp ubuntu /home/$namespace/.bashrc
sudo chmod g+rwx /home/$namespace/.bashrc
mkdir -p /home/$namespace/${vpc_name}
mkdir -p /home/$namespace/${vpc_name}_output
cd /home/$namespace

# setup ~/.ssh
mkdir -p /home/$namespace/.ssh
cp ~/.ssh/authorized_keys /home/$namespace/.ssh

# setup ~/cloud-automation
if [[ ! -d ./cloud-automation ]]; then
  git clone https://github.com/uc-cdis/cloud-automation.git
fi

# setup ~/vpc_name
for name in 00configmap.yaml apis_configs kubeconfig; do
  cp -r ~/${vpc_name}/$name /home/$namespace/${vpc_name}/$name
done

ln -sf /home/$namespace/cloud-automation/kube/services /home/$namespace/$vpc_name/services

# setup ~/vpc_name/credentials and kubeconfig
cd /home/$namespace/${vpc_name}
mkdir -p credentials
for name in ca.pem ca-key.pem admin.pem admin-key.pem; do
  cp ~/${vpc_name}/credentials/$name credentials/
done
sed -i.bak "s/default/$namespace/" kubeconfig
export KUBECONFIG="/home/$namespace/${vpc_name}/kubeconfig"

echo "Testing new KUBECONFIG at $KUBECONFIG"
# setup the namespace
if ! kubectl get namespace $namespace > /dev/null 2>&1; then
  kubectl create namespace $namespace
fi
# do not re-create the databases
for name in .rendered_fence_db .rendered_gdcapi_db; do
  touch "/home/$namespace/${vpc_name}/$name"
done

# setup ~/${vpc_name}_output/
cp ~/${vpc_name}_output/creds.json /home/$namespace/${vpc_name}_output/creds.json

# update creds.json
oldHostname=$(jq -r '.fence.hostname' < /home/$namespace/${vpc_name}_output/creds.json)
newHostname=$(echo $oldHostname | sed "s/^[a-zA-Z0-1]*/$namespace/")
sed -i.bak "s/$oldHostname/$newHostname/g" /home/$namespace/${vpc_name}_output/creds.json
sed -i.bak "s/$oldHostname/$newHostname/g; s/namespace:.*//" /home/$namespace/${vpc_name}/00configmap.yaml

# setup ~/.bashrc
if ! grep kubes.sh /home/${namespace}/.bashrc > /dev/null 2>&1; then
  echo "Adding variables to .bashrc"
  cat >> /home/${namespace}/.bashrc << EOF
export http_proxy=http://cloud-proxy.internal.io:3128
export https_proxy=http://cloud-proxy.internal.io:3128
export no_proxy='localhost,127.0.0.1,169.254.169.254,.internal.io'

export KUBECONFIG=~/${vpc_name}/kubeconfig

if [ -f ~/cloud-automation/kube/kubes.sh ]; then
    . ~/cloud-automation/kube/kubes.sh
fi
EOF
fi

# reset ownership
sudo chown -R "${namespace}:" /home/$namespace
sudo chown -R "${namespace}:" /home/$namespace/.ssh
sudo chmod -R 0700 /home/$namespace/.ssh

echo "The $namespace user is ready to login and run ~/cloud-automation/tf_files/configs/kube-services-body.sh $vpc_name"