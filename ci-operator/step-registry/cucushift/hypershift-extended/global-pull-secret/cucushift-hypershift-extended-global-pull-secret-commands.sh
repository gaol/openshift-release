#!/bin/bash
set -xeuo pipefail

if [[ ${DYNAMIC_GLOBAL_PULL_SECRET_ENABLED} == "false" ]]; then
  echo "SKIP global pull secret checking ....."
  exit 0
fi

if [[ -f "${SHARED_DIR}/proxy-conf.sh" ]]; then
    source "${SHARED_DIR}/proxy-conf.sh"
fi

HOSTEDCLUSTER_NAMESPACE="${HOSTEDCLUSTER_NAMESPACE:-clusters}"
HOSTEDCLUSTER_NAME=$(oc --kubeconfig "${SHARED_DIR}"/kubeconfig get hostedclusters -n "${HOSTEDCLUSTER_NAMESPACE}" -o jsonpath='{.items[0].metadata.name}')
platform=$(oc --kubeconfig "${SHARED_DIR}"/kubeconfig get hostedcluster "$HOSTEDCLUSTER_NAME" -n "$HOSTEDCLUSTER_NAMESPACE" --ignore-not-found -o=jsonpath='{.spec.platform.type}')
platform_lower=$(echo "$platform" | tr '[:upper:]' '[:lower:]')

# The pull secret name for the hosted cluster
CLUSTER_PULL_SECRET=$(oc --kubeconfig "${SHARED_DIR}"/kubeconfig get hostedcluster "${HOSTEDCLUSTER_NAME}" -n "${HOSTEDCLUSTER_NAMESPACE}" -o jsonpath='{.spec.pullSecret.name}')
mgmt_kubeconfig="${SHARED_DIR}/kubeconfig"

# Get hosted cluster endpoint
if [ ! -f "${SHARED_DIR}/nested_kubeconfig" ]; then
    exit 1
fi
export KUBECONFIG="${SHARED_DIR}/nested_kubeconfig"

# retry_until_success <retries> <sleep_time> <function_name> [args...]
# - retries       : max number of attempts
# - sleep_time    : seconds between attempts
# - func          : the function to be called or a sub shell call
function retry_until_success() {
    local retries="$1"
    local sleep_time="$2"
    shift 2   # drop retries and sleep_time
    for i in $(seq 1 "$retries"); do
        echo "Attempt $i/$retries: running $*"
        if "$@"; then
            echo "Success on attempt $i"
            return 0
        fi
        echo "Failed attempt $i, retrying in $sleep_time seconds..."
        sleep "$sleep_time"
    done
    echo "$* did not succeed after $retries attempts"
    return 1
}

function check_image_registry_pods_running() {
    pods=$(oc get pods -l app=${DS_NAME} -n ${DS_NAMESPACE} -o jsonpath='{.items[*].metadata.name}')
    for pod in $pods; do
        if ! oc get pod $pod -n ${DS_NAMESPACE} -o jsonpath='{.status.phase}'|grep Running; then
            return 1
        fi
    done
    return 0
}

# Check if the target auth exist in the node
# $1: the node name
# $2: the registry url in the /var/lib/kubelet/config.json
# $3: the expected auth encoded using base64(username:password)
function check_auth_exists_ps_node() {
  local node="$1"
  local registry="$2"
  local expected_auth="$3"
  echo "Checking the /var/lib/kubelet/config.json file in node $node for authentication information..."
  echo "Check if the Node: $node has globalps related labels"
  oc get node $node -o jsonpath='{.metadata.labels}'| jq | grep "globalps"
  secret_json=$(oc debug "node/$node" -q -- chroot /host cat /var/lib/kubelet/config.json)
  if [ -z "$secret_json" ]; then
    echo "config.json in node $node is empty"
    return 1
  fi
  verify_credentials_in_ps $secret_json $registry $expected_auth
}

# Check if the target auth does not exist in the node anymore
# node   : the node name
# auth   : the auth url in the /var/lib/kubelet/config.json
function check_auth_not_exists_ps_node() {
  ! check_auth_exists_ps_node "$@"
}

function delete_global_ps() {
  oc delete secret global-pull-secret -n kube-system 2>/dev/null
}

# Helper function to delete an image registry item out of a dockerconfigjson secret
# $1: secret name
# $2: namespace
# $3: kubeconfig path
# $4: registry URL
function delete_image_registry_from_pull_secret() {
  local secret_name="$1"
  local namespace="$2"
  local kubeconfig="$3"
  local registry="$4"
  # as long as the secret exits, delete the registry item
  if oc --kubeconfig $kubeconfig get secret $secret_name -n $namespace 2>/dev/null; then
    local auths updated_auths new_auths_b64
    auths="$(oc --kubeconfig $kubeconfig get secret $secret_name -n $namespace -o jsonpath='{.data.\.dockerconfigjson}'|base64 -d)"
    updated_auths="$(echo $auths | jq --arg registry $registry 'del(.auths[$registry])')"
    new_auths_b64="$(echo $updated_auths | jq -c '.' | base64 -w0)"
    oc --kubeconfig "$kubeconfig" patch secret "$secret_name" -n "$namespace" --type='merge' -p "{\"data\": {\".dockerconfigjson\": \"$new_auths_b64\"}}"
  fi
  return 0
}

# Helper function to get an existing registry(the first one) from a pull secret
# $1: secret name
# $2: namespace
# $3: kubeconfig path
function get_existing_registry_from_secret() {
  local secret_name="$1"
  local namespace="$2"
  local kubeconfig="$3"
  # Get the pull secret
  local ps
  ps=$(oc --kubeconfig "$kubeconfig" get secret "$secret_name" -n "$namespace" -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d)
  if echo "$ps" | jq -e '.auths | type == "object" and (length > 0)' >/dev/null 2>&1; then
    # ps is not empty
    local registry
    registry=$(echo "$ps" | jq -r '.auths | to_entries | .[0]' 2>/dev/null)
    if [ -n "$registry" ] && [ "$registry" != "null" ]; then
      echo "$registry"
      return 0
    fi
    return 1
  fi
  return 1
}

# Helper function to create/update a pull secret with specific credentials
# $1: secret name
# $2: namespace
# $3: kubeconfig path
# $4: registry URL
# $5: username
# $6: password
function create_or_update_pull_secret() {
  local secret_name="$1"
  local namespace="$2"
  local kubeconfig="$3"
  local registry="$4"
  local username="$5"
  local password="$6"

  # Create base64 encoded auth
  local new_auth_base64
  new_auth_base64=$(echo -n "$username:$password" | base64)
  local new_auth="{\"auth\": \"$new_auth_base64\"}"

  # Create or update the secret
  set +x
  if oc --kubeconfig "$kubeconfig" get secret "$secret_name" -n "$namespace" &>/dev/null; then
    # secret exists, patch to add the new registry pull secret
    local auths new_auths new_auths_b64
    auths="$(oc --kubeconfig $kubeconfig get secret $secret_name -n $namespace -o jsonpath='{.data.\.dockerconfigjson}'|base64 -d)"
    new_auths="$(echo $auths | jq --arg registry $registry --argjson new_auth "$new_auth"  '.auths[$registry] = $new_auth')"
    new_auths_b64="$(echo $new_auths | jq -c '.' | base64 -w0)"
    oc --kubeconfig "$kubeconfig" patch secret "$secret_name" -n "$namespace" --type='merge' -p "{\"data\": {\".dockerconfigjson\": \"$new_auths_b64\"}}"
  else
    # secret does not exist, create it
    local auths
    auths=$(echo "{}" | jq --arg registry "$registry" --argjson new_auth "$new_auth" '.auths[$registry] = $new_auth')
    oc --kubeconfig "$kubeconfig" create secret generic "$secret_name" -n "$namespace" --from-literal=.dockerconfigjson="$auths"
  fi
}

