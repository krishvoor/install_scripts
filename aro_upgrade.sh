#!/usr/bin/env bash
set -ex

export aro_version_channel=${ARO_VERSION_CHANNEL:-candidate}
export ARO_RESOURCE_GROUP=${ARO_RESOURCE_GROUP:-krishvoor-120-5rg}
export _es_index=${ES_INDEX:-managedservices-timings}
export control_plane_waiting_iterations=${ARO_CONTROL_PLANE_WAITING:-100}
export waiting_per_worker=${ARO_WORKER_UPGRADE_TIME:-5}
export ARO_CLUSTER_NAME=$(oc get infrastructure.config.openshift.io cluster -o json 2>/dev/null | jq -r '.status.infrastructureName | sub("-[^-]+$"; "")')
export VERSION="4.13.24"
export UUID="${UUID:-$(uuidgen | tr '[:upper:]' '[:lower:]')}"
export KUBECONFIG="${HOME}/kubeconfig"
export ES_SERVER="${ES_SERVER=}"
export _es_index="${ES_INDEX:-}"

aro_upgrade(){
  if [ ${aro_version_channel} == "nightly" ] ; then
    echo "ERROR: Invalid channel group. Nightly versions cannot be upgraded. Exiting..."
    exit 1
  fi
  echo "ARO Cluster: ${ARO_CLUSTER_NAME}"
  echo "OCP Channel Group: ${aro_version_channel}"
  az account show

  if ! az aro list -g ${ARO_RESOURCE_GROUP} -o json | jq -r '.[].name' | grep -q "${ARO_CLUSTER_NAME}" ; then
    echo "ERROR: Cluster ${ARO_CLUSTER_NAME} not found on az aro list results. Exiting..."
    exit 1
  fi

  if [ -z ${VERSION} ] ; then
    echo "ERROR: No version to upgrade is given for the cluster ${ARO_CLUSTER_NAME}"
    exit 1
  else
    echo "INFO: Upgrading cluster ${ARO_CLUSTER_NAME} to ${VERSION} version..."
  fi

  echo "INFO: Patching the 4.13 Admin Acks"
  oc -n openshift-config patch cm admin-acks --patch '{"data":{"ack-4.12-kube-1.26-api-removals-in-4.13":"true"}}' --type=merge

  echo "INFO: Upgrading to 4.13 ${aro_version_channel} Channel"
  oc adm upgrade channel ${aro_version_channel}-4.13

  echo "INFO: OCP Upgrade to 4.13 kick-started"
  CURRENT_VERSION=$(oc get clusterversion | grep ^version | awk '{print $2}')
  oc adm upgrade --to=$VERSION --allow-not-recommended

  aro_cp_upgrade_active_waiting ${VERSION}
  if [ $? -eq 0 ] ; then
    CONTROLPLANE_UPGRADE_RESULT="OK"
  else
    CONTROLPLANE_UPGRADE_RESULT="Failed"
  fi
#  aro_workers_active_waiting
#  if [ $? -eq 0 ] ; then
#    WORKERS_UPGRADE_RESULT="OK"
#  else
#    WORKERS_UPGRADE_RESULT="Failed"
#  fi
  WORKERS_UPGRADE_DURATION="250"
  WORKERS_UPGRADE_RESULT="NA"
  aro_upgrade_index_results ${CONTROLPLANE_UPGRADE_DURATION} ${CONTROLPLANE_UPGRADE_RESULT} ${WORKERS_UPGRADE_DURATION} ${WORKERS_UPGRADE_RESULT} ${CURRENT_VERSION} ${VERSION}
  exit 0
}

aro_workers_active_waiting() {
  start_time=$(date +%s)
  WORKERS=$(oc get node --no-headers -l node-role.kubernetes.io/workload!="",node-role.kubernetes.io/infra!="",node-role.kubernetes.io/worker="" 2>/dev/null | wc -l)
  # Giving waiting_per_worker minutes per worker
  ITERATIONWORKERS=0
  VERSION_STATUS=($(oc get clusterversion | sed -e 1d | awk '{print $2" "$3" "$4}'))
  while [ ${ITERATIONWORKERS} -le $(( ${WORKERS}*${waiting_per_worker} )) ] ; do
    if [ ${VERSION_STATUS[0]} == $1 ] && [ ${VERSION_STATUS[1]} == "True" ] && [ ${VERSION_STATUS[2]} == "False" ]; then
      echo "INFO: Upgrade finished for ARO, continuing..."
      end_time=$(date +%s)
      export WORKERS_UPGRADE_DURATION=$((${end_time} - ${start_time}))
      return 0
    else
      LASTSTATUS=$(oc logs $(oc get pods -n openshift-managed-upgrade-operator -o Name | grep -v catalog) -n openshift-managed-upgrade-operator | grep "workers are upgraded" | tail -1)
      echo "INFO: ${ITERATIONWORKERS}/$(( ${WORKERS}*${waiting_per_worker} )). Last Update: ${LASTSTATUS}."
      echo "INFO: Waiting 60 seconds for the next check..."
      ITERATIONWORKERS=$((${ITERATIONWORKERS}+1))
      sleep 60
    fi
  done
  echo "ERROR: ${ITERATIONWORKERS}/$(( ${WORKERS}*${waiting_per_worker} )). ROSA workers upgrade not finished after $(( ${WORKERS}*${waiting_per_worker} )) iterations. Exiting..."
  end_time=$(date +%s)
  export WORKERS_UPGRADE_DURATION=$((${end_time} - ${start_time}))
  oc logs $(oc get pods -n openshift-managed-upgrade-operator -o Name | grep -v catalog) -n openshift-managed-upgrade-operator
  az aro list -o table
  return 1
}

aro_cp_upgrade_active_waiting() {
    # Giving control_plane_waiting_iterations minutes for controlplane upgrade
    start_time=$(date +%s)
    ITERATIONS=0
    while [ ${ITERATIONS} -le ${control_plane_waiting_iterations} ]; do
        VERSION_STATUS=($(oc get clusterversion | sed -e 1d | awk '{print $2" "$3" "$4}'))
        if [ ${VERSION_STATUS[0]} == $1 ] && [ ${VERSION_STATUS[1]} == "True" ] && [ ${VERSION_STATUS[2]} == "False" ]; then
            # Version is upgraded, available=true, progressing=false -> Upgrade finished
            echo "INFO: OCP upgrade to $1 is finished for OCP, now waiting for ARO..."
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

aro_upgrade_index_results() {
    METADATA=$(grep -v "^#" <<EOF
{
  "uuid": "${UUID}",
  "platform": "ARO",
  "cluster_name": "${ARO_CLUSTER_NAME}",
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

aro_upgrade
