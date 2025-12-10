#!/bin/bash
# cleanup-nncp.sh - Gracefully cleanup NodeNetworkConfigurationPolicies
# Usage: cleanup-nncp.sh

set -e

echo "=================================================="
echo "NNCP Cleanup: Setting state to absent"
echo "=================================================="

# Phase 1: Patch all test NNCPs to state=absent
echo "Phase 1: Patching NNCPs to state=absent..."
SIMPLE_NNCPS=$(oc get nncp -l test-type=nic-hotplug-simple -o name 2>/dev/null || true)
VLAN_NNCPS=$(oc get nncp -l test-type=nic-hotplug-vlan -o name 2>/dev/null || true)

if [ -n "$SIMPLE_NNCPS" ]; then
    echo "  Found simple bridge NNCPs:"
    echo "$SIMPLE_NNCPS" | while read -r nncp; do
        echo "    Setting $nncp to absent..."
        oc patch "$nncp" --type=merge -p '{"spec":{"desiredState":{"interfaces":[{"name":"br-scale","state":"absent","type":"linux-bridge"}]}}}' || true
    done
fi

if [ -n "$VLAN_NNCPS" ]; then
    echo "  Found VLAN bridge NNCPs:"
    echo "$VLAN_NNCPS" | while read -r nncp; do
        echo "    Setting $nncp to absent..."
        oc patch "$nncp" --type=merge -p '{"spec":{"desiredState":{"interfaces":[{"name":"br-scale","state":"absent","type":"linux-bridge"}]}}}' || true
    done
fi

# Phase 2: Wait for NNCPs to become Available (bridges removed)
echo ""
echo "Phase 2: Waiting for NNCPs to process state=absent..."
sleep 15

# Phase 3: Delete the NNCP objects
echo ""
echo "Phase 3: Deleting NNCP objects..."
if [ -n "$SIMPLE_NNCPS" ]; then
    echo "  Deleting simple bridge NNCPs..."
    oc delete nncp -l test-type=nic-hotplug-simple --wait=true --timeout=2m || true
fi

if [ -n "$VLAN_NNCPS" ]; then
    echo "  Deleting VLAN bridge NNCPs..."
    oc delete nncp -l test-type=nic-hotplug-vlan --wait=true --timeout=2m || true
fi

echo ""
echo "=================================================="
echo "NNCP Cleanup: Complete"
echo "=================================================="