# Helper function to verify credentials in global-pull-secret
# $1: the whole pull secret data that has been decoded to json format
# $2: registry URL
# $3: expected auth encoded using base64(username:password)
function verify_credentials_in_ps() {
  local whole_ps="$1"
  local registry="$2"
  local expected_auth="$3"
  local whole_auth_encoded
  whole_auth_encoded=$(echo "$whole_ps" | jq -r --arg reg "$registry" '.auths[$reg].auth' 2>/dev/null)
  if [ -n "$whole_auth_encoded" ] && [ "$whole_auth_encoded" != "null" ]; then
    if [ "$whole_auth_encoded" != "$expected_auth" ]; then
      echo "authentication should be: $expected_auth, but got: $whole_auth_encoded"
      return 1
    fi
    echo "Good, all data are expected in the pull secret"
    return 0
  fi
  echo "$registry is not found in the pull secret"
  return 1
}

# Helper function to encode auth using base64
# $1: username
# $2: password
function base64_encode_auth() {
  local username="$1"
  local password="$2"
  echo -n "$username:$password" | base64
}

# Helper function to get all replace nodes from the hosted cluster
# Returns space-separated list of node names from NodePools with Replace upgrade type
function get_replace_nodes() {
  # Get NodePools with Replace upgrade type from management cluster
  local replace_nodepools
  replace_nodepools=$(oc --kubeconfig "${SHARED_DIR}/kubeconfig" get nodepool -n "$HOSTEDCLUSTER_NAMESPACE" -o json | jq -r '.items[] | select(.spec.management.upgradeType == "Replace") | .metadata.name')

  # Get all nodes from the Replace NodePools from hosted cluster
  local all_replace_nodes=""
  for np in $replace_nodepools; do
    local nodes
    nodes=$(oc get nodes -l "hypershift.openshift.io/nodePool=$np" -o jsonpath='{.items[*].metadata.name}')
    if [ -n "$all_replace_nodes" ]; then
      all_replace_nodes="$all_replace_nodes $nodes"
    else
      all_replace_nodes="$nodes"
    fi
  done

  echo "$all_replace_nodes"
}

# Helper function to verify all auths from original pull-secret exist in a node
# $1: node name to check
function verify_all_original_pull_secret_auths_in_node() {
  local node="$1"
  echo "Verifying all auths from original pull-secret exist in node: $node"

  # Get all registry:auth pairs from pull-secret in openshift-config
  local pull_secret_data
  pull_secret_data=$(oc get secret pull-secret -n openshift-config -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d)

  # Extract all registries
  local registries
  registries=$(echo "$pull_secret_data" | jq -r '.auths | keys[]')

  # Read config.json from the node once (outside the registry loop for efficiency)
  local node_config_json
  node_config_json=$(oc debug "node/$node" -q -- chroot /host cat /var/lib/kubelet/config.json)
  if [ -z "$node_config_json" ]; then
    echo "config.json in node $node is empty"
    return 1
  fi

  # For each registry, verify it exists in the node's config.json
  for registry in $registries; do
    local expected_auth
    expected_auth=$(echo "$pull_secret_data" | jq -r --arg reg "$registry" '.auths[$reg].auth')
    verify_credentials_in_ps "$node_config_json" "$registry" "$expected_auth"
  done

  echo "All auths from original pull-secret verified in node: $node"
}

# Helper function to verify credentials in global-pull-secret
# $1: registry URL
# $2: expected auth encoded using base64(username:password)
function verify_credentials_in_global_ps() {
  local registry="$1"
  local expected_auth="$2"
  # Get the credentials from global-pull-secret
  local global_ps
  global_ps=$(oc get secret global-pull-secret -n kube-system -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d)
  if [ -z "$global_ps" ]; then
    echo "global-pull-secret is empty"
    return 1
  fi
  verify_credentials_in_ps $global_ps $registry $expected_auth
}


function prepare_image_registry() {
  # make sure the namespace exists and clean
  if oc get namespace "$DS_NAMESPACE" &>/dev/null; then
    oc delete namespace "$DS_NAMESPACE" &>/dev/null
  fi
  oc create namespace "${DS_NAMESPACE}"
  cat <<EOF | oc apply -f -
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: "${DS_NAME}"
  namespace: ${DS_NAMESPACE}
spec:
  selector:
    matchLabels:
      app: "${DS_NAME}"
  template:
    metadata:
      labels:
        app: "${DS_NAME}"
    spec:
      terminationGracePeriodSeconds: 10
      containers:
        - name: "${DS_NAME}"
          image: ${IMAGE}
          command: ["sleep",  "30m"]
          imagePullPolicy: Always
EOF
}

nodes=$(get_replace_nodes)

# Test Case: Basic global pull secret functionality
# Tests authentication failure, secret creation, sync, update, and deletion
function test_basic_global_pull_secret() {
  if [ ! -f "$SHARED_DIR/image_registry.ini" ]; then
      echo "No image registry configured"
      exit 1
  fi

  DS_NAME="test-ds"
  DS_NAMESPACE="test-ds-namespace"
  IMAGE=$(cat "$SHARED_DIR/image_registry.ini" | grep "dst_image:" | cut -d ":" -f2- |tr -d " ")
  REG_USER=$(cat "$SHARED_DIR/image_registry.ini" | grep "username:" | cut -d ":" -f2- |tr -d " ")
  REG_PASS=$(cat "$SHARED_DIR/image_registry.ini" | grep "password:" | cut -d ":" -f2- |tr -d " ")
  REG_ROUTE=$(cat "$SHARED_DIR/image_registry.ini" | grep "route:" | cut -d ":" -f2- |tr -d " ")
  echo "=== Testing basic global pull secret functionality ==="

  # prepare image registry for the testing
  echo -e "Preparing image registry for the testing\n"
  prepare_image_registry

  # make sure the namespace is deleted at the end
  trap 'oc --kubeconfig "${SHARED_DIR}/nested_kubeconfig" delete namespace "$DS_NAMESPACE"' EXIT

  # make sure the set up is clean
  if oc get secret "additional-pull-secret" -n "kube-system" &>/dev/null; then
    oc delete secret "additional-pull-secret" -n "kube-system" &>/dev/null
  fi

  # Check that all pods have authentication failures
  pods=$(oc get pods -l app=${DS_NAME} -n ${DS_NAMESPACE} -o jsonpath='{.items[*].metadata.name}')
  for pod in $pods; do
    echo "Checking pod $pod for authentication failure message..."
    retry_until_success 10 5  bash -c "oc get event --ignore-not-found -n ${DS_NAMESPACE} --field-selector involvedObject.name=$pod,involvedObject.kind=Pod -ojsonpath='{range .items[?(@.reason==\"Failed\")]}{.message}{\"\n\"}{end}' 2>&1 | grep -q 'authentication required'"
  done
  echo "All pods have the expected authentication failure message."

  # create additional-pull-secret with reg auth, user, pass
  echo -e "Create additional-pull-secret with registry username and password\n"
  create_or_update_pull_secret "additional-pull-secret" "kube-system" "${SHARED_DIR}/nested_kubeconfig" "$REG_ROUTE" "$REG_USER" "$REG_PASS"

  reg_registry_auth=$(base64_encode_auth "$REG_USER" "$REG_PASS")
  # there is a global-pull-secret in kube-system now, which has the reg auth
  retry_until_success 10 5 bash -c "oc get --ignore-not-found secret global-pull-secret -n kube-system -o jsonpath='{.metadata.name}' | grep global-pull-secret"

  # all pods should work now
  retry_until_success 20 5 check_image_registry_pods_running

  set +x
  # check that the reg auth is in the global-pull-secret
  verify_credentials_in_global_ps "$REG_ROUTE" "$reg_registry_auth"

  # in all nodes, the /var/lib/kubelet/config.json file should contain reg auth
  # we only check the nodes which has the label set.
  for node in $nodes; do
    check_auth_exists_ps_node "$node" "$REG_ROUTE" "$reg_registry_auth"
  done
  set -x

  # add a new auth into additional-pull-secret
  new_auth_test_url="test-new-auth-global-ps"
  new_auth_test_user="global-ps-user"
  new_auth_test_pass="global-ps-pass"

  new_registry_auth=$(base64_encode_auth "$new_auth_test_user" "$new_auth_test_pass")
  create_or_update_pull_secret "additional-pull-secret" "kube-system" "${SHARED_DIR}/nested_kubeconfig" "$new_auth_test_url" "$new_auth_test_user" "$new_auth_test_pass"

  set +x
  # the new auth will be synced to global-pull-secret
  retry_until_success 10 5 verify_credentials_in_global_ps "$new_auth_test_url" "$new_registry_auth"

  # the new auth will be synced to all nodes
  for node in $nodes; do
    retry_until_success 10 5 check_auth_exists_ps_node "$node" "$new_auth_test_url" "$new_registry_auth"
  done

  # update the registry ${new_auth_test_url} with new user/pass in the additional-pull-secret
  set -x
  new_auth_test_user_2="global-ps-user-2"
  new_auth_test_pass_2="global-ps-pass-2"

  new_registry_auth_2=$(base64_encode_auth "$new_auth_test_user_2" "$new_auth_test_pass_2")
  create_or_update_pull_secret "additional-pull-secret" "kube-system" "${SHARED_DIR}/nested_kubeconfig" "$new_auth_test_url" "$new_auth_test_user_2" "$new_auth_test_pass_2"

  set +x
  # the new auth will be synced to global-pull-secret
  retry_until_success 10 5 verify_credentials_in_global_ps "$new_auth_test_url" "$new_registry_auth_2"

  # the new auth will be synced to all nodes
  for node in $nodes; do
    retry_until_success 10 5 check_auth_exists_ps_node "$node" "$new_auth_test_url" "$new_registry_auth_2"
  done
  set -x

  # delete the global-pull-secret, it will get created again
  delete_global_ps
  retry_until_success 10 5 bash -c "oc get --ignore-not-found secret global-pull-secret -n kube-system -o jsonpath={.metadata.name} | grep global-pull-secret"

  # delete the additional-pull-secret, all will be deleted
  oc delete secret additional-pull-secret -n kube-system
  retry_until_success 10 5 bash -c "oc get --ignore-not-found secret global-pull-secret -n kube-system --no-headers | grep -q '^' || echo \"0\""

  # in each node, there is no more auth added here.
  set +x
  for node in $nodes; do
    retry_until_success 10 5 check_auth_not_exists_ps_node "$node" "$REG_ROUTE" "$reg_registry_auth"
    retry_until_success 10 5 check_auth_not_exists_ps_node "$node" "$new_auth_test_url" "$new_registry_auth_2"
  done
  set -x

  echo "Basic global pull secret test completed successfully"
}

