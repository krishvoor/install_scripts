#!/usr/bin/env bash
set -ex

# Declare variables
export CLUSTER_ID=${CLUSTER_ID:-""}
export UUID="${UUID:-$(uuidgen | tr '[:upper:]' '[:lower:]')}"
export TEMP_DIR="$(mktemp -d)"
export KUBECONFIG=${KUBECONFIG:-"/tmp/kubeconfig_rosa"}
export NODE_UPGRADE_TIMEOUT=${NODE_UPGRADE_TIMEOUT:-"20000"}
export MAX_SURGE=${MAX_SURGE:-"50%"}
export MAX_UNAVAILABLE=${MAX_UNAVAILABLE:-"0%"}
export MC_KUBECONFIG=${MC_KUBECONFIG:-"/tmp/kubeconfig_perf2"}
export START_TIME=${START_TIME:=""}
export END_TIME=${END_TIME:-""}

# Declare associative array to store upgrade durations
upgrade_durations=()

# _wait_for <resource> <resource_name> <desired_state> <timeout in minutes>
_wait_for(){
    echo "Waiting for $2 $1 to be $3 in $4 Minutes"
    oc wait --for=condition=$3 --timeout=$4m $1 $2
}

hcp_cp_upgrade(){

    echo "INFO: Capture ROSA-HCP Upgrade Version"
    UPGRADE_VERSION=`rosa list upgrade -c ${CLUSTER_ID} | grep -v 'no available upgrades' | grep 'recommended' | cut -d ' ' -f1 | grep 4.15`
    
    cp_start_time=$(date +"%s")
    echo "INFO: Perform ROSA-HCP Upgrade to ${UPGRADE_VERSION}"
    rosa upgrade cluster -y -m auto --version ${UPGRADE_VERSION} -c ${CLUSTER_ID} --control-plane
    sleep 600
    
    echo "INFO: Iterate over rosa list upgrade to understand if ugprade is completed"
    while true; do
      if (( $(date +"%s") - ${cp_start_time} >= 4800 )); then
        echo "ERROR: Timed out while waiting for the previous upgrade schedule to be removed."
        exit 1
      fi

      echo "INFO: Check if the ROSA-HCP completed"
      rosa upgrade cluster -y -m auto --version ${UPGRADE_VERSION} -c ${CLUSTER_ID} --control-plane 1> "${TEMP_DIR}/update_info.txt" 2>&1 || true

      upgrade_info=$(cat "${TEMP_DIR}/update_info.txt")
      if [[ "$upgrade_info" == *"There is already"* ]]; then
        echo "INFO: Waiting for the previous upgrade schedule to be removed."
        sleep 120
      else
        echo "INFO: ${upgrade_info}"
        break
      fi
    done
    cp_end_time=$(date +"%s")
    cp_upgrade_duration=$((cp_end_time - cp_start_time))

    echo "INFO: Control Plane upgrade of ROSA-HCP:${CLUSTER_ID} is now completed in ${cp_upgrade_duration} seconds"

    echo "INFO: Wait till all operators are available"
        _wait_for co --all Available=True 10
        _wait_for co --all Progressing=False 10
        _wait_for co --all Degraded=False 10
}

hcp_kb_cdv2(){
    echo "INFO: Install Cluster-density-v2 on the ROSA-HCP"
    pushd "/Users/krvoora/Desktop/mu-ms/cdv2"
    NODE_COUNT=`oc get no --no-headers | grep -v infra | wc -l`
    ITERATIONS=$(( NODE_COUNT * 9 ))
    kube-burner-ocp cluster-density-v2 --iterations=${ITERATIONS} --churn=false --gc=false .
    popd
}

hcp_install_dittybopper(){
    echo "INFO: Install Dittybopper on the ROSA-HCP ${CLUSTER_ID}"
    pushd "${TEMP_DIR}"
    git clone https://github.com/cloud-bulldozer/performance-dashboards
    cd performance-dashboards/dittybopper
    ./deploy.sh
    popd
}

