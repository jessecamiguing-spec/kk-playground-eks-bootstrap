#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# EKS cluster bootstrap for KodeKloud playground (resource-capped account)
# ---------------------------------------------------------------------------

CLUSTER_ROLE_NAME="eksClusterRole"
CLUSTER_ROLE_POLICY_ARN="arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
KUBERNETES_VERSION="1.35"
NODEGROUP_TEMPLATE_URL="https://s3.us-west-2.amazonaws.com/amazon-eks/cloudformation/2025-11-26/amazon-eks-nodegroup.yaml"
NODE_DESIRED_COUNT=3
NODE_JOIN_TIMEOUT_SECONDS=300
NODE_JOIN_POLL_INTERVAL_SECONDS=15
CLUSTER_NAME=""

create_cluster_role() {
  echo "==> Creating IAM role: ${CLUSTER_ROLE_NAME}"

  if aws iam get-role --role-name "${CLUSTER_ROLE_NAME}" >/dev/null 2>&1; then
    echo "    Role ${CLUSTER_ROLE_NAME} already exists, skipping creation."
  else
    aws iam create-role \
      --role-name "${CLUSTER_ROLE_NAME}" \
      --assume-role-policy-document '{
        "Version": "2012-10-17",
        "Statement": [
          {
            "Effect": "Allow",
            "Principal": {
              "Service": "eks.amazonaws.com"
            },
            "Action": "sts:AssumeRole"
          }
        ]
      }' >/dev/null
    echo "    Role ${CLUSTER_ROLE_NAME} created."
  fi

  aws iam attach-role-policy \
    --role-name "${CLUSTER_ROLE_NAME}" \
    --policy-arn "${CLUSTER_ROLE_POLICY_ARN}"
  echo "    Attached ${CLUSTER_ROLE_POLICY_ARN}."
}

prompt_cluster_name() {
  read -rp "Enter EKS cluster name: " CLUSTER_NAME
  if [[ -z "${CLUSTER_NAME}" ]]; then
    echo "Cluster name cannot be empty." >&2
    exit 1
  fi
}

get_cluster_role_arn() {
  aws iam get-role --role-name "${CLUSTER_ROLE_NAME}" --query 'Role.Arn' --output text
}

get_default_vpc_id() {
  local vpc_id
  vpc_id=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)

  if [[ -z "${vpc_id}" || "${vpc_id}" == "None" ]]; then
    echo "No default VPC found in this account/region." >&2
    exit 1
  fi

  echo "${vpc_id}"
}

get_subnet_ids_for_vpc() {
  local vpc_id="$1"
  # us-east-1e cannot host EKS control-plane instances (permanent AWS limitation).
  aws ec2 describe-subnets \
    --filters Name=vpc-id,Values="${vpc_id}" \
    --query "Subnets[?AvailabilityZone!='us-east-1e'].SubnetId" \
    --output text | tr '\t' ','
}

create_key_pair() {
  echo "==> Creating EC2 key pair: ${CLUSTER_NAME}"

  local key_file="${CLUSTER_NAME}.pem"

  if aws ec2 describe-key-pairs --key-names "${CLUSTER_NAME}" >/dev/null 2>&1; then
    echo "    Key pair ${CLUSTER_NAME} already exists, skipping creation (private key not re-downloadable)."
    return
  fi

  aws ec2 create-key-pair \
    --key-name "${CLUSTER_NAME}" \
    --key-type rsa \
    --key-format pem \
    --query 'KeyMaterial' \
    --output text > "${key_file}"

  chmod 400 "${key_file}"
  echo "    Key pair ${CLUSTER_NAME} created. Private key saved to ${key_file}"
}

wait_with_spinner() {
  local message="$1"
  shift

  "$@" &
  local pid=$!
  local spin='|/-\'
  local i=0
  local start_ts=${SECONDS}

  while kill -0 "${pid}" 2>/dev/null; do
    local frame="${spin:i%${#spin}:1}"
    i=$((i + 1))
    printf "\r    %s %s (%ds elapsed)  " "${frame}" "${message}" "$((SECONDS - start_ts))"
    sleep 0.2
  done

  local status=0
  wait "${pid}" || status=$?

  printf "\r    %s (%ds)                  \n" "${message}" "$((SECONDS - start_ts))"
  return "${status}"
}

