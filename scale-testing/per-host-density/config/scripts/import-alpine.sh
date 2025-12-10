#!/bin/bash
#
# This script automates importing the latest Alpine Linux cloud image into an OpenShift
# project using a KubeVirt DataVolume. The resulting PVC can then be
# used as a "golden image" for creating new virtual machines.
#

set -eo pipefail # Exit immediately if a command exits with a non-zero status.

# --- Configuration ---
# You can update this URL if a newer version of Alpine Linux is released.
ALPINE_URL="https://dl-cdn.alpinelinux.org/alpine/v3.21/releases/cloud/generic_alpine-3.21.5-x86_64-bios-cloudinit-r0.qcow2"
DV_NAME="alpine-latest"
TIMEOUT_SECONDS=600 # 10 minutes max for the import
INTERVAL_SECONDS=10

# --- Helper Functions for Colored Output ---
c_red=$(tput setaf 1)
c_green=$(tput setaf 2)
c_yellow=$(tput setaf 3)
c_bold=$(tput bold)
c_reset=$(tput sgr0)

info() {
    echo "${c_bold}${c_green}▶${c_reset} ${c_bold}$1${c_reset}"
}

success() {
    echo "${c_bold}${c_green}✅ $1${c_reset}"
}

error() {
    echo "${c_bold}${c_red}❌ Error: $1${c_reset}" >&2
    exit 1
}

# --- Script Logic ---

# 1. Validate input and prerequisites
if [[ -z "$1" ]]; then
  echo "Usage: $0 <project-name>"
  echo "Example: $0 my-virtualization-project"
  exit 1
fi
PROJECT_NAME="$1"

if ! command -v oc &> /dev/null; then
  error "'oc' CLI not found. Please install the OpenShift CLI and ensure it's in your PATH."
fi

if ! oc whoami &> /dev/null; then
  error "You are not logged into an OpenShift cluster. Please run 'oc login' first."
fi

if ! oc get project "$PROJECT_NAME" &> /dev/null; then
  error "Project '$PROJECT_NAME' not found. You can create it with 'oc new-project $PROJECT_NAME'."
fi

info "Using project: $PROJECT_NAME"

# 2. Check if the DataVolume already exists
if oc get dv "$DV_NAME" -n "$PROJECT_NAME" &>/dev/null; then
    PHASE=$(oc get dv "$DV_NAME" -n "$PROJECT_NAME" -o jsonpath='{.status.phase}')
    if [[ "$PHASE" == "Succeeded" ]]; then
        success "DataVolume '$DV_NAME' already exists and is ready to use in project '$PROJECT_NAME'."
        exit 0
    else
        info "DataVolume '$DV_NAME' exists but is not in 'Succeeded' state. Deleting and recreating..."
        oc delete dv "$DV_NAME" -n "$PROJECT_NAME" --wait=true
    fi
fi

# 3. Create the DataVolume resource
info "Applying DataVolume manifest to import Alpine Linux..."
oc apply -n "$PROJECT_NAME" -f - <<EOF
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataVolume
metadata:
  name: ${DV_NAME}
spec:
  source:
    http:
      url: "${ALPINE_URL}"
  pvc:
    accessModes:
      - ReadWriteOnce
    resources:
      requests:
        storage: 5Gi
EOF

# 4. Monitor the import process
info "Waiting for the image import to complete. This may take a few minutes..."
SECONDS_WAITED=0
while true; do
  PHASE=$(oc get dv "$DV_NAME" -n "$PROJECT_NAME" -o jsonpath='{.status.phase}')
  PROGRESS=$(oc get dv "$DV_NAME" -n "$PROJECT_NAME" -o jsonpath='{.status.progress}')

  if [[ "$PHASE" == "Succeeded" ]]; then
    echo # Newline after progress bar
    success "Image import complete! The PVC '$DV_NAME' is ready."
    break
  fi

  if [[ "$PHASE" == "Failed" || "$PHASE" == "Error" ]]; then
    echo # Newline
    error "Import failed with phase: $PHASE. Please check the 'importer' pod logs in project '$PROJECT_NAME'."
  fi

  if (( SECONDS_WAITED >= TIMEOUT_SECONDS )); then
    echo # Newline
    error "Timeout reached while waiting for import to complete."
  fi

  # Print a dynamic progress line
  echo -ne "   ${c_yellow}Current phase: ${PHASE}, Progress: ${PROGRESS}${c_reset}\r"
  sleep $INTERVAL_SECONDS
  SECONDS_WAITED=$((SECONDS_WAITED + INTERVAL_SECONDS))
done

# 5. Final instructions
echo
info "Next Step: You can now create a Virtual Machine by cloning this PVC."
info "Use '${c_bold}${DV_NAME}${c_reset}' as the source PVC name in your VM manifest."