## Test cases for the original pull secret and additional-pull-secret merging with or without conflicts
# NOTE: The basic test (if run) cleans up additional-pull-secret at the end
# Each test case below will create its own additional-pull-secret and clean it up

# Test Case: Update additional-pull-secret which conflicts with original pull secret
function test_update_additional_pull_secret_with_conflicts() {
  echo "=== Testing updating additional-pull-secret with conflicts ==="
  set +x
  local fake_user="fakeuser" fake_pass="fakepass" existing_auth_json existing_registry existing_auth
  existing_auth_json=$(get_existing_registry_from_secret "pull-secret" "openshift-config" "$KUBECONFIG")
  existing_registry=$(echo "$existing_auth_json" | jq -r '.key')
  existing_auth=$(echo "$existing_auth_json" | jq -r '.value.auth')
  echo "Found existing registry in original pull secret: $existing_registry"
  # Create an additional-pull-secret with different credentials for the same registry
  create_or_update_pull_secret "additional-pull-secret" "kube-system" "${SHARED_DIR}/nested_kubeconfig" "$existing_registry" "$fake_user" "$fake_pass"
  echo "Created additional-pull-secret with conflicting credentials for: $existing_registry"
  # the pull secrets in global-pull-secret should always be the original one because of conflicts
  retry_until_success 10 5 verify_credentials_in_global_ps "$existing_registry" "$existing_auth"
  for node in $nodes; do
    retry_until_success 10 5 check_auth_exists_ps_node "$node" "$existing_registry" "$existing_auth"
  done
  # Cleanup
  oc delete secret additional-pull-secret -n kube-system
  retry_until_success 10 5 bash -c "oc get --ignore-not-found secret global-pull-secret -n kube-system --no-headers | grep -q '^' || echo \"0\""
  retry_until_success 10 5 check_auth_not_exists_ps_node "$node" "$existing_registry" "$(base64_encode_auth "$fake_user" "$fake_pass")"
  echo "Precedence test completed successfully"
}

# Test Case: Update additional-pull-secret without conflicts, check the availability of the new auth
function test_update_additional_pull_secret_without_conflicts() {
  echo "=== Testing additional-pull-secret update without conflicts ==="
  # Create a new registry entry in additional-pull-secret
  local new_registry="test-additional-ps-no-conflict.com" new_user="test-user-additional-ps" new_pass="test-pass-additional-ps" test_new_registry_auth
  create_or_update_pull_secret "additional-pull-secret" "kube-system" "${SHARED_DIR}/nested_kubeconfig" "$new_registry" "$new_user" "$new_pass"
  echo "Updated additional-pull-secret with new registry: $new_registry"
  test_new_registry_auth=$(base64_encode_auth "$new_user" "$new_pass")

  set +x
  retry_until_success 10 5 verify_credentials_in_global_ps "$new_registry" "$test_new_registry_auth"
  for node in $nodes; do
    retry_until_success 10 5 check_auth_exists_ps_node "$node" "$new_registry" "$test_new_registry_auth"
  done
  # Cleanup
  oc delete secret additional-pull-secret -n kube-system
  retry_until_success 10 5 bash -c "oc get --ignore-not-found secret global-pull-secret -n kube-system --no-headers | grep -q '^' || echo \"0\""
  echo "Additional-pull-secret no-conflict test completed successfully"
}

# Test Case: Update CLUSTER_PULL_SECRET in management cluster with conflicts
# the new added auth will take precedence
# This case demonstrate when something added to the management cluster, which will trigger the reconciling of the global-pull-secret
function test_update_original_pull_secret_with_conflicts() {
  echo "=== Testing ${CLUSTER_PULL_SECRET} update with conflicts ==="

  # create one into additional-pull-secret
  local new_registry="test-additional-ps.com" new_user="test-user-additional-ps" new_pass="test-pass-additional-ps" test_new_registry_auth
  create_or_update_pull_secret "additional-pull-secret" "kube-system" "${SHARED_DIR}/nested_kubeconfig" "$new_registry" "$new_user" "$new_pass"
  echo "Updated additional-pull-secret with new registry: $new_registry"
  test_new_registry_auth=$(base64_encode_auth "$new_user" "$new_pass")
  # wait until the new registry has been synced to global-pull-secret and nodes
  set +x
  retry_until_success 10 5 verify_credentials_in_global_ps "$new_registry" "$test_new_registry_auth"
  for node in $nodes; do
    retry_until_success 10 5 check_auth_exists_ps_node "$node" "$new_registry" "$test_new_registry_auth"
  done

  # now create the auth with different usename+password to management cluster
  local new_mgmt_user="test-mgmt-user" new_mgmt_pass="test-mgmt-pass" new_mgmt_auth
  new_mgmt_auth=$(base64_encode_auth "$new_mgmt_user" "$new_mgmt_pass")
  local mgmt_kubeconfig="${SHARED_DIR}/kubeconfig"
  create_or_update_pull_secret "$CLUSTER_PULL_SECRET" "$HOSTEDCLUSTER_NAMESPACE" "$mgmt_kubeconfig" "$new_registry" "$new_mgmt_user" "$new_mgmt_pass"

  # delete the global-pull-secret to trigger the reconcile
  sleep 5 && delete_global_ps

  # the latter auth will be used in global-pull-secret and nodes
  set +x
  retry_until_success 20 5 verify_credentials_in_global_ps "$new_registry" "$new_mgmt_auth"
  for node in $nodes; do
    retry_until_success 10 5 check_auth_exists_ps_node "$node" "$new_registry" "$new_mgmt_auth"
  done
  # Cleanup
  oc delete secret additional-pull-secret -n kube-system
  retry_until_success 10 5 bash -c "oc get --ignore-not-found secret global-pull-secret -n kube-system --no-headers | grep -q '^' || echo \"0\""
  delete_image_registry_from_pull_secret "$CLUSTER_PULL_SECRET" "$HOSTEDCLUSTER_NAMESPACE" "$mgmt_kubeconfig" "$new_registry"
  echo "Updating ${CLUSTER_PULL_SECRET} with conflict test completed successfully"
}