create_cluster() {
  echo "==> Creating EKS cluster: ${CLUSTER_NAME}"

  if aws eks describe-cluster --name "${CLUSTER_NAME}" >/dev/null 2>&1; then
    echo "    Cluster ${CLUSTER_NAME} already exists, skipping creation."
  else
    local role_arn subnet_ids
    role_arn=$(get_cluster_role_arn)
    subnet_ids=$(get_subnet_ids_for_vpc "$(get_default_vpc_id)")

    aws eks create-cluster \
      --name "${CLUSTER_NAME}" \
      --kubernetes-version "${KUBERNETES_VERSION}" \
      --role-arn "${role_arn}" \
      --resources-vpc-config "subnetIds=${subnet_ids}" \
      --access-config authenticationMode=API_AND_CONFIG_MAP >/dev/null

    echo "    Cluster creation initiated."
  fi

  wait_with_spinner "Waiting for cluster ${CLUSTER_NAME} to become ACTIVE" \
    aws eks wait cluster-active --name "${CLUSTER_NAME}"
  echo "    Cluster ${CLUSTER_NAME} is ACTIVE."
}

get_cluster_security_group() {
  aws eks describe-cluster --name "${CLUSTER_NAME}" --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' --output text
}

get_cluster_endpoint() {
  aws eks describe-cluster --name "${CLUSTER_NAME}" --query 'cluster.endpoint' --output text
}

get_cluster_certificate_authority() {
  aws eks describe-cluster --name "${CLUSTER_NAME}" --query 'cluster.certificateAuthority.data' --output text
}

get_cluster_service_cidr() {
  aws eks describe-cluster --name "${CLUSTER_NAME}" --query 'cluster.kubernetesNetworkConfig.serviceIpv4Cidr' --output text
}

deploy_node_group_stack() {
  echo "==> Deploying node group CloudFormation stack: ${CLUSTER_NAME}"

  if aws cloudformation describe-stacks --stack-name "${CLUSTER_NAME}" >/dev/null 2>&1; then
    echo "    Stack ${CLUSTER_NAME} already exists, skipping creation."
    return
  fi

  local vpc_id subnet_ids control_plane_sg api_endpoint ca_data service_cidr
  vpc_id=$(get_default_vpc_id)
  subnet_ids=$(get_subnet_ids_for_vpc "${vpc_id}")
  control_plane_sg=$(get_cluster_security_group)
  api_endpoint=$(get_cluster_endpoint)
  ca_data=$(get_cluster_certificate_authority)
  service_cidr=$(get_cluster_service_cidr)

  aws cloudformation create-stack \
    --stack-name "${CLUSTER_NAME}" \
    --template-url "${NODEGROUP_TEMPLATE_URL}" \
    --capabilities CAPABILITY_IAM \
    --parameters "$(cat <<PARAMS
[
  {"ParameterKey": "ClusterName", "ParameterValue": "${CLUSTER_NAME}"},
  {"ParameterKey": "ClusterControlPlaneSecurityGroup", "ParameterValue": "${control_plane_sg}"},
  {"ParameterKey": "AuthenticationMode", "ParameterValue": "EKS API and ConfigMap"},
  {"ParameterKey": "ApiServerEndpoint", "ParameterValue": "${api_endpoint}"},
  {"ParameterKey": "CertificateAuthorityData", "ParameterValue": "${ca_data}"},
  {"ParameterKey": "ServiceCidr", "ParameterValue": "${service_cidr}"},
  {"ParameterKey": "NodeGroupName", "ParameterValue": "${CLUSTER_NAME}"},
  {"ParameterKey": "NodeImageIdSSMParam", "ParameterValue": "/aws/service/eks/optimized-ami/${KUBERNETES_VERSION}/amazon-linux-2023/x86_64/standard/recommended/image_id"},
  {"ParameterKey": "NodeAutoScalingGroupMinSize", "ParameterValue": "1"},
  {"ParameterKey": "NodeAutoScalingGroupDesiredCapacity", "ParameterValue": "3"},
  {"ParameterKey": "NodeAutoScalingGroupMaxSize", "ParameterValue": "3"},
  {"ParameterKey": "NodeInstanceType", "ParameterValue": "t3.small"},
  {"ParameterKey": "KeyName", "ParameterValue": "${CLUSTER_NAME}"},
  {"ParameterKey": "VpcId", "ParameterValue": "${vpc_id}"},
  {"ParameterKey": "Subnets", "ParameterValue": "${subnet_ids}"}
]
PARAMS
)" \
    >/dev/null

  echo "    Stack creation initiated."
  wait_with_spinner "Waiting for CloudFormation stack ${CLUSTER_NAME} (CREATE_COMPLETE)" \
    aws cloudformation wait stack-create-complete --stack-name "${CLUSTER_NAME}"
  echo "    Stack ${CLUSTER_NAME} is CREATE_COMPLETE."
}

get_node_instance_role_arn() {
  aws cloudformation describe-stacks \
    --stack-name "${CLUSTER_NAME}" \
    --query "Stacks[0].Outputs[?OutputKey=='NodeInstanceRole'].OutputValue" \
    --output text
}

