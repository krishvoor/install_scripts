#!/usr/bin/env bash
set -ex

export gcp_version_channel=${GCP_VERSION_CHANNEL:-stable}
export control_plane_waiting_iterations=${GCP_CONTROL_PLANE_WAITING:-360}
export waiting_per_worker=${GCP_WORKER_UPGRADE_TIME:-5}
export GCP_CLUSTER_NAME=$(oc get infrastructure.config.openshift.io cluster -o json 2>/dev/null | jq -r '.status.infrastructureName | sub("-[^-]+$"; "")')
export CURRENT_VERSION=$(oc get clusterversion | grep ^version | awk '{print $2}')
export VERSION="4.15.14"
export UUID="${UUID:-$(uuidgen | tr '[:upper:]' '[:lower:]')}"
export KUBECONFIG="/var/folders/j6/48w6gy3n4d34gzr7jmxn6kcc0000gn/T/tmp.iEMmIb93Ko/kubeconfig"
export ES_SERVER="${ES_SERVER=}"
export _es_index="${ES_INDEX:-managedservices-timings}"
export TEMP_DIR="$(mktemp -d)"

_download_binary(){
  # Get the latest version of kube-burner-ocp from GitHub releases
  KUBE_BURNER_VERSION=$(curl -sS "https://api.github.com/repos/kube-burner/kube-burner-ocp/releases/latest" | grep -o '"tag_name": ".*"' | cut -d'"' -f4)
  
  # Construct the download URL with the latest version
  KUBE_BURNER_URL="https://github.com/kube-burner/kube-burner-ocp/releases/download/${KUBE_BURNER_VERSION}/kube-burner-ocp-${KUBE_BURNER_VERSION}-linux-x86_64.tar.gz"
  
  # Download and extract the latest version
  curl --fail --retry 8 --retry-all-errors -sS -L "${KUBE_BURNER_URL}" | tar -xzC ${TEMP_DIR} kube-burner-ocp
}

_run_kube_burner(){
    PROM_ROUTE=https://$(oc get route -n openshift-monitoring prometheus-k8s -o jsonpath="{.spec.host}")
    PROM_TOKEN=$(oc sa new-token -n openshift-monitoring prometheus-k8s)
    pushd $TEMP_DIR

    # Downloads the kube-burner-ocp binary
    _download_binary

    # clone kube-burner-ocp directory if not present
    echo "Cloning repository into ${TEMP_DIR}"
    pushd ${TEMP_DIR}
    git clone https://github.com/kube-burner/kube-burner-ocp -v kube-burner-ocp-repo

    # Index the metrics to ES_SERVER
    echo "Indexing the results"
    $TEMP_DIR/kube-burner-ocp --start=$1 --end=$2 --log-level debug --es-server=${ES_SERVER} --es-index=ripsaw-kube-burner -t ${PROM_TOKEN} -u ${PROM_ROUTE} --job-name=$3 --metrics-profile=$TEMP_DIR/kube-burner-ocp-repo/config/metrics.yml
}

_gcp_MissingUpgradeableAnnotation(){
    oc patch cloudcredential.operator.openshift.io/cluster --type merge --patch '{"metadata": {"annotations": {"cloudcredential.openshift.io/upgradeable-to": "v4.15"}}}'
}

gcp_upgrade(){
  if [ ${gcp_version_channel} == "nightly" ] ; then
    echo "ERROR: Invalid channel group. Nightly versions cannot be upgraded. Exiting..."
    exit 1
  fi
  echo "GCP Cluster: ${GCP_CLUSTER_NAME}"
  echo "OCP Channel Group: ${gcp_version_channel}"

  if [ -z ${VERSION} ] ; then
    echo "ERROR: No version to upgrade is given for the cluster ${GCP_CLUSTER_NAME}"
    exit 1
  else
    echo "INFO: Upgrading cluster ${GCP_CLUSTER_NAME} to ${VERSION} version..."
  fi

  # Patch COO for MissingUpgradeableAnnotation 
  _gcp_MissingUpgradeableAnnotation
  echo "INFO: Updating to the ${gcp_version_channel}-4.15 Channel"
  oc adm upgrade channel ${gcp_version_channel}-4.15

  echo "INFO: OCP Upgrade to 4.15 kick-started"
  oc adm upgrade --to=$VERSION --allow-not-recommended
  UPGRADE_START=$(date +%s)
  gcp_cp_upgrade_active_waiting ${VERSION}
  if [ $? -eq 0 ] ; then
    CONTROLPLANE_UPGRADE_RESULT="OK"
  else
    CONTROLPLANE_UPGRADE_RESULT="Failed"
  fi
#  gcp_workers_active_waiting
#  if [ $? -eq 0 ] ; then
#    WORKERS_UPGRADE_RESULT="OK"
#  else
#    WORKERS_UPGRADE_RESULT="Failed"
#  fi
  WORKERS_UPGRADE_DURATION="250"
  WORKERS_UPGRADE_RESULT="NA"
  UPGRADE_END=$(date +%s)
  gcp_upgrade_index_results ${CONTROLPLANE_UPGRADE_DURATION} ${CONTROLPLANE_UPGRADE_RESULT} ${WORKERS_UPGRADE_DURATION} ${WORKERS_UPGRADE_RESULT} ${CURRENT_VERSION} ${VERSION}
  _run_kube_burner ${UPGRADE_START} ${UPGRADE_END} post-gcp-upgrade
  exit 0
}