# Test Case: Update CLUSTER_PULL_SECRET in management cluster without conflicts
# This case demonstrate when something added to the management cluster, which will trigger the reconciling of the global-pull-secret
function test_update_original_pull_secret_without_conflicts() {
  echo "=== Testing ${CLUSTER_PULL_SECRET} update without conflicts ==="

  # create one into additional-pull-secret
  local new_registry="test-additional-ps-no-conflict2.com"
  local new_user="test-user-additional-ps"
  local new_pass="test-pass-additional-ps"
  create_or_update_pull_secret "additional-pull-secret" "kube-system" "${SHARED_DIR}/nested_kubeconfig" "$new_registry" "$new_user" "$new_pass"
  echo "Updated additional-pull-secret with new registry: $new_registry"
  local test_new_registry_auth
  test_new_registry_auth=$(base64_encode_auth "$new_user" "$new_pass")
  # wait until the new registry has been synced to global-pull-secret and nodes
  set +x
  retry_until_success 10 5 verify_credentials_in_global_ps "$new_registry" "$test_new_registry_auth"
  for node in $nodes; do
    retry_until_success 10 5 check_auth_exists_ps_node "$node" "$new_registry" "$test_new_registry_auth"
  done

  # now create another auth with different usename+password to management cluster
  local new_mgmt_registry="test-mgmt-ps.com" new_mgmt_user="test-mgmt-user" new_mgmt_pass="test-mgmt-pass" new_mgmt_auth
  new_mgmt_auth=$(base64_encode_auth "$new_mgmt_user" "$new_mgmt_pass")
  local mgmt_kubeconfig="${SHARED_DIR}/kubeconfig"
  create_or_update_pull_secret "$CLUSTER_PULL_SECRET" "$HOSTEDCLUSTER_NAMESPACE" "$mgmt_kubeconfig" "$new_mgmt_registry" "$new_mgmt_user" "$new_mgmt_pass"

  # delete the global-pull-secret to trigger the reconcile
  sleep 5 && delete_global_ps

  # the latter auth will be used in global-pull-secret and nodes
  set +x
  retry_until_success 20 5 verify_credentials_in_global_ps "$new_mgmt_registry" "$new_mgmt_auth"
  for node in $nodes; do
    retry_until_success 10 5 check_auth_exists_ps_node "$node" "$new_mgmt_registry" "$new_mgmt_auth"
  done

  # Cleanup
  oc delete secret additional-pull-secret -n kube-system
  retry_until_success 10 5 bash -c "oc get --ignore-not-found secret global-pull-secret -n kube-system --no-headers | grep -q '^' || echo \"0\""
  delete_image_registry_from_pull_secret "$CLUSTER_PULL_SECRET" "$HOSTEDCLUSTER_NAMESPACE" "$mgmt_kubeconfig" "$new_mgmt_registry"
  echo "Updating ${CLUSTER_PULL_SECRET} without conflict test completed successfully"
}

# Test Case: new nodes of RePlace upgrade strategy should be updated
function test_new_node_pools_inplace_replace_upgrade() {
  echo "=== Testing new nodepool with RePlace upgrade strategy should be updated. ==="

  # create additional-pull-secret
  local new_registry="test-ps-upgrade.com" new_user="test-user-ps" new_pass="test-pass-ps" test_new_registry_auth
  create_or_update_pull_secret "additional-pull-secret" "kube-system" "${SHARED_DIR}/nested_kubeconfig" "$new_registry" "$new_user" "$new_pass"
  echo "Updated additional-pull-secret with new registry: $new_registry"
  test_new_registry_auth=$(base64_encode_auth "$new_user" "$new_pass")
  # wait until the new registry has been synced to global-pull-secret and nodes
  set +x
  retry_until_success 10 5 verify_credentials_in_global_ps "$new_registry" "$test_new_registry_auth"
  for node in $nodes; do
    retry_until_success 10 5 check_auth_exists_ps_node "$node" "$new_registry" "$test_new_registry_auth"
  done

  # Create a new nodepool with InPlace upgrade type
  # we need to switch to mgmt to create nodepool
  set -x
  export KUBECONFIG="${SHARED_DIR}/kubeconfig"
  if [[ "${platform_lower}" == "azure" ]]; then
      SUBNET_ID="$(oc get hc -n $HOSTEDCLUSTER_NAMESPACE $HOSTEDCLUSTER_NAME -o jsonpath='{.spec.platform.azure.subnetID}')"
      MARKET_PUBLISHER="$(oc get np -n $HOSTEDCLUSTER_NAMESPACE -ojsonpath='{.items[0].spec.platform.azure.image.azureMarketplace.publisher}')"
      MARKET_OFFER="$(oc get np -n $HOSTEDCLUSTER_NAMESPACE -ojsonpath='{.items[0].spec.platform.azure.image.azureMarketplace.offer}')"
      MARKET_SKU="$(oc get np -n $HOSTEDCLUSTER_NAMESPACE -ojsonpath='{.items[0].spec.platform.azure.image.azureMarketplace.sku}')"
      MARKET_VERSION="$(oc get np -n $HOSTEDCLUSTER_NAMESPACE -ojsonpath='{.items[0].spec.platform.azure.image.azureMarketplace.version}')"
      MARKET_CMD_OPTS=""
      if [[ -n "${MARKET_PUBLISHER}" ]]; then
          MARKET_CMD_OPTS="--marketplace-publisher $MARKET_PUBLISHER --marketplace-offer $MARKET_OFFER --marketplace-sku $MARKET_SKU --marketplace-version $MARKET_VERSION"
      fi

      hypershift create nodepool "${platform_lower}" --name test-np-inplace --namespace "$HOSTEDCLUSTER_NAMESPACE" --cluster-name "$HOSTEDCLUSTER_NAME" --replicas 1 --node-upgrade-type InPlace --nodepool-subnet-id "$SUBNET_ID" $MARKET_CMD_OPTS
      # Create another nodepool with Replace upgrade type
      hypershift create nodepool "${platform_lower}" --name test-np-replace --namespace "$HOSTEDCLUSTER_NAMESPACE" --cluster-name "$HOSTEDCLUSTER_NAME" --replicas 1 --node-upgrade-type Replace --nodepool-subnet-id "$SUBNET_ID" $MARKET_CMD_OPTS
  else
      hypershift create nodepool "${platform_lower}" --name test-np-inplace --namespace "$HOSTEDCLUSTER_NAMESPACE" --cluster-name "$HOSTEDCLUSTER_NAME" --replicas 1 --node-upgrade-type InPlace
      # Create another nodepool with Replace upgrade type
      hypershift create nodepool "${platform_lower}" --name test-np-replace --namespace "$HOSTEDCLUSTER_NAMESPACE" --cluster-name "$HOSTEDCLUSTER_NAME" --replicas 1 --node-upgrade-type Replace
  fi

  # wait until the nodes are ready
  oc wait nodepool test-np-inplace -n "$HOSTEDCLUSTER_NAMESPACE" --for=condition=AllNodesHealthy --timeout=30m
  oc wait nodepool test-np-replace -n "$HOSTEDCLUSTER_NAMESPACE" --for=condition=AllNodesHealthy --timeout=30m
  # switch back to the hosted cluster
  export KUBECONFIG="${SHARED_DIR}/nested_kubeconfig"
  set +x

  # after nodepools are ready, the auth still exists in the global-pull-secret
  retry_until_success 10 5 verify_credentials_in_global_ps "$new_registry" "$test_new_registry_auth"

  # The config.json in replace_nodes should be updated
  # we check replace first, because it will take effect
  replace_nodes=$(oc get nodes -l 'hypershift.openshift.io/nodePool=test-np-replace' -o jsonpath='{.items[*].metadata.name}')
  for node in $replace_nodes; do
    echo -e "\n\nChecking the RePlace node: $node\n\n"
    # it takes about 10 minutes , so let's wait at most 30 minutes
    retry_until_success 60 30 check_auth_exists_ps_node "$node" "$new_registry" "$test_new_registry_auth"
  done

  # The config.json in inplace_nodes should NOT be updated
  inplace_nodes=$(oc get nodes -l 'hypershift.openshift.io/nodePool=test-np-inplace' -o jsonpath='{.items[*].metadata.name}')
  for node in $inplace_nodes; do
    echo -e "\n\nChecking the InPlace node: $node\n\n"
    retry_until_success 10 5 check_auth_not_exists_ps_node "$node" "$new_registry" "$test_new_registry_auth"
  done

  set -x
  # Cleanup
  oc delete secret additional-pull-secret -n kube-system
  retry_until_success 10 5 bash -c "oc get --ignore-not-found secret global-pull-secret -n kube-system --no-headers | grep -q '^' || echo \"0\""

  # we need to switch to mgmt to clean the nodepools
  export KUBECONFIG="${SHARED_DIR}/kubeconfig"
  oc delete nodepool test-np-inplace --namespace "$HOSTEDCLUSTER_NAMESPACE"
  # Create another nodepool with Replace upgrade type
  oc delete nodepool test-np-replace --namespace "$HOSTEDCLUSTER_NAMESPACE"
  # switch back to the hosted cluster
  export KUBECONFIG="${SHARED_DIR}/nested_kubeconfig"

  echo "Testing of Inplace/Replace upgrade strategry has completed successfully"
}

