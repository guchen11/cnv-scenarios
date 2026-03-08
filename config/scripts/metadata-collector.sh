#!/bin/bash
#
# metadata-collector.sh - Collect OCP cluster and environment metadata
#
# Gathers cluster version, node hardware, operator versions, storage classes,
# and test configuration. Outputs metadata.json and optionally indexes to
# Elasticsearch for correlation with kube-burner metrics via UUID.
#
# Usage:
#   metadata-collector.sh \
#     --uuid <kube-burner-uuid> \
#     --test-name <test-name> \
#     --mode <sanity|full> \
#     --run-timestamp <run-YYYYMMDD-HHMMSS> \
#     --vars-file <path-to-temp-vars> \
#     --results-dir <path-to-results> \
#     [--es-server <url>] \
#     [--metadata-index <name>] \
#     [--test-index <name>]
#

set -eo pipefail

# =============================================================================
# ARGUMENT PARSING
# =============================================================================

UUID=""
TEST_NAME=""
MODE=""
RUN_TIMESTAMP=""
VARS_FILE=""
RESULTS_DIR=""
ES_SERVER=""
METADATA_INDEX="cnv-metadata"
TEST_INDEX=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --uuid)          UUID="$2";          shift 2 ;;
        --test-name)     TEST_NAME="$2";     shift 2 ;;
        --mode)          MODE="$2";          shift 2 ;;
        --run-timestamp) RUN_TIMESTAMP="$2"; shift 2 ;;
        --vars-file)     VARS_FILE="$2";     shift 2 ;;
        --results-dir)   RESULTS_DIR="$2";   shift 2 ;;
        --es-server)     ES_SERVER="$2";     shift 2 ;;
        --metadata-index) METADATA_INDEX="$2"; shift 2 ;;
        --test-index)    TEST_INDEX="$2";    shift 2 ;;
        *)
            echo "metadata-collector: Unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

if [[ -z "$UUID" || -z "$TEST_NAME" || -z "$RESULTS_DIR" ]]; then
    echo "metadata-collector: --uuid, --test-name, and --results-dir are required" >&2
    exit 1
fi

mkdir -p "$RESULTS_DIR"

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

get_yaml_value() {
    local key="$1"
    local file="$2"
    local default="${3:-}"

    if [[ -f "$file" ]]; then
        local value
        value=$(grep "^${key}:" "$file" 2>/dev/null | head -1 | awk '{print $2}' | tr -d '"' | tr -d "'")
        if [[ -n "$value" ]]; then
            echo "$value"
            return
        fi
    fi
    echo "$default"
}

oc_safe() {
    oc "$@" 2>/dev/null || echo ""
}

# =============================================================================
# CLUSTER METADATA COLLECTION
# =============================================================================

echo "metadata-collector: Collecting cluster metadata for UUID=${UUID}..."

ocp_version=$(oc_safe get clusterversion version -o jsonpath='{.status.desired.version}')
cluster_id=$(oc_safe get clusterversion version -o jsonpath='{.spec.clusterID}')
platform=$(oc_safe get infrastructure cluster -o jsonpath='{.status.platform}')
api_url=$(oc_safe get infrastructure cluster -o jsonpath='{.status.apiServerURL}')
network_type=$(oc_safe get network.config cluster -o jsonpath='{.spec.networkType}')

# =============================================================================
# NODE INFORMATION
# =============================================================================

nodes_json=$(oc_safe get nodes -o json)

