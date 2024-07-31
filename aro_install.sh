#!/usr/bin/env bash
set -ex

# Declare variables
export ARO_RESOURCE_GROUP=${ARO_RESOURCE_GROUP:-"v413"}
export LOCATION=${LOCATION:-"eastus"}
export ARO_VIRTUAL_NET="kv-413-vnet"
export ARO_MASTER_SUBNET=${ARO_MASTER_SUBNET:-"master-subnet"}
export ARO_WORKER_SUBNET=${ARO_WORKER_SUBNET:-"worker-subnet"}
export ARO_CLUSTER_NAME=${ARO_CLUSTER_NAME:-"v413cs"}
export ARO_SDN_TYPE=${ARO_SDN_TYPE:-"OVNKubernetes"}
export ARO_API_VISIBILITY=${ARO_API_VISIBILITY:-"Public"}
export ARO_INGRESS_VISIBILITY=${ARO_INGRESS_VISIBILITY:-"Public"}
export ARO_MASTER_SIZE=${ARO_MASTER_SIZE:-"Standard_D8s_v3"}
export ARO_WORKER_SIZE=${ARO_WORKER_SIZE:-"Standard_D8s_v3"}
export ARO_WORKER_COUNT=${ARO_WORKER_COUNT:-3}
export ARO_REQUIRED_REPLICAS=${ARO_REQUIRED_REPLICAS:-8}
export ARO_INFRA_SIZE=${ARO_INFRA_SIZE:-"Standard_E4s_v3"}
export VERSION="${VERSION:-$(az aro get-versions --location ${LOCATION} -o json | jq '.[-2]' -r)}"
export UUID="${UUID:-$(uuidgen | tr '[:upper:]' '[:lower:]')}"
export TEMP_DIR="$(mktemp -d)"
export KUBECONFIG="${TEMP_DIR}/kubeconfig"
export PULL_SECRET="${HOME}/pull-secret.txt"

# ES_SERVER Details
export ES_SERVER="${ES_SERVER=XXX}"
export _es_index="${ES_INDEX:-}"

aro_verify_permissions() {

    echo "INFO: Azure account information"
    az account show

    echo "INFO: Current Subscription DSv5 Quota"
    az vm list-usage -l $LOCATION --query "[?contains(name.value, 'standardDSv3Family')]" -o table

    echo "INFO: Current Subscription ESv5 Quota for Infrastructure Nodes"
    az vm list-usage -l $LOCATION --query "[?contains(name.value, 'standardESv3Family')]" -o table

    echo "INFO: Registering the resource providers"
    az provider register -n Microsoft.RedHatOpenShift --wait
    az provider register -n Microsoft.Compute --wait
    az provider register -n Microsoft.Storage --wait
    az provider register -n Microsoft.Authorization --wait
    az feature register --namespace Microsoft.RedHatOpenShift --name preview
}

aro_create() {
    echo "INFO: Verifying Permissions"
    aro_verify_permissions

    echo "INFO: Creating a Resource Group"
    az group create --name $ARO_RESOURCE_GROUP --location $LOCATION

    echo "INFO: Extending expiry date"
    az group update --name $ARO_RESOURCE_GROUP --tags openshift_expiryDate=2025-12-25

    echo "INFO: Creating Virtual Network"
    az network vnet create --name $ARO_VIRTUAL_NET --resource-group $ARO_RESOURCE_GROUP --location $LOCATION --address-prefixes "10.0.0.0/22"

    echo "INFO: Creating Master Subnet"
    az network vnet subnet create --name $ARO_MASTER_SUBNET --resource-group $ARO_RESOURCE_GROUP --vnet-name $ARO_VIRTUAL_NET --address-prefix "10.0.0.0/23"

    echo "INFO: Creating Worker Subnet"
    az network vnet subnet create --name $ARO_WORKER_SUBNET --resource-group $ARO_RESOURCE_GROUP --vnet-name $ARO_VIRTUAL_NET --address-prefix "10.0.2.0/23"

    start_time=$(date +%s)
    echo "INFO: Creating ARO Cluster"
    az aro create --name ${ARO_CLUSTER_NAME} \
	--resource-group ${ARO_RESOURCE_GROUP} \
	--vnet ${ARO_VIRTUAL_NET} \
	--master-subnet ${ARO_MASTER_SUBNET} \
	--master-vm-size ${ARO_MASTER_SIZE} \
	--worker-subnet ${ARO_WORKER_SUBNET} \
	--worker-count ${ARO_WORKER_COUNT} \
	--worker-vm-size ${ARO_WORKER_SIZE} \
	--apiserver-visibility ${ARO_API_VISIBILITY} \
	--ingress-visibility ${ARO_INGRESS_VISIBILITY} \
	--version ${VERSION} \
	--pull-secret ${PULL_SECRET} \
	--verbose

    end_time=$(date +%s)
    cluster_install_time=$((end_time - start_time))

    echo "INFO: Get Kubeadmin Config"
    az aro get-admin-kubeconfig --name $ARO_CLUSTER_NAME --resource-group $ARO_RESOURCE_GROUP -f ${TEMP_DIR}/kubeconfig
    sleep 600

    # Capture & Create cluster-admin login

    # echo "INFO: We are going to Perform OCP Upgrade"
    ## Add logic to check if the condition is true

    echo "INFO: Creating Infrastructure Nodes"
    aro_infra_create_move

    echo "INFO: Scaling the Worker Nodes"
    sleep 180
    aro_scale

    echo "INFO: Indexing Results"
    #aro_install_index_results "$cluster_install_time" "$ARO_MASTER_SIZE" "$ARO_WORKER_SIZE" "$ARO_INFRA_SIZE" "$time_taken_scale"
}