# Test Case: new nodes of In/RePlace upgrade strategy before creating additional-pull-secret should be updated
function test_new_inplace_replace_upgrade_nodes_before_additional_pull_secret() {
  echo "=== Testing new nodepool with RePlace upgrade strategy should be updated before creating the additional-pull-secret. ==="

  # Create a new nodepool with InPlace upgrade type
  # we need to switch to mgmt to create nodepool
  set -x
  export KUBECONFIG="${SHARED_DIR}/kubeconfig"
  if [[ "${platform_lower}" == "azure" ]]; then
      SUBNET_ID="$(oc get hc -n $HOSTEDCLUSTER_NAMESPACE $HOSTEDCLUSTER_NAME -o jsonpath='{.spec.platform.azure.subnetID}')"
      MARKET_PUBLISHER="$(oc get np -n $HOSTEDCLUSTER_NAMESPACE -ojsonpath='{.items[0].spec.platform.azure.image.azureMarketplace.publisher}')"
      MARKET_OFFER="$(oc get np -n $HOSTEDCLUSTER_NAMESPACE -ojsonpath='{.items[0].spec.platform.azure.image.azureMarketplace.offer}')"
      MARKET_SKU="$(oc get np -n $HOSTEDCLUSTER_NAMESPACE -ojsonpath='{.items[0].spec.platform.azure.image.azureMarketplace.sku}')"
      MARKET_VERSION="$(oc get np -n $HOSTEDCLUSTER_NAMESPACE -ojsonpath='{.items[0].spec.platform.azure.image.azureMarketplace.version}')"
      MARKET_CMD_OPTS=""
      if [[ -n "${MARKET_PUBLISHER}" ]]; then
          MARKET_CMD_OPTS="--marketplace-publisher $MARKET_PUBLISHER --marketplace-offer $MARKET_OFFER --marketplace-sku $MARKET_SKU --marketplace-version $MARKET_VERSION"
      fi

      hypershift create nodepool "${platform_lower}" --name test-np-inplace --namespace "$HOSTEDCLUSTER_NAMESPACE" --cluster-name "$HOSTEDCLUSTER_NAME" --replicas 1 --node-upgrade-type InPlace --nodepool-subnet-id "$SUBNET_ID" $MARKET_CMD_OPTS
      # Create another nodepool with Replace upgrade type
      hypershift create nodepool "${platform_lower}" --name test-np-replace --namespace "$HOSTEDCLUSTER_NAMESPACE" --cluster-name "$HOSTEDCLUSTER_NAME" --replicas 1 --node-upgrade-type Replace --nodepool-subnet-id "$SUBNET_ID" $MARKET_CMD_OPTS
  else
      hypershift create nodepool "${platform_lower}" --name test-np-inplace --namespace "$HOSTEDCLUSTER_NAMESPACE" --cluster-name "$HOSTEDCLUSTER_NAME" --replicas 1 --node-upgrade-type InPlace
      # Create another nodepool with Replace upgrade type
      hypershift create nodepool "${platform_lower}" --name test-np-replace --namespace "$HOSTEDCLUSTER_NAMESPACE" --cluster-name "$HOSTEDCLUSTER_NAME" --replicas 1 --node-upgrade-type Replace
  fi

  # wait until the nodes are ready
  oc wait nodepool test-np-inplace -n "$HOSTEDCLUSTER_NAMESPACE" --for=condition=AllNodesHealthy --timeout=30m
  oc wait nodepool test-np-replace -n "$HOSTEDCLUSTER_NAMESPACE" --for=condition=AllNodesHealthy --timeout=30m
  # switch back to the hosted cluster
  export KUBECONFIG="${SHARED_DIR}/nested_kubeconfig"
  set +x

  # create additional-pull-secret
  local new_registry="test-ps-upgrade.com" new_user="test-user-ps" new_pass="test-pass-ps" test_new_registry_auth
  create_or_update_pull_secret "additional-pull-secret" "kube-system" "${SHARED_DIR}/nested_kubeconfig" "$new_registry" "$new_user" "$new_pass"
  echo "Updated additional-pull-secret with new registry: $new_registry"
  test_new_registry_auth=$(base64_encode_auth "$new_user" "$new_pass")
  # wait until the new registry has been synced to global-pull-secret and nodes
  set +x
  retry_until_success 10 5 verify_credentials_in_global_ps "$new_registry" "$test_new_registry_auth"
  for node in $nodes; do
    retry_until_success 10 5 check_auth_exists_ps_node "$node" "$new_registry" "$test_new_registry_auth"
  done

  # after nodepools are ready, the auth still exists in the global-pull-secret
  retry_until_success 10 5 verify_credentials_in_global_ps "$new_registry" "$test_new_registry_auth"

  # The config.json in replace_nodes should be updated
  # we check replace first, because it will take effect
  replace_nodes=$(oc get nodes -l 'hypershift.openshift.io/nodePool=test-np-replace' -o jsonpath='{.items[*].metadata.name}')
  for node in $replace_nodes; do
    echo -e "\n\nChecking the RePlace node: $node\n\n"
    retry_until_success 60 30 check_auth_exists_ps_node "$node" "$new_registry" "$test_new_registry_auth"
  done

  # The config.json in inplace_nodes should NOT be updated
  inplace_nodes=$(oc get nodes -l 'hypershift.openshift.io/nodePool=test-np-inplace' -o jsonpath='{.items[*].metadata.name}')
  for node in $inplace_nodes; do
    echo -e "\n\nChecking the InPlace node: $node\n\n"
    retry_until_success 10 5 check_auth_not_exists_ps_node "$node" "$new_registry" "$test_new_registry_auth"
  done

  set -x
  # Cleanup
  oc delete secret additional-pull-secret -n kube-system
  retry_until_success 10 5 bash -c "oc get --ignore-not-found secret global-pull-secret -n kube-system --no-headers | grep -q '^' || echo \"0\""

  # we need to switch to mgmt to clean the nodepools
  export KUBECONFIG="${SHARED_DIR}/kubeconfig"
  oc delete nodepool test-np-inplace --namespace "$HOSTEDCLUSTER_NAMESPACE"
  # Create another nodepool with Replace upgrade type
  oc delete nodepool test-np-replace --namespace "$HOSTEDCLUSTER_NAMESPACE"
  # switch back to the hosted cluster
  export KUBECONFIG="${SHARED_DIR}/nested_kubeconfig"

  echo "Testing of Inplace/Replace upgrade strategry before creating additional-pull-secret has completed successfully"
}

