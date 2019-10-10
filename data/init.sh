#!/bin/bash -x

# awscli is not installed by default on Ubuntu.
OS_RELEASE=$(grep "^NAME" /etc/os-release | sed -e 's/NAME="//' -e 's/"$//')
SSM_AGENT_SERVICE_NAME=""
case "$OS_RELEASE" in
  Ubuntu|Debian*)
    apt-get update
    apt-get -y install awscli
    SSM_AGENT_SERVICE_NAME="snap.amazon-ssm-agent.amazon-ssm-agent.service"
    ;;
  "Red Hat"*|CentOS*)
    yum update
    yum -y install awscli
    SSM_AGENT_SERVICE_NAME="amazon-ssm-agent.service"
    ;;
  "Amazon Linux"*)
    yum update
    SSM_AGENT_SERVICE_NAME="amazon-ssm-agent.service"
    ;;
  *)
    echo "Don't know what to do with $OS_RELEASE."
    exit 0
    ;;
esac

# Discover default network interface
dni=$(route | grep '^default' | grep -o '[^ ]*$')
iface_prefix=$(echo "$dni" | sed 's/[0-9]$//')

# Determine the region
# https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-instance-metadata.html
AWS_DEFAULT_REGION=$(curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone | sed 's/[a-z]$//')
export AWS_DEFAULT_REGION

# Attach the ENI
instance_id=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
# this needs awscli to be installed
aws ec2 attach-network-interface \
    --instance-id "$instance_id" \
    --device-index 1 \
    --network-interface-id "${eni_id}"

# Wait for network initialization
sleep 10

cd /proc/sys/net/ipv4/conf || exit
new_iface=$(ls -d1 "$iface_prefix"* | grep -v "$dni")

# Enable IP forwarding and NAT
# TODO: figure out which where the new interface attached. it's not always eth1.
sysctl -q -w net.ipv4.ip_forward=1
sysctl -q -w net.ipv4.conf.${new_iface}.send_redirects=0
# doesn't seem to do much.
iptables -t nat -A POSTROUTING -o "$new_iface" -j MASQUERADE

# Switch the default route to eth1
ip route del default dev "$dni"

# Waiting for network connection
curl --retry 10 http://www.example.com

# Restart the SSM agent
systemctl restart "$SSM_AGENT_SERVICE_NAME"

# Run the extra script if set
${extra_user_data}
