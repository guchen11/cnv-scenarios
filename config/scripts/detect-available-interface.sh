#!/bin/bash
#
# Auto-detect available network interfaces on worker nodes
# Returns the first unused physical interface that can be used for NIC hot-plug testing
#

set -e

# Get list of worker nodes
WORKER_NODES=$(oc get nodes -l node-role.kubernetes.io/worker= -o jsonpath='{.items[*].metadata.name}')

if [ -z "$WORKER_NODES" ]; then
    echo "ERROR: No worker nodes found" >&2
    exit 1
fi

# Function to check if an interface is available on a node
check_interface_available() {
    local node=$1
    local interface=$2
    
    # Note: oc debug outputs extra lines, so we use grep -q for boolean checks
    # and filter output to handle multi-line responses
    
    # Check if interface exists
    if ! oc debug "node/${node}" -- chroot /host ip link show "$interface" 2>/dev/null | grep -q "$interface"; then
        return 1
    fi
    
    # Check if interface has an IP address (should not for testing)
    if oc debug "node/${node}" -- chroot /host ip addr show "$interface" 2>/dev/null | grep -q "inet "; then
        return 1
    fi
    
    # Check if interface is already in a bridge
    if oc debug "node/${node}" -- chroot /host ip link show "$interface" 2>/dev/null | grep -q "master "; then
        return 1
    fi
    
    # Check if interface has default route
    if oc debug "node/${node}" -- chroot /host ip route show dev "$interface" 2>/dev/null | grep -q "default"; then
        return 1
    fi
    
    return 0
}

# Function to get physical interfaces on a node
get_physical_interfaces() {
    local node=$1
    
    # Get list of physical interfaces (exclude virtual, loopback, etc.)
    oc debug "node/${node}" -- chroot /host ls -1 /sys/class/net/ 2>/dev/null | grep -E "^(eth|ens|enp|em)" || echo ""
}

# Try to find a common available interface across all worker nodes
echo "Detecting available interfaces on worker nodes..." >&2

FIRST_NODE=$(echo "$WORKER_NODES" | awk '{print $1}')

echo "Checking node: $FIRST_NODE" >&2
CANDIDATE_INTERFACES=$(get_physical_interfaces "$FIRST_NODE")

if [ -z "$CANDIDATE_INTERFACES" ]; then
    echo "ERROR: No physical interfaces found on node $FIRST_NODE" >&2
    exit 1
fi

# Check each candidate interface
for interface in $CANDIDATE_INTERFACES; do
    echo "Checking interface: $interface" >&2
    
    # Check if this interface is available on all worker nodes
    available_on_all=true
    
    for node in $WORKER_NODES; do
        if ! check_interface_available "$node" "$interface"; then
            echo "  Interface $interface not available on node $node" >&2
            available_on_all=false
            break
        fi
    done
    
    if [ "$available_on_all" = true ]; then
        echo "Found available interface: $interface" >&2
        echo "$interface"
        exit 0
    fi
done

echo "ERROR: No available interface found across all worker nodes" >&2
echo "Please specify baseInterface manually in vars.yml" >&2
exit 1