# Test Case: Update additional-pull-secret first, then directly modify node config.json
# Tests that non-conflicting manual changes are preserved, while conflicting ones are reverted
function test_update_in_node_directly_after_additional_ps() {
  echo "=== Testing direct node config.json modification after additional-pull-secret update ==="

  # Get replace nodes from the hosted cluster
  local replace_nodes
  replace_nodes=$(get_replace_nodes)
  echo "Found replace nodes: $replace_nodes"

  # First, create additional-pull-secret with a new auth
  local new_registry="test-direct-node-update.com" new_user="test-user-node" new_pass="test-pass-node" test_new_registry_auth
  create_or_update_pull_secret "additional-pull-secret" "kube-system" "${SHARED_DIR}/nested_kubeconfig" "$new_registry" "$new_user" "$new_pass"
  echo "Created additional-pull-secret with new registry: $new_registry"
  test_new_registry_auth=$(base64_encode_auth "$new_user" "$new_pass")

  # Wait until the new registry has been synced to global-pull-secret and nodes
  set +x
  retry_until_success 10 5 verify_credentials_in_global_ps "$new_registry" "$test_new_registry_auth"
  for node in $replace_nodes; do
    retry_until_success 10 5 check_auth_exists_ps_node "$node" "$new_registry" "$test_new_registry_auth"
  done
  set -x

  # Now directly modify the config.json in each node
  # Add two auths: one non-conflicting (should be preserved), one conflicting (should be reverted)
  local non_conflict_registry="manual-registry-no-conflict.com"
  local non_conflict_user="manual-user"
  local non_conflict_pass="manual-pass"
  local non_conflict_auth=$(base64_encode_auth "$non_conflict_user" "$non_conflict_pass")

  local conflict_user="conflicting-user"
  local conflict_pass="conflicting-pass"
  local conflict_auth=$(base64_encode_auth "$conflict_user" "$conflict_pass")

  for node in $replace_nodes; do
    echo "Directly modifying config.json in node: $node"
    # Read current config, add two new auths
    oc debug "node/$node" -q -- chroot /host bash -c "
CONFIG_FILE=\"/var/lib/kubelet/config.json\"
# Read current config
CURRENT_CONFIG=\$(cat \$CONFIG_FILE)
# Add non-conflicting auth
UPDATED_CONFIG=\$(echo \"\$CURRENT_CONFIG\" | jq '.auths[\"$non_conflict_registry\"] = {\"auth\": \"$non_conflict_auth\"}')
# Add conflicting auth for the registry from additional-pull-secret
UPDATED_CONFIG=\$(echo \"\$UPDATED_CONFIG\" | jq '.auths[\"$new_registry\"] = {\"auth\": \"$conflict_auth\"}')
# Write back
echo \"\$UPDATED_CONFIG\" > \$CONFIG_FILE
"
    echo "Modified config.json in node: $node"
  done

  # Wait a bit for the system to detect the change
  sleep 10

  set +x
  # Verify that non-conflicting auth is preserved in nodes
  for node in $replace_nodes; do
    echo "Checking that non-conflicting auth is preserved in node: $node"
    retry_until_success 10 5 check_auth_exists_ps_node "$node" "$non_conflict_registry" "$non_conflict_auth"
    retry_until_success 10 5 verify_all_original_pull_secret_auths_in_node "$node"
  done

  # Verify that the conflicting auth is reverted back to the original from additional-pull-secret
  for node in $replace_nodes; do
    echo "Checking that conflicting auth is reverted to additional-pull-secret value in node: $node"
    retry_until_success 30 5 check_auth_exists_ps_node "$node" "$new_registry" "$test_new_registry_auth"
    retry_until_success 30 5 verify_all_original_pull_secret_auths_in_node "$node"
  done
  set -x

  # Cleanup - Test disaster recovery by deleting config.json
  echo "Testing disaster recovery by deleting /var/lib/kubelet/config.json on all nodes"
  for node in $replace_nodes; do
    echo "Deleting config.json in node: $node"
    oc debug "node/$node" -q -- chroot /host rm -f /var/lib/kubelet/config.json
  done

  # Wait for the file to be recreated
  sleep 10

  set +x
  # Verify the file is recreated and doesn't contain non-conflicting manual auth (it should be gone)
  for node in $replace_nodes; do
    echo "Checking that non-conflicting manual auth is NOT in recreated config.json in node: $node"
    retry_until_success 30 5 check_auth_not_exists_ps_node "$node" "$non_conflict_registry" "$non_conflict_auth"
  done

  # Verify the file contains the auth from additional-pull-secret (it should be restored)
  for node in $replace_nodes; do
    echo "Checking that auth from additional-pull-secret IS in recreated config.json in node: $node"
    retry_until_success 30 5 check_auth_exists_ps_node "$node" "$new_registry" "$test_new_registry_auth"
    retry_until_success 30 5 verify_all_original_pull_secret_auths_in_node "$node"
  done
  set -x

  # Delete the additional-pull-secret
  if oc get secret additional-pull-secret -n kube-system &>/dev/null; then
    oc delete secret additional-pull-secret -n kube-system
  fi
  retry_until_success 10 5 bash -c "oc get --ignore-not-found secret global-pull-secret -n kube-system --no-headers | grep -q '^' || echo \"0\""

  # Wait a bit for changes to propagate
  sleep 10

  set +x
  # Verify the config.json doesn't have any of the manually added items
  for node in $replace_nodes; do
    echo "Verifying all manually added auths are gone from node: $node"
    retry_until_success 10 5 check_auth_not_exists_ps_node "$node" "$non_conflict_registry" "$non_conflict_auth"
    retry_until_success 10 5 check_auth_not_exists_ps_node "$node" "$new_registry" "$test_new_registry_auth"
    retry_until_success 10 5 verify_all_original_pull_secret_auths_in_node "$node"
  done
  set -x

  echo "Direct node update after additional-pull-secret test completed successfully"
}

# Test Case: Directly modify node config.json first, then update additional-pull-secret
# Tests the reverse order to verify reconciliation behavior
function test_update_in_node_directly_before_additional_ps() {
  echo "=== Testing direct node config.json modification before additional-pull-secret update ==="

  # Get replace nodes from the hosted cluster
  local replace_nodes
  replace_nodes=$(get_replace_nodes)
  echo "Found replace nodes: $replace_nodes"

  # First, directly modify the config.json in each node
  # Add two auths: one that will not conflict, one that will conflict with future additional-pull-secret
  local non_conflict_registry="manual-registry-no-conflict2.com"
  local non_conflict_user="manual-user2"
  local non_conflict_pass="manual-pass2"
  local non_conflict_auth=$(base64_encode_auth "$non_conflict_user" "$non_conflict_pass")

  local future_registry="test-direct-node-update2.com"
  local manual_user="manual-conflicting-user"
  local manual_pass="manual-conflicting-pass"
  local manual_auth=$(base64_encode_auth "$manual_user" "$manual_pass")

  for node in $replace_nodes; do
    echo "Directly modifying config.json in node: $node"
    oc debug "node/$node" -q -- chroot /host bash -c "
CONFIG_FILE=\"/var/lib/kubelet/config.json\"
# Read current config
CURRENT_CONFIG=\$(cat \$CONFIG_FILE)
# Add non-conflicting auth
UPDATED_CONFIG=\$(echo \"\$CURRENT_CONFIG\" | jq '.auths[\"$non_conflict_registry\"] = {\"auth\": \"$non_conflict_auth\"}')
# Add auth that will conflict with future additional-pull-secret
UPDATED_CONFIG=\$(echo \"\$UPDATED_CONFIG\" | jq '.auths[\"$future_registry\"] = {\"auth\": \"$manual_auth\"}')
# Write back
echo \"\$UPDATED_CONFIG\" > \$CONFIG_FILE
"
    echo "Modified config.json in node: $node"
  done

  # Wait a bit
  sleep 10

  set +x
  # Verify the manual changes are present
  for node in $replace_nodes; do
    echo "Verifying manual changes are present in node: $node"
    retry_until_success 10 5 check_auth_exists_ps_node "$node" "$non_conflict_registry" "$non_conflict_auth"
    retry_until_success 10 5 check_auth_exists_ps_node "$node" "$future_registry" "$manual_auth"
    retry_until_success 10 5 verify_all_original_pull_secret_auths_in_node "$node"
  done
  set -x

  # Now create additional-pull-secret with auth for future_registry (conflicting)
  local new_user="test-user-node2" new_pass="test-pass-node2" test_new_registry_auth
  create_or_update_pull_secret "additional-pull-secret" "kube-system" "${SHARED_DIR}/nested_kubeconfig" "$future_registry" "$new_user" "$new_pass"
  echo "Created additional-pull-secret with registry: $future_registry"
  test_new_registry_auth=$(base64_encode_auth "$new_user" "$new_pass")

  # Wait until the new registry has been synced to global-pull-secret
  set +x
  retry_until_success 10 5 verify_credentials_in_global_ps "$future_registry" "$test_new_registry_auth"

  # Verify that non-conflicting auth is still preserved in nodes
  for node in $replace_nodes; do
    echo "Checking that non-conflicting auth is still preserved in node: $node"
    retry_until_success 10 5 check_auth_exists_ps_node "$node" "$non_conflict_registry" "$non_conflict_auth"
    retry_until_success 10 5 verify_all_original_pull_secret_auths_in_node "$node"
  done

  # Verify that the conflicting auth is replaced with the one from additional-pull-secret
  for node in $replace_nodes; do
    echo "Checking that conflicting auth is replaced with additional-pull-secret value in node: $node"
    retry_until_success 30 5 check_auth_exists_ps_node "$node" "$future_registry" "$test_new_registry_auth"
    retry_until_success 30 5 verify_all_original_pull_secret_auths_in_node "$node"
  done
  set -x

  # Cleanup - Test disaster recovery by deleting config.json
  echo "Testing disaster recovery by deleting /var/lib/kubelet/config.json on all nodes"
  for node in $replace_nodes; do
    echo "Deleting config.json in node: $node"
    oc debug "node/$node" -q -- chroot /host rm -f /var/lib/kubelet/config.json
  done

  # Wait for the file to be recreated
  sleep 10

  set +x
  # Verify the file is recreated and doesn't contain non-conflicting manual auth (it should be gone)
  for node in $replace_nodes; do
    echo "Checking that non-conflicting manual auth is NOT in recreated config.json in node: $node"
    retry_until_success 30 5 check_auth_not_exists_ps_node "$node" "$non_conflict_registry" "$non_conflict_auth"
  done

  # Verify the file contains the auth from additional-pull-secret (it should be restored)
  for node in $replace_nodes; do
    echo "Checking that auth from additional-pull-secret IS in recreated config.json in node: $node"
    retry_until_success 30 5 check_auth_exists_ps_node "$node" "$future_registry" "$test_new_registry_auth"
    retry_until_success 30 5 verify_all_original_pull_secret_auths_in_node "$node"
  done
  set -x

  # Delete the additional-pull-secret
  if oc get secret additional-pull-secret -n kube-system &>/dev/null; then
    oc delete secret additional-pull-secret -n kube-system
  fi
  retry_until_success 10 5 bash -c "oc get --ignore-not-found secret global-pull-secret -n kube-system --no-headers | grep -q '^' || echo \"0\""

  # Wait a bit for changes to propagate
  sleep 10

  set +x
  # Verify the config.json doesn't have any of the manually added items
  for node in $replace_nodes; do
    echo "Verifying all manually added auths are gone from node: $node"
    retry_until_success 10 5 check_auth_not_exists_ps_node "$node" "$non_conflict_registry" "$non_conflict_auth"
    retry_until_success 10 5 check_auth_not_exists_ps_node "$node" "$future_registry" "$test_new_registry_auth"
    retry_until_success 10 5 verify_all_original_pull_secret_auths_in_node "$node"
  done
  set -x

  echo "Direct node update before additional-pull-secret test completed successfully"
}

# Test Case: Corrupted config.json recovery
# Tests that the system can recover from various types of corrupted config.json files
function test_corrupted_config_json_recovery() {
  echo "=== Testing recovery from corrupted config.json files ==="

  # Get replace nodes from the hosted cluster
  local replace_nodes
  replace_nodes=$(get_replace_nodes)
  echo "Found replace nodes: $replace_nodes"

  # Create additional-pull-secret with a new auth
  local new_registry="test-corrupted-recovery.com" new_user="test-user-corrupt" new_pass="test-pass-corrupt" test_new_registry_auth
  create_or_update_pull_secret "additional-pull-secret" "kube-system" "${SHARED_DIR}/nested_kubeconfig" "$new_registry" "$new_user" "$new_pass"
  echo "Created additional-pull-secret with new registry: $new_registry"
  test_new_registry_auth=$(base64_encode_auth "$new_user" "$new_pass")

  # Wait until the new registry has been synced to global-pull-secret and nodes
  set +x
  retry_until_success 10 5 verify_credentials_in_global_ps "$new_registry" "$test_new_registry_auth"
  for node in $replace_nodes; do
    retry_until_success 10 5 check_auth_exists_ps_node "$node" "$new_registry" "$test_new_registry_auth"
  done
  set -x

  # Test corruption type 1: Invalid JSON syntax
  echo "Testing recovery from invalid JSON syntax on all nodes"
  for node in $replace_nodes; do
    echo "Corrupting config.json with invalid JSON in node: $node"
    oc debug "node/$node" -q -- chroot /host bash -c "echo '{invalid json syntax here' > /var/lib/kubelet/config.json"
  done

  # Wait for the system to detect and fix the corruption
  sleep 15

  set +x
  # Verify all nodes have been fixed and contain the correct auth
  for node in $replace_nodes; do
    echo "Verifying invalid JSON has been fixed in node: $node"
    retry_until_success 30 5 check_auth_exists_ps_node "$node" "$new_registry" "$test_new_registry_auth"
    retry_until_success 30 5 verify_all_original_pull_secret_auths_in_node "$node"
  done
  set -x

  # Test corruption type 2: Valid JSON but missing .auths field
  echo "Testing recovery from missing .auths field on all nodes"
  for node in $replace_nodes; do
    echo "Corrupting config.json with missing .auths field in node: $node"
    oc debug "node/$node" -q -- chroot /host bash -c "echo '{}' > /var/lib/kubelet/config.json"
  done

  # Wait for the system to detect and fix the corruption
  sleep 15

  set +x
  # Verify all nodes have been fixed and contain the correct auth
  for node in $replace_nodes; do
    echo "Verifying missing .auths field has been fixed in node: $node"
    retry_until_success 30 5 check_auth_exists_ps_node "$node" "$new_registry" "$test_new_registry_auth"
    retry_until_success 30 5 verify_all_original_pull_secret_auths_in_node "$node"
  done
  set -x

  # Test corruption type 3: Valid JSON but wrong structure
  echo "Testing recovery from wrong JSON structure on all nodes"
  for node in $replace_nodes; do
    echo "Corrupting config.json with completely wrong structure in node: $node"
    oc debug "node/$node" -q -- chroot /host bash -c "echo '{\"wrong\": \"structure\", \"no\": \"auths\"}' > /var/lib/kubelet/config.json"
  done

  # Wait for the system to detect and fix the corruption
  sleep 15

  set +x
  # Verify all nodes have been fixed and contain the correct auth
  for node in $replace_nodes; do
    echo "Verifying wrong JSON structure has been fixed in node: $node"
    retry_until_success 30 5 check_auth_exists_ps_node "$node" "$new_registry" "$test_new_registry_auth"
    retry_until_success 30 5 verify_all_original_pull_secret_auths_in_node "$node"
  done
  set -x

  # Cleanup
  if oc get secret additional-pull-secret -n kube-system &>/dev/null; then
    oc delete secret additional-pull-secret -n kube-system
  fi
  retry_until_success 10 5 bash -c "oc get --ignore-not-found secret global-pull-secret -n kube-system --no-headers | grep -q '^' || echo \"0\""

  # Verify the config.json doesn't have any of the manually added items
  set +x
  for node in $replace_nodes; do
    echo "Verifying all manually added auths are gone from node: $node"
    retry_until_success 10 5 check_auth_not_exists_ps_node "$node" "$new_registry" "$test_new_registry_auth"
    retry_until_success 10 5 verify_all_original_pull_secret_auths_in_node "$node"
  done
  echo "Corrupted config.json recovery test completed successfully"
}

# Test Case: Complete disaster recovery
# Tests recovery when both global-pull-secret and all node config.json files are deleted
function test_complete_disaster_recovery() {
  echo "=== Testing complete disaster recovery (delete global-pull-secret and all node config.json files) ==="

  # Get replace nodes from the hosted cluster
  local replace_nodes
  replace_nodes=$(get_replace_nodes)
  echo "Found replace nodes: $replace_nodes"

  # Create additional-pull-secret with a new auth
  local new_registry="test-disaster-recovery.com" new_user="test-user-disaster" new_pass="test-pass-disaster" test_new_registry_auth
  create_or_update_pull_secret "additional-pull-secret" "kube-system" "${SHARED_DIR}/nested_kubeconfig" "$new_registry" "$new_user" "$new_pass"
  echo "Created additional-pull-secret with new registry: $new_registry"
  test_new_registry_auth=$(base64_encode_auth "$new_user" "$new_pass")

  # Wait until everything is synced
  set +x
  retry_until_success 10 5 verify_credentials_in_global_ps "$new_registry" "$test_new_registry_auth"
  for node in $replace_nodes; do
    retry_until_success 10 5 check_auth_exists_ps_node "$node" "$new_registry" "$test_new_registry_auth"
  done
  set -x

  # Complete disaster: Delete everything except additional-pull-secret
  echo "Simulating complete disaster: deleting global-pull-secret and all node config.json files"

  # Delete global-pull-secret
  delete_global_ps
  echo "Deleted global-pull-secret"

  # Delete config.json on all replace nodes
  for node in $replace_nodes; do
    echo "Deleting config.json in node: $node"
    oc debug "node/$node" -q -- chroot /host rm -f /var/lib/kubelet/config.json
  done

  # Wait for complete recovery
  sleep 15

  set +x
  # Verify global-pull-secret gets recreated
  echo "Verifying global-pull-secret is recreated"
  retry_until_success 20 5 bash -c "oc get --ignore-not-found secret global-pull-secret -n kube-system -o jsonpath='{.metadata.name}' | grep global-pull-secret"

  # Verify the recreated global-pull-secret has the correct content
  echo "Verifying recreated global-pull-secret has correct content"
  retry_until_success 10 5 verify_credentials_in_global_ps "$new_registry" "$test_new_registry_auth"

  # Verify all node config.json files are recreated with correct content
  for node in $replace_nodes; do
    echo "Verifying config.json is recreated with correct content in node: $node"
    retry_until_success 30 5 check_auth_exists_ps_node "$node" "$new_registry" "$test_new_registry_auth"
    retry_until_success 30 5 verify_all_original_pull_secret_auths_in_node "$node"
  done
  set -x

  # Cleanup
  if oc get secret additional-pull-secret -n kube-system &>/dev/null; then
    oc delete secret additional-pull-secret -n kube-system
  fi
  retry_until_success 10 5 bash -c "oc get --ignore-not-found secret global-pull-secret -n kube-system --no-headers | grep -q '^' || echo \"0\""
  # Verify the config.json doesn't have any of the manually added items
  set +x
  for node in $replace_nodes; do
    echo "Verifying all manually added auths are gone from node: $node"
    retry_until_success 10 5 check_auth_not_exists_ps_node "$node" "$new_registry" "$test_new_registry_auth"
    retry_until_success 10 5 verify_all_original_pull_secret_auths_in_node "$node"
  done
  echo "Complete disaster recovery test completed successfully"
}

# make sure we are using the hosted cluster kubeconfig
export KUBECONFIG="${SHARED_DIR}/nested_kubeconfig"

# If a specific test function is provided as argument, run only that function and exit
if [ $# -gt 0 ]; then
  echo "Running specific test function: $1"
  "$1"
  exit $?
fi

echo -e "\n=== Running basic global pull secret test ===\n"
test_basic_global_pull_secret

# Run additional-pull-secret update tests
echo "=== Running tests of updating additional-pull-secret ==="
echo -e "\nRunning test_update_additional_pull_secret_with_conflicts \n"
test_update_additional_pull_secret_with_conflicts
echo -e "\nRunning test_update_additional_pull_secret_without_conflicts \n"
test_update_additional_pull_secret_without_conflicts

# Run CLUSTER_PULL_SECRET update tests
echo "=== Running tests of updating ${CLUSTER_PULL_SECRET} for cluster: ${HOSTEDCLUSTER_NAME} ==="
echo -e "\nRunning test_update_original_pull_secret_with_conflicts \n"
test_update_original_pull_secret_with_conflicts
echo -e "\nRunning test_update_original_pull_secret_without_conflicts \n"
test_update_original_pull_secret_without_conflicts

# Run inplace / replace
echo -e "\n=== Running test_new_node_pools_inplace_replace_upgrade ===\n"
test_new_node_pools_inplace_replace_upgrade

echo -e "\n=== Running test_new_inplace_replace_upgrade_nodes_before_additional_pull_secret ===\n"
test_new_inplace_replace_upgrade_nodes_before_additional_pull_secret

# Run direct node modification tests
echo -e "\n=== Running test_update_in_node_directly_after_additional_ps ===\n"
test_update_in_node_directly_after_additional_ps

echo -e "\n=== Running test_update_in_node_directly_before_additional_ps ===\n"
test_update_in_node_directly_before_additional_ps

# Run disaster recovery tests
echo -e "\n=== Running test_corrupted_config_json_recovery ===\n"
test_corrupted_config_json_recovery

echo -e "\n=== Running test_complete_disaster_recovery ===\n"
test_complete_disaster_recovery

echo -e "Nodes Status:\n"
oc --kubeconfig "${SHARED_DIR}/nested_kubeconfig" get nodes

echo "All additional global pull secret tests completed"