hcp_mp_upgrade(){
    echo "INFO: Get recommended version for ROSA-hcp ${CLUSTER_ID} machinepool"
    mp_list=$(rosa list machinepool -c ${CLUSTER_ID} -o json | jq -r ".[].id")
    mp_recommended_version=$(rosa list upgrade --machinepool workers-0 -c ${CLUSTER_ID} | grep -v 'no available upgrades' | grep 'recommended' | cut -d ' ' -f1 || true)

    # Start timer for MachinePool Scaling
    mp_start_time=$(date +"%s")

    # Iterate over machine pool IDs correctly
    for mp_id in ${mp_list}; do
        echo "Upgrading the MP ${mp_id} part of ${CLUSTER_ID}"
        rosa upgrade machinepool ${mp_id} -y -c ${CLUSTER_ID} --version ${mp_recommended_version}
    done

    sleep 600

    for mp_id in ${mp_list}; do
        start_time=$(date +"%s")
        while true; do
            sleep 120
            echo "INFO: Wait for the node upgrade for the $mp_id machinepool finished"
            node_version=$(rosa list machinepool -c ${CLUSTER_ID} -o json | jq -r --arg k ${mp_id} '.[] | select(.id==$k) .version.raw_id')
            if [[ "${node_version}" == "${mp_recommended_version}" ]]; then
                end_time=$(date +"%s")
                upgrade_durations=$(( end_time - start_time ))
                echo "INFO: Machinepool:$mp_id upgraded successfully to the OCP version ${mp_recommended_version} after ${upgrade_durations} seconds"
                break
            fi

            if (( $(date +"%s") - ${start_time} >= ${NODE_UPGRADE_TIMEOUT} )); then
                echo "ERROR: Timed out while waiting for the machinepool upgrading to be ready"
                rosa list machinepool -c ${CLUSTER_ID}
                exit 1
            fi
        done
    done

    echo "INFO: Wait till all operators are available"
        _wait_for co --all Available=True 10
        _wait_for co --all Progressing=False 10
        _wait_for co --all Degraded=False 10
}

hcp_update_max_surge_unavailable(){
    echo "INFO: Fetch machinepools for ROSA-hcp ${CLUSTER_ID}"
    mp_list=$(rosa list machinepool -c ${CLUSTER_ID} -o json | jq -r ".[].id")

    for mp_id in ${mp_list}; do
        echo "INFO: Patching maxSurge and maxUnavailable for machinepool ${mp_id} in ROSA-HCP:${CLUSTER_ID}"
        # Do this manually until OCM-9340 is fixed
        rosa edit machinepool --max-surge=${MAX_SURGE} --max-unavailable=${MAX_UNAVAILABLE} --cluster=${CLUSTER_ID} ${mp_id}

        echo "INFO: Print maxSurge & maxUnavailable details for all machinepools in ROSA-HCP:${CLUSTER_ID}"
        rosa list machinepool --cluster=${CLUSTER_ID} -ojson | jq '.[] | {id: .id,max_surge: .management_upgrade.max_surge, max_unavailable: .management_upgrade.max_unavailable, auto_repair: .auto_repair, version: .version.raw_id}'
    done
}

kube-burner-index(){
    echo "INFO: Indexing the cluster results"
    pushd "${TEMP_DIR}"
    git clone https://github.com/cloud-bulldozer/e2e-benchmarking
    cd workloads/kube-burner-ocp-wrapper
    START_TIME=${START_TIME} END_TIME=${START_TIME} MC_KUBECONFIG=/tmp/kubeconfig_perf2  WORKLOAD=index ./run.sh
}

# Install Dittybopper
# hcp_install_dittybopper

# Upgrade Control Plane & Report Timings
# hcp_cp_upgrade

# Install Cluster Density v2 on the cluster
# hcp_kb_cdv2

# Apply maxSurge & maxUnavailable
# hcp_update_max_surge_unavailable

# Upgrade NodePool & Report Timings
hcp_mp_upgrade

# Perform indexing
kube-burner-index