#!/usr/bin/env bash

#Description: Kyma CLI Integration plan on Gardener. This scripts implements a pipeline that consists of many steps. The purpose is to install and test Reconciler end-to-end upgrade flow on a real Gardener cluster.
#
#Expected common vars:
# - JOB_TYPE - set up by prow (presubmit, postsubmit, periodic)
# - KYMA_PROJECT_DIR - directory path with Kyma sources to use for installation
# - GARDENER_REGION - Gardener compute region
# - GARDENER_ZONES - Gardener compute zones inside the region
# - GARDENER_CLUSTER_VERSION - Version of the Kubernetes cluster
# - GARDENER_KYMA_PROW_KUBECONFIG - Kubeconfig of the Gardener service account
# - GARDENER_KYMA_PROW_PROJECT_NAME - Name of the gardener project where the cluster will be integrated.
# - GARDENER_KYMA_PROW_PROVIDER_SECRET_NAME - Name of the secret configured in the gardener project to access the cloud provider
# - BOT_GITHUB_TOKEN: Bot github token used for API queries
# - MACHINE_TYPE - (optional) machine type
#
#Please look in each provider script for provider specific requirements

## ---------------------------------------------------------------------------------------
## Configurations and Variables
## ---------------------------------------------------------------------------------------

# exit on error, and raise error when variable is not set when used
set -e

ENABLE_TEST_LOG_COLLECTOR=false

# Exported variables
export TEST_INFRA_SOURCES_DIR="${KYMA_PROJECT_DIR}/test-infra"
export CONTROL_PLANE_RECONCILER_DIR="/home/prow/go/src/github.com/kyma-project/control-plane/tools/reconciler"
export TEST_INFRA_CLUSTER_INTEGRATION_SCRIPTS="${TEST_INFRA_SOURCES_DIR}/prow/scripts/cluster-integration/helpers"

# shellcheck source=prow/scripts/lib/log.sh
source "${TEST_INFRA_SOURCES_DIR}/prow/scripts/lib/log.sh"
# shellcheck source=prow/scripts/lib/utils.sh
source "${TEST_INFRA_SOURCES_DIR}/prow/scripts/lib/utils.sh"
# shellcheck source=prow/scripts/lib/kyma.sh
source "${TEST_INFRA_SOURCES_DIR}/prow/scripts/lib/kyma.sh"
# shellcheck source=prow/scripts/lib/gardener/gardener.sh
source "${TEST_INFRA_SOURCES_DIR}/prow/scripts/lib/gardener/gardener.sh"
# shellcheck source=prow/scripts/cluster-integration/helpers/reconciler.sh
source "${TEST_INFRA_CLUSTER_INTEGRATION_SCRIPTS}/reconciler.sh"

# All provides require these values, each of them may check for additional variables
requiredVars=(
    BOT_GITHUB_TOKEN
    GARDENER_PROVIDER
    KYMA_PROJECT_DIR
    GARDENER_REGION
    GARDENER_ZONES
    GARDENER_CLUSTER_VERSION
    GARDENER_KYMA_PROW_KUBECONFIG
    GARDENER_KYMA_PROW_PROJECT_NAME
    GARDENER_KYMA_PROW_PROVIDER_SECRET_NAME
)

utils::check_required_vars "${requiredVars[@]}"

if [[ $GARDENER_PROVIDER == "azure" ]]; then
    # shellcheck source=prow/scripts/lib/gardener/azure.sh
    source "${TEST_INFRA_SOURCES_DIR}/prow/scripts/lib/gardener/azure.sh"
elif [[ $GARDENER_PROVIDER == "aws" ]]; then
    # shellcheck source=prow/scripts/lib/gardener/aws.sh
    source "${TEST_INFRA_SOURCES_DIR}/prow/scripts/lib/gardener/aws.sh"
elif [[ $GARDENER_PROVIDER == "gcp" ]]; then
    # shellcheck source=prow/scripts/lib/gardener/gcp.sh
    source "${TEST_INFRA_SOURCES_DIR}/prow/scripts/lib/gardener/gcp.sh"
else
    log::error "GARDENER_PROVIDER ${GARDENER_PROVIDER} is not yet supported"
    exit 1
fi

# nice cleanup on exit, be it succesful or on fail
trap gardener::cleanup EXIT INT

# Used to detect errors for logging purposes
ERROR_LOGGING_GUARD="true"
export ERROR_LOGGING_GUARD

readonly COMMON_NAME_PREFIX="grd"
utils::generate_commonName -n "${COMMON_NAME_PREFIX}"

export INPUT_CLUSTER_NAME="${utils_generate_commonName_return_commonName:?}"

## Get Kyma latest release version
kyma::get_last_release_version \
    -t "${BOT_GITHUB_TOKEN}" \
    -v "^1."
LAST_RELEASE_1_VERSION="${kyma_get_last_release_version_return_version:?}"
log::info "### Reading latest 1.x release version, got: ${LAST_RELEASE_1_VERSION}"
export KYMA_SOURCE="${LAST_RELEASE_1_VERSION}"

## ---------------------------------------------------------------------------------------
## Prow job execution steps
## ---------------------------------------------------------------------------------------
log::banner "Provisioning Gardener cluster"

# Provision garderner cluster
reconciler::provision_cluster

reconciler::export_shoot_cluster_kubeconfig

# Deploy reconciler in the cluster
reconciler::deploy

# Disable sidecar injection for reconciler namespace
reconciler::disable_sidecar_injection_reconciler_ns

# Wait until reconciler is ready
reconciler::wait_until_is_ready


# Install Kyma CLI
kyma::install_cli

# Install Kyma using cli with version previously set in KYMA_SOURCE
export EXECUTION_PROFILE=evaluation
log::banner "Installing Kyma $KYMA_SOURCE with profile: \"$EXECUTION_PROFILE\""
gardener::install_kyma

# run the fast integration test before reconciliation
log::banner "Executing pre-upgrade test - before reconciliation"
gardener::pre_upgrade_test_fast_integration_kyma

# Deploy test pod which will trigger reconciliation
reconciler::deploy_test_pod

# Wait until test-pod is ready
reconciler::wait_until_test_pod_is_ready

# Fetch latest Kyma2 release
kyma::get_last_release_version -t "${BOT_GITHUB_TOKEN}"
export KYMA_UPGRADE_SOURCE="${kyma_get_last_release_version_return_version:?}"
log::info "### Reading release version from RELEASE_VERSION file, got: ${KYMA_UPGRADE_SOURCE}"

# Set up test pod environment
reconciler::initialize_test_pod

# Trigger the reconciliation through test pod
reconciler::trigger_kyma_reconcile

# Wait until reconciliation is complete
reconciler::wait_until_kyma_reconciled

# run the fast integration test after reconciliation
export KYMA_MAJOR_VERSION="2"
log::banner "Executing post-upgrade test - after reconciliation"
gardener::post_upgrade_test_fast_integration_kyma

#!!! Must be at the end of the script !!!
ERROR_LOGGING_GUARD="false"