if [[ -n "$nodes_json" ]]; then
    node_total=$(echo "$nodes_json" | jq '.items | length')
    node_masters=$(echo "$nodes_json" | jq '[.items[] | select(.metadata.labels["node-role.kubernetes.io/master"] != null or .metadata.labels["node-role.kubernetes.io/control-plane"] != null)] | length')
    node_workers=$(echo "$nodes_json" | jq '[.items[] | select(.metadata.labels["node-role.kubernetes.io/worker"] != null)] | length')

    worker_details=$(echo "$nodes_json" | jq '[
        .items[]
        | select(.metadata.labels["node-role.kubernetes.io/worker"] != null)
        | {
            name: .metadata.name,
            cpuModel: (
                [.metadata.labels | to_entries[] | select(.key | startswith("host-model-cpu.node.kubevirt.io/")) | .key | ltrimstr("host-model-cpu.node.kubevirt.io/")] | first //
                .metadata.labels["feature.node.kubernetes.io/cpu-model.family"] //
                .metadata.labels["node.kubernetes.io/instance-type"] //
                "unknown"
            ),
            cpuCores: (.status.capacity.cpu // "0" | tonumber),
            memoryGiB: (((.status.capacity.memory // "0Ki" | gsub("Ki$"; "") | tonumber) / 1048576) | floor),
            architecture: (.status.nodeInfo.architecture // "unknown")
        }
    ]')
else
    node_total=0
    node_masters=0
    node_workers=0
    worker_details="[]"
fi

# =============================================================================
# OPERATOR VERSIONS
# =============================================================================

get_csv_version() {
    local namespace="$1"
    local pattern="$2"
    oc_safe get csv -n "$namespace" -o json | \
        jq -r --arg pat "$pattern" '
            [.items[] | select(.metadata.name | test($pat)) | .spec.version] | first // "N/A"
        '
}

cnv_version=$(get_csv_version "openshift-cnv" "kubevirt-hyperconverged-operator")
hco_version="$cnv_version"
odf_version=$(get_csv_version "openshift-storage" "odf-operator")
sriov_version=$(get_csv_version "openshift-sriov-network-operator" "sriov-network-operator")
nmstate_version=$(get_csv_version "openshift-nmstate" "kubernetes-nmstate-operator")

# =============================================================================
# STORAGE CLASSES
# =============================================================================

sc_json=$(oc_safe get sc -o json)

if [[ -n "$sc_json" ]]; then
    default_sc=$(echo "$sc_json" | jq -r '
        [.items[] | select(.metadata.annotations["storageclass.kubernetes.io/is-default-class"] == "true") | .metadata.name] | first // "none"
    ')
    storage_classes=$(echo "$sc_json" | jq '[
        .items[] | {
            name: .metadata.name,
            provisioner: .provisioner,
            reclaimPolicy: .reclaimPolicy
        }
    ]')
else
    default_sc="unknown"
    storage_classes="[]"
fi

# =============================================================================
# KUBE-BURNER VERSION
# =============================================================================

kb_version=""
kb_job_summary="${RESULTS_DIR}/iteration-1/jobSummary.json"
if [[ -f "$kb_job_summary" ]]; then
    kb_version=$(jq -r '.[0].version // ""' "$kb_job_summary" 2>/dev/null)
fi
if [[ -z "$kb_version" ]]; then
    kb_version=$(kube-burner version 2>/dev/null | head -1 || echo "unknown")
fi

# =============================================================================
# TEST CONFIGURATION (from vars file)
# =============================================================================

if [[ -n "$VARS_FILE" && -f "$VARS_FILE" ]]; then
    tc_vmCount=$(get_yaml_value "vmCount" "$VARS_FILE" "0")
    tc_cpuCores=$(get_yaml_value "cpuCores" "$VARS_FILE" "0")
    tc_memory=$(get_yaml_value "memory" "$VARS_FILE" "$(get_yaml_value "memorySize" "$VARS_FILE" "unknown")")
    tc_storage=$(get_yaml_value "storage" "$VARS_FILE" "unknown")
    tc_storageClassName=$(get_yaml_value "storageClassName" "$VARS_FILE" "unknown")
else
    tc_vmCount="0"
    tc_cpuCores="0"
    tc_memory="unknown"
    tc_storage="unknown"
    tc_storageClassName="unknown"
fi

# =============================================================================
# BUILD METADATA JSON
# =============================================================================

metadata_file="${RESULTS_DIR}/metadata.json"

jq -n \
    --arg uuid "$UUID" \
    --arg timestamp "$(date -Iseconds)" \
    --arg metricName "metadata" \
    --arg testName "$TEST_NAME" \
    --arg testMode "${MODE:-unknown}" \
    --arg runTimestamp "${RUN_TIMESTAMP:-unknown}" \
    --arg kubeBurnerVersion "$kb_version" \
    --arg ocpVersion "${ocp_version:-unknown}" \
    --arg clusterId "${cluster_id:-unknown}" \
    --arg platform "${platform:-unknown}" \
    --arg apiUrl "${api_url:-unknown}" \
    --arg networkType "${network_type:-unknown}" \
    --argjson nodeTotal "${node_total:-0}" \
    --argjson nodeMasters "${node_masters:-0}" \
    --argjson nodeWorkers "${node_workers:-0}" \
    --argjson workerDetails "${worker_details:-[]}" \
    --arg cnvVersion "${cnv_version:-N/A}" \
    --arg hcoVersion "${hco_version:-N/A}" \
    --arg odfVersion "${odf_version:-N/A}" \
    --arg sriovVersion "${sriov_version:-N/A}" \
    --arg nmstateVersion "${nmstate_version:-N/A}" \
    --arg defaultStorageClass "$default_sc" \
    --argjson storageClasses "$storage_classes" \
    --arg varsFile "${VARS_FILE:-}" \
    --argjson vmCount "${tc_vmCount}" \
    --argjson cpuCores "${tc_cpuCores}" \
    --arg memory "$tc_memory" \
    --arg storage "$tc_storage" \
    --arg storageClassName "$tc_storageClassName" \
    '{
        uuid: $uuid,
        timestamp: $timestamp,
        metricName: $metricName,
        testName: $testName,
        testMode: $testMode,
        runTimestamp: $runTimestamp,
        kubeBurnerVersion: $kubeBurnerVersion,
        cluster: {
            ocpVersion: $ocpVersion,
            clusterId: $clusterId,
            platform: $platform,
            apiUrl: $apiUrl,
            networkType: $networkType
        },
        nodes: {
            total: $nodeTotal,
            masters: $nodeMasters,
            workers: $nodeWorkers,
            workerDetails: $workerDetails
        },
        operators: {
            cnvVersion: $cnvVersion,
            hcoVersion: $hcoVersion,
            odfVersion: $odfVersion,
            sriovVersion: $sriovVersion,
            nmstateVersion: $nmstateVersion
        },
        storage: {
            defaultClass: $defaultStorageClass,
            classes: $storageClasses
        },
        testConfig: {
            varsFile: $varsFile,
            vmCount: $vmCount,
            cpuCores: $cpuCores,
            memory: $memory,
            storage: $storage,
            storageClassName: $storageClassName
        }
    }' > "$metadata_file"

echo "metadata-collector: Metadata saved to ${metadata_file}"

# =============================================================================
# ELASTICSEARCH INDEXING
# =============================================================================

if [[ -n "$ES_SERVER" ]]; then
    echo "metadata-collector: Indexing metadata to Elasticsearch..."

    # Index to dedicated metadata index
    response=$(curl -s -o /dev/null -w "%{http_code}" \
        -X POST "${ES_SERVER}/${METADATA_INDEX}/_doc" \
        -H 'Content-Type: application/json' \
        -k \
        -d @"$metadata_file" 2>/dev/null) || true

    if [[ "$response" == "201" || "$response" == "200" ]]; then
        echo "metadata-collector: Indexed to ${METADATA_INDEX} (HTTP ${response})"
    else
        echo "metadata-collector: WARNING: Failed to index to ${METADATA_INDEX} (HTTP ${response})" >&2
    fi

    # Index to per-test index if specified
    if [[ -n "$TEST_INDEX" ]]; then
        response=$(curl -s -o /dev/null -w "%{http_code}" \
            -X POST "${ES_SERVER}/${TEST_INDEX}/_doc" \
            -H 'Content-Type: application/json' \
            -k \
            -d @"$metadata_file" 2>/dev/null) || true

        if [[ "$response" == "201" || "$response" == "200" ]]; then
            echo "metadata-collector: Indexed to ${TEST_INDEX} (HTTP ${response})"
        else
            echo "metadata-collector: WARNING: Failed to index to ${TEST_INDEX} (HTTP ${response})" >&2
        fi
    fi
fi

echo "metadata-collector: Done."