aro_infra_create_move(){
    echo "INFO: MOBB Helm Chart for adding ARO machinesets"
    helm repo remove mobb | true
    helm repo add mobb https://rh-mobb.github.io/helm-charts/
    helm repo update

    cat << EOF > "${TEMP_DIR}/values.yaml"
machineRole: "infra"

vmSize: ${ARO_INFRA_SIZE}

machineLabels:
  node-role.kubernetes.io/infra: ""

machineTaints:
  - key: "node-role.kubernetes.io/infra"
    effect: "NoSchedule"
EOF

    echo "INFO: Installing the Helm Chart"
    helm upgrade --install -f "${TEMP_DIR}/values.yaml" -n openshift-machine-api infra mobb/aro-machinesets
    sleep 500

    # Condition to check if Nodes are in running state

    # Ingress
    echo "INFO: Moving Ingress Controller Operator Pods to Infra Nodes"
    oc patch -n openshift-ingress-operator ingresscontroller default --type=merge \
        -p='{"spec":{"replicas":3,"nodePlacement":{"nodeSelector":{"matchLabels":{"node-role.kubernetes.io/infra":""}},"tolerations":[{"effect":"NoSchedule","key":"node-role.kubernetes.io/infra","operator":"Exists"}]}}}'
    
    # Registry
    echo "INFO: Moving Registry Pods to Infra Nodes"
    oc patch configs.imageregistry.operator.openshift.io/cluster --type=merge \
        -p='{"spec":{"affinity":{"podAntiAffinity":{"preferredDuringSchedulingIgnoredDuringExecution":[{"podAffinityTerm":{"namespaces":["openshift-image-registry"],"topologyKey":"kubernetes.io/hostname"},"weight":100}]}},"logLevel":"Normal","managementState":"Managed","nodeSelector":{"node-role.kubernetes.io/infra":""},"tolerations":[{"effect":"NoSchedule","key":"node-role.kubernetes.io/infra","operator":"Exists"}]}}'

    # Cluster Monitoring
    echo "INFO: Moving Cluster Monitoring Stack to Infra Nodes"

cat << EOF | oc apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-monitoring-config
  namespace: openshift-monitoring
data:
  config.yaml: |+
    alertmanagerMain:
      nodeSelector:
        node-role.kubernetes.io/infra: ""
      tolerations:
        - effect: "NoSchedule"
          key: "node-role.kubernetes.io/infra"
          operator: "Exists"
    prometheusK8s:
      nodeSelector:
        node-role.kubernetes.io/infra: ""
      tolerations:
        - effect: "NoSchedule"
          key: "node-role.kubernetes.io/infra"
          operator: "Exists"
    prometheusOperator: {}
    grafana:
      nodeSelector:
        node-role.kubernetes.io/infra: ""
      tolerations:
        - effect: "NoSchedule"
          key: "node-role.kubernetes.io/infra"
          operator: "Exists"
    k8sPrometheusAdapter:
      nodeSelector:
        node-role.kubernetes.io/infra: ""
      tolerations:
        - effect: "NoSchedule"
          key: "node-role.kubernetes.io/infra"
          operator: "Exists"
    kubeStateMetrics:
      nodeSelector:
        node-role.kubernetes.io/infra: ""
      tolerations:
        - effect: "NoSchedule"
          key: "node-role.kubernetes.io/infra"
          operator: "Exists"
    telemeterClient:
      nodeSelector:
        node-role.kubernetes.io/infra: ""
      tolerations:
        - effect: "NoSchedule"
          key: "node-role.kubernetes.io/infra"
          operator: "Exists"
    openshiftStateMetrics:
      nodeSelector:
        node-role.kubernetes.io/infra: ""
      tolerations:
        - effect: "NoSchedule"
          key: "node-role.kubernetes.io/infra"
          operator: "Exists"
    thanosQuerier:
      nodeSelector:
        node-role.kubernetes.io/infra: ""
      tolerations:
        - effect: "NoSchedule"
          key: "node-role.kubernetes.io/infra"
          operator: "Exists"
EOF

}