gcp_cp_upgrade_active_waiting() {
    # Giving control_plane_waiting_iterations minutes for controlplane upgrade
    start_time=$(date +%s)
    ITERATIONS=0
    while [ ${ITERATIONS} -le ${control_plane_waiting_iterations} ]; do
        VERSION_STATUS=($(oc get clusterversion | sed -e 1d | awk '{print $2" "$3" "$4}'))
        if [ ${VERSION_STATUS[0]} == $1 ] && [ ${VERSION_STATUS[1]} == "True" ] && [ ${VERSION_STATUS[2]} == "False" ]; then
            # Version is upgraded, available=true, progressing=false -> Upgrade finished
            echo "INFO: OCP upgrade to $1 is finished for OCP, now waiting for GCP..."
            end_time=$(date +%s)
            export CONTROLPLANE_UPGRADE_DURATION=$((${end_time} - ${start_time}))
            return 0
        else
            echo "INFO: ${ITERATIONS}/${control_plane_waiting_iterations}. AVAILABLE: ${VERSION_STATUS[1]}, PROGRESSING: ${VERSION_STATUS[2]}. Waiting 60 seconds for the next check..."
            ITERATIONS=$((${ITERATIONS} + 1))
            sleep 60
        fi
    done
    echo "ERROR: ${ITERATIONS}/${control_plane_waiting_iterations}. OCP Version is ${VERSION_STATUS[0]}, not upgraded to $1 after ${control_plane_waiting_iterations} iterations. Exiting..."
    oc get clusterversion
    end_time=$(date +%s)
    export CONTROLPLANE_UPGRADE_DURATION=$((${end_time} - ${start_time}))
    return 1
}

gcp_upgrade_index_results() {
    METADATA=$(grep -v "^#" <<EOF
{
  "uuid": "${UUID}",
  "platform": "GCP-MS",
  "cluster_name": "${GCP_CLUSTER_NAME}",
  "network_type": "$(oc get network cluster -o json 2>/dev/null | jq -r .status.networkType)",
  "controlplane_upgrade_duration": "$1",
  "workers_upgrade_duration": "$3",
  "from_version": "$5",
  "to_version": "$6",
  "controlplane_upgrade_result": "$2",
  "workers_upgrade_result": "$4",
  "master_count": "$(oc get node -l node-role.kubernetes.io/master= --no-headers 2>/dev/null | wc -l)",
  "worker_count": "$(oc get node --no-headers -l node-role.kubernetes.io/infra!="",node-role.kubernetes.io/worker="" 2>/dev/null | wc -l)",
  "infra_count": "$(oc get node -l node-role.kubernetes.io/infra= --no-headers --ignore-not-found 2>/dev/null | wc -l)",
  "total_node_count": "$(oc get nodes 2>/dev/null | wc -l)",
  "ocp_cluster_name": "$(oc get infrastructure.config.openshift.io cluster -o json 2>/dev/null | jq -r .status.infrastructureName)",
  "timestamp": "$(date +%s%3N)",
  "cluster_version": "$5",
  "cluster_major_version": "$(echo $5 | awk -F. '{print $1"."$2}')"
}
EOF
)
    printf "Indexing installation timings to ${ES_SERVER}/${_es_index}"
    curl -k -sS -X POST -H "Content-type: application/json" ${ES_SERVER}/${_es_index}/_doc -d "${METADATA}" -o /dev/null
    return 0
}

gcp_upgrade