get_node_security_group_id() {
  aws cloudformation describe-stacks \
    --stack-name "${CLUSTER_NAME}" \
    --query "Stacks[0].Outputs[?OutputKey=='NodeSecurityGroup'].OutputValue" \
    --output text
}

enable_ssh_access() {
  echo "==> Enabling SSH access to worker nodes from this session's public IP"

  local node_sg my_ip
  node_sg=$(get_node_security_group_id)
  my_ip=$(curl -s https://checkip.amazonaws.com)

  if [[ -z "${my_ip}" ]]; then
    echo "    Could not determine public IP, skipping SSH ingress rule." >&2
    return
  fi

  if aws ec2 describe-security-groups --group-ids "${node_sg}" \
      --query "SecurityGroups[0].IpPermissions[?FromPort==\`22\`].IpRanges[?CidrIp=='${my_ip}/32']" \
      --output text | grep -q "${my_ip}"; then
    echo "    SSH already allowed from ${my_ip}."
    return
  fi

  aws ec2 authorize-security-group-ingress \
    --group-id "${node_sg}" \
    --protocol tcp --port 22 --cidr "${my_ip}/32" >/dev/null

  echo "    Allowed SSH (port 22) from ${my_ip} to security group ${node_sg}."
}

configure_kubeconfig() {
  echo "==> Updating local kubeconfig for cluster: ${CLUSTER_NAME}"
  aws eks update-kubeconfig --name "${CLUSTER_NAME}"
}

join_worker_nodes() {
  echo "==> Joining worker nodes to cluster via aws-auth ConfigMap"

  local configmap_file="aws-auth-cm.yaml"
  local role_arn
  role_arn=$(get_node_instance_role_arn)

  if [[ -z "${role_arn}" || "${role_arn}" == "None" ]]; then
    echo "Could not find NodeInstanceRole output on stack ${CLUSTER_NAME}." >&2
    exit 1
  fi

  curl -O https://s3.us-west-2.amazonaws.com/amazon-eks/cloudformation/2020-10-29/aws-auth-cm.yaml

  sed -i.bak "s|rolearn:.*|rolearn: ${role_arn}|" "${configmap_file}"
  rm -f "${configmap_file}.bak"

  kubectl apply -f "${configmap_file}"
  echo "    aws-auth ConfigMap applied with NodeInstanceRole ${role_arn}."
}

verify_nodes_joined() {
  echo "==> Waiting for worker nodes to register as Ready (up to ${NODE_JOIN_TIMEOUT_SECONDS}s)"

  local elapsed=0
  local ready_count=0

  while (( elapsed < NODE_JOIN_TIMEOUT_SECONDS )); do
    ready_count=$(kubectl get nodes --no-headers 2>/dev/null | awk '$2 == "Ready"' | wc -l | tr -d ' ') || true
    ready_count=${ready_count:-0}

    if (( ready_count >= NODE_DESIRED_COUNT )); then
      break
    fi

    echo "    ${ready_count}/${NODE_DESIRED_COUNT} nodes Ready, waiting... (${elapsed}s elapsed)"
    sleep "${NODE_JOIN_POLL_INTERVAL_SECONDS}"
    elapsed=$((elapsed + NODE_JOIN_POLL_INTERVAL_SECONDS))
  done

  echo ""
  kubectl get nodes -o wide

  if (( ready_count == 0 )); then
    echo "No worker nodes joined the cluster within ${NODE_JOIN_TIMEOUT_SECONDS}s. Check the aws-auth ConfigMap and EC2 instance/system logs." >&2
    exit 1
  fi

  echo "    ${ready_count}/${NODE_DESIRED_COUNT} node(s) Ready."
}

label_nodes() {
  local nodes node i=1

  nodes=$(kubectl get nodes --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[*].metadata.name}')

  for node in ${nodes}; do
    kubectl label node "${node}" alias="Node-${i}" --overwrite >/dev/null
    i=$((i + 1))
  done
}

install_metrics_server() {
  kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

  if kubectl get deployment metrics-server -n kube-system \
      -o jsonpath='{.spec.template.spec.containers[0].args}' | grep -q -- '--kubelet-insecure-tls'; then
    echo "    --kubelet-insecure-tls already set."
  else
    # Self-managed node kubelet certs aren't signed for a hostname metrics-server trusts by default.
    kubectl patch deployment metrics-server -n kube-system --type='json' \
      -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
    echo "    Patched metrics-server with --kubelet-insecure-tls."
  fi

  echo "    Metrics Server installed."
}

deploy_sre_app() {
  echo "==> Creating namespace sre-app and deployment"

  kubectl create namespace sre-app --dry-run=client -o yaml | kubectl apply -f -

  cat <<'EOF' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: sre-app
  namespace: sre-app
spec:
  replicas: 2
  selector:
    matchLabels:
      app: sre-app
  template:
    metadata:
      labels:
        app: sre-app
    spec:
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
              - matchExpressions:
                  - key: nodetype
                    operator: In
                    values: ["sre", "production-failover"]
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100
              preference:
                matchExpressions:
                  - key: nodetype
                    operator: In
                    values: ["sre"]
      containers:
        - name: sre-app
          image: nginx
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 256m
              memory: 512Mi
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: sre-app
  namespace: sre-app
spec:
  maxUnavailable: 50%
  selector:
    matchLabels:
      app: sre-app
EOF
}

deploy_devops_app() {
  echo "==> Creating namespace devops-app and deployment"

  kubectl create namespace devops-app --dry-run=client -o yaml | kubectl apply -f -

  cat <<'EOF' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: devops-app
  namespace: devops-app
spec:
  replicas: 2
  selector:
    matchLabels:
      app: devops-app
  template:
    metadata:
      labels:
        app: devops-app
    spec:
      nodeSelector:
        nodetype: devops
      containers:
        - name: devops-app
          image: busybox
          command: ["sleep", "infinity"]
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 256m
              memory: 512Mi
EOF
}

break_kubelet() {
  local key_file="${CLUSTER_NAME}.pem"
  local instance_ids instance_id public_ip

  instance_ids=$(aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=${CLUSTER_NAME}-${CLUSTER_NAME}-Node" "Name=instance-state-name,Values=running" \
    --query 'Reservations[].Instances[].InstanceId' --output text)

  for instance_id in ${instance_ids}; do
    public_ip=$(aws ec2 describe-instances --instance-ids "${instance_id}" \
      --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)

    [[ -z "${public_ip}" || "${public_ip}" == "None" ]] && continue

    ssh -i "${key_file}" \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      -o ConnectTimeout=10 \
      -o BatchMode=yes \
      ec2-user@"${public_ip}" \
      "sudo systemctl stop kubelet" >/dev/null 2>&1 || true
  done
}

connect_via_ssm() {
  local instance_ids count instance_id

  instance_ids=$(aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=${CLUSTER_NAME}-${CLUSTER_NAME}-Node" "Name=instance-state-name,Values=running" \
    --query 'Reservations[].Instances[].InstanceId' --output text)

  if [[ -z "${instance_ids}" ]]; then
    echo "No running node instances found for cluster ${CLUSTER_NAME}." >&2
    exit 1
  fi

  count=$(wc -w <<< "${instance_ids}")

  if [[ "${count}" -eq 1 ]]; then
    instance_id="${instance_ids}"
  else
    echo "Multiple node instances found, pick one:"
    select instance_id in ${instance_ids}; do
      [[ -n "${instance_id}" ]] && break
    done
  fi

  echo "==> Connecting to ${instance_id} via SSM Session Manager"
  aws ssm start-session --target "${instance_id}"
}

connect_via_ssh() {
  local key_file="${CLUSTER_NAME}.pem"
  local instance_ids count instance_id public_ip

  enable_ssh_access

  instance_ids=$(aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=${CLUSTER_NAME}-${CLUSTER_NAME}-Node" "Name=instance-state-name,Values=running" \
    --query 'Reservations[].Instances[].InstanceId' --output text)

  if [[ -z "${instance_ids}" ]]; then
    echo "No running node instances found for cluster ${CLUSTER_NAME}." >&2
    exit 1
  fi

  count=$(wc -w <<< "${instance_ids}")

  if [[ "${count}" -eq 1 ]]; then
    instance_id="${instance_ids}"
  else
    echo "Multiple node instances found, pick one:"
    select instance_id in ${instance_ids}; do
      [[ -n "${instance_id}" ]] && break
    done
  fi

  public_ip=$(aws ec2 describe-instances --instance-ids "${instance_id}" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)

  echo "==> SSH to ${instance_id} (${public_ip})"
  ssh -i "${key_file}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ec2-user@"${public_ip}"
}

main() {
  create_cluster_role
  prompt_cluster_name
  create_key_pair
  create_cluster
  deploy_node_group_stack
  enable_ssh_access
  configure_kubeconfig
  join_worker_nodes
  verify_nodes_joined
  label_nodes
  install_metrics_server
  deploy_sre_app
  deploy_devops_app
  break_kubelet

  echo "==> sre-app and devops-app deployed."
}

if [[ "${1:-}" == "ssm" ]]; then
  prompt_cluster_name
  connect_via_ssm
  exit 0
fi

if [[ "${1:-}" == "ssh" ]]; then
  prompt_cluster_name
  connect_via_ssh
  exit 0
fi

main "$@"