aro_scale(){

    ## Add the Load Balancer
    echo "INFO: Increasing the Load Balancer"
    az aro update -n ${ARO_CLUSTER_NAME} -g ${ARO_RESOURCE_GROUP} --lb-ip-count 5

    # Capture Machineset details
    echo "INFO: Capture machineset details to scale"
    worker_machinesets=$(oc get machineset -n openshift-machine-api --selector='machine.openshift.io/cluster-api-machine-role=worker' --output=jsonpath='{.items[*].metadata.name}')
    
    echo "INFO: Worker Machineset Information ${worker_machinesets}"

    for machineset_name in $worker_machinesets; do
        oc scale machineset $machineset_name -n openshift-machine-api --replicas=$ARO_REQUIRED_REPLICAS
        echo "Scaled machineset $machineset_name to ${ARO_REQUIRED_REPLICAS} replicas."
    done

    echo "INFO: Scale the Worker Nodes and capture the timings"
    local all_running=false
    local iteration=0
    start_time=$(date +%s)

    while [ "$all_running" == false ]; do
        ((iteration++))

        # Get the machine information
        machines_info=$(oc get machines -o json -n openshift-machine-api)

        # Check each machine's status
        all_running=true
        while IFS= read -r line; do
        # Extract machine status and creation timestamp
        node_status=$(echo "$line" | jq -r '.status.phase')

        # Check if the machine is not in the "Running" state
        if [ "$node_status" != "Running" ]; then
            if [ "$node_status" == "Failed" ]; then
            echo "Machine $(echo "$line" | jq -r '.metadata.name') is in 'Failed' state. Exiting the script."
            exit 1
            fi
            all_running=false
            break
        fi
        done <<< "$(echo "$machines_info" | jq -c '.items[]')"

        # If all machines are not in the "Running" state, wait and continue the loop
        if [ "$all_running" == false ]; then
        sleep 30
        end_time=$(date +%s)
        time_taken_scale=$((end_time - start_time))
        echo "Iteration $iteration: Not all machines are in the 'Running' state. Waiting... Time taken: $time_taken_scale seconds"
        fi
    done

    echo "All machines are in the 'Running' state after $iteration iterations. Total time taken: $time_taken_scale seconds."

}

aro_install_index_results(){
    METADATA=$(cat <<EOF
{
  "uuid": "${UUID}",
  "platform": "ARO",
  "cluster_name": "${ARO_CLUSTER_NAME}",
  "network_type": "$(oc get network cluster -o json 2>/dev/null | jq -r .status.networkType)",
  "install_duration": "$1",
  "master_type": "$2",
  "worker_type": "$3",
  "infra_type": "$4",
  "scale_time": "$5",
  "master_count": "$(oc get node -l node-role.kubernetes.io/master= --no-headers 2>/dev/null | wc -l)",
  "worker_count": "$(oc get node --no-headers -l node-role.kubernetes.io/workload!="",node-role.kubernetes.io/infra!="",node-role.kubernetes.io/worker="" 2>/dev/null | wc -l)",
  "infra_count": "$(oc get node -l node-role.kubernetes.io/infra= --no-headers --ignore-not-found 2>/dev/null | wc -l)",
  "workload_count": "$(oc get node -l node-role.kubernetes.io/workload= --no-headers --ignore-not-found 2>/dev/null | wc -l)",
  "total_node_count": "$(oc get nodes 2>/dev/null | wc -l)",
  "ocp_infra_name": "$(oc get infrastructure.config.openshift.io cluster -o json 2>/dev/null | jq -r .status.infrastructureName)",
  "timestamp": "$(date +%s%3N)",
  "cluster_version": "${VERSION}"
}
EOF
)
    printf "Indexing installation timings to ${ES_SERVER}/${_es_index}"
    curl -k -sS -X POST -H "Content-type: application/json" ${ES_SERVER}/${_es_index}/_doc -d "${METADATA}" -o /dev/null
    return 0
}

aro_create
