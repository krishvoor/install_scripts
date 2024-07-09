#!/usr/bin/env bash
set -ex

# Declare variables
export CLUSTER_ID=${CLUSTER_ID:-""}
export UUID="${UUID:-$(uuidgen | tr '[:upper:]' '[:lower:]')}"
export TEMP_DIR="$(mktemp -d)"
export KUBECONFIG=${KUBECONFIG:-""}
export NODE_UPGRADE_TIMEOUT=${NODE_UPGRADE_TIMEOUT:-"7200"}

# Declare associative array to store upgrade durations
declare -A upgrade_durations

# ES_SERVER Details
export ES_SERVER="${ES_SERVER=XXX}"
export _es_index="${ES_INDEX:-}"

hcp_cp_upgrade(){

    echo "INFO: Capture ROSA-HCP Upgrade Version"
    UPGRADE_VERSION=rosa list upgrade -c ${CLUSTER_ID} | grep -v 'no available upgrades' | grep 'recommended' | cut -d ' ' -f1
    
    cp_start_time=$(date +"%s")
    echo "INFO: Perform ROSA-HCP Upgrade to ${UPGRADE_VERSION}"
    rosa upgrade cluster -y -m auto --version {UPGRADE_VERSION} -c ${CLUSTER_ID} --control-plane
    sleep 600
    
    echo "INFO: Iterate over rosa list upgrade to understand if ugprade is completed"
    while true; do
      if (( $(date +"%s") - $start_time >= 1800 )); then
        echo "ERROR: Timed out while waiting for the previous upgrade schedule to be removed."
        exit 1
      fi

      echo "INFO: Check if the ROSA-HCP completed"
      rosa upgrade cluster -y -m auto --version {UPGRADE_VERSION} -c ${CLUSTER_ID} --control-plane 1> "${TEMP_DIR}/update_info.txt" 2>&1 || true

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
}

hcp_kb_cdv2(){
    echo "INFO: Install Cluster-density-v2 on the ROSA-HCP"
    pushd "/Users/krvoora/Desktop/mu-ms/cdv2"
    kube-burner-ocp cluster-density-v2 --iterations-216 --churn=false --gc=false .
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
    mp_recommended_version=$(rosa list upgrade --machinepool workers-0 -c ${CLUSTER_ID} | grep -v 'no available upgrades' | grep 'recommended'| cut -d ' ' -f1 || true)

    # Start timer for MachinePool Scaling
    mp_start_time=$(date +"%s")
    for mp_id in mp_list; do
        echo "Upgrading the MP ${mp_id} part of ${CLUSTER_ID}"
        rosa upgrade machinepool ${mp_id} -y -c ${CLUSTER_ID} --version ${mp_recommended_version}
    done

    for mp_id in mp_list; do
        start_time=$(date +"%s")
        while true; do
            sleep 120
            echo "INFO: Wait for the node upgrade for the $mp_id machinepool finished"
            node_version=$(rosa list machinepool -c ${CLUSTER_ID} -o json | jq -r --arg k ${mp_id} '.[] | select(.id==$k) .version.raw_id')
            if [[ "${node_version}" == ${mp_recommended_version} ]]; then
                end_time=$(date +"%s")
                upgrade_durations[$mp_id]=$(( end_time - start_time ))
                echo "INFO: "Machinepool:$mp_id upgraded successfully to the OCP version ${mp_recommended_version} after ${upgrade_duration} seconds""
                break
            fi

            if (( $(date +"%s") - start_time >= $NODE_UPGRADE_TIMEOUT )); then
            echo "ERROR: Timed out while waiting for the machinepool upgrading to be ready"
            rosa list machinepool -c ${CLUSTER_ID}
            exit 1
            fi
        done
    done
}

hcp_update_max_surge(){
    echo "INFO: "
}

hcp_update_max_unavailable(){
    echo "INFO: "
}