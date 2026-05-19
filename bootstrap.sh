#!/bin/bash
set -e

# Phased one-click install: RHOAI 3.4 + MaaS (rhoai-3_4/)
TIMEOUT_SECONDS=45
KUSTOMIZE_DIR="rhoai-3_4"

# shellcheck source=/dev/null
source "$(dirname "$0")/scripts/functions.sh"
source "$(dirname "$0")/scripts/util.sh"
source "$(dirname "$0")/scripts/command_flags.sh" "$@"

setup_bin
check_bin oc
check_bin kustomize
check_oc_login

CLUSTER_DOMAIN=$(get_cluster_domain)
echo "Cluster ingress domain: ${CLUSTER_DOMAIN}"
echo ""

# Phase 1: Core + observability operators
echo "Phase 1: overlays/01-operators"
apply_overlay "${KUSTOMIZE_DIR}" "01-operators"

wait_for_install_plan_completion "openshift-nfd" "nfd"
wait_for_install_plan_completion "nvidia-gpu-operator" "gpu-operator-certified"
wait_for_install_plan_completion "cert-manager-operator" "openshift-cert-manager-operator"
wait_for_install_plan_completion "rh-connectivity-link" "rhcl-operator"
wait_for_install_plan_completion "openshift-lws-operator" "leader-worker-set"
wait_for_install_plan_completion "redhat-ods-operator" "rhods-operator"
wait_for_observability_operators

patch_rhcl_gateway_controller_names

# Phase 2: NFD, NVIDIA, LWS, RHCL/Kuadrant
apply_overlay "${KUSTOMIZE_DIR}" "02-nfd-nvidia-lws-instances"

# Phase 3: Gateway
echo "Phase 3: overlays/03-gateway (hostname: maas.${CLUSTER_DOMAIN})"
patch_gateway_hostname "${CLUSTER_DOMAIN}" "${KUSTOMIZE_DIR}"

# Phase 4: DataScienceCluster
apply_overlay "${KUSTOMIZE_DIR}" "04-rhoai"
wait_for_datascience_cluster

# Phase 10: DSCInitialization monitoring (observability dashboard)
apply_overlay "${KUSTOMIZE_DIR}" "10-observability-dashboard-rhoai"

# Phase 5: ODH dashboard config
apply_overlay "${KUSTOMIZE_DIR}" "05-odhdashboard"

# Phase 6: Postgres
apply_overlay "${KUSTOMIZE_DIR}" "06-postgres"
wait_for_postgres

configure_authorino_tls

# Phase 7: MaaS controller CRDs, RBAC, policies
apply_overlay "${KUSTOMIZE_DIR}" "07-maas-controller"

# Phase 8: Simulated models
apply_overlay "${KUSTOMIZE_DIR}" "08-simulated-models"

# Phase 9: MaaS subscriptions
apply_overlay "${KUSTOMIZE_DIR}" "09-maas-subscriptions"

echo ""
echo "=========================================================================="
echo " Bootstrap complete."
echo "=========================================================================="
echo ""
echo "Gateway: https://maas.${CLUSTER_DOMAIN}"
echo ""
echo "Manual checks if something fails:"
echo "  - Secret cert-manager-ingress-cert in openshift-ingress (Gateway TLS)"
echo "  - maas-api DB env from secret maas-db-config (see postgres/maas-api.yaml)"
echo "  - Validation: https://opendatahub-io.github.io/models-as-a-service/latest/install/validation/"
echo ""
