#!/usr/bin/env bash

#Description: TEMPORARY PIPELINE FOR ALPHA FEATURES TESTING. WORK IN PROGRESS. Related issue: https://github.com/kyma-project/test-infra/issues/3057
#
#
#Expected vars:
#
# - KYMA_PROJECT_DIR - directory path with Kyma sources to use for installation
# - GARDENER_REGION - Gardener compute region
# - GARDENER_ZONES - Gardener compute zones inside the region
# - GARDENER_KYMA_PROW_KUBECONFIG - Kubeconfig of the Gardener service account
# - GARDENER_KYMA_PROW_PROJECT_NAME Name of the gardener project where the cluster will be integrated.
# - GARDENER_KYMA_PROW_PROVIDER_SECRET_NAME Name of the GCP secret configured in the gardener project to access the cloud provider
# - MACHINE_TYPE (optional): GCP machine type
#
#Permissions: In order to run this script you need to use a service account with permissions equivalent to the following GCP roles:
# - Compute Admin
# - Service Account User
# - Service Account Admin
# - Service Account Token Creator
# - Make sure the service account is enabled for the Google Identity and Access Management API.

set -e

readonly GARDENER_CLUSTER_VERSION="1.16"

#Exported variables
export TEST_INFRA_SOURCES_DIR="${KYMA_PROJECT_DIR}/test-infra"
export TEST_INFRA_CLUSTER_INTEGRATION_SCRIPTS="${TEST_INFRA_SOURCES_DIR}/prow/scripts/cluster-integration/helpers"

# shellcheck source=prow/scripts/lib/gardener/gcp.sh
source "${TEST_INFRA_SOURCES_DIR}/prow/scripts/lib/gardener/gcp.sh"
# shellcheck disable=SC1090
source "${TEST_INFRA_SOURCES_DIR}/prow/scripts/lib/testing-helpers.sh"
# shellcheck source=prow/scripts/lib/utils.sh
source "${TEST_INFRA_SOURCES_DIR}/prow/scripts/lib/utils.sh"
# shellcheck source=prow/scripts/lib/utils.sh
source "${TEST_INFRA_SOURCES_DIR}/prow/scripts/lib/cli-alpha.sh"

requiredVars=(
    KYMA_PROJECT_DIR
    GARDENER_REGION
    GARDENER_ZONES
    GARDENER_KYMA_PROW_KUBECONFIG
    GARDENER_KYMA_PROW_PROJECT_NAME
    GARDENER_KYMA_PROW_PROVIDER_SECRET_NAME
)

utils::check_required_vars "${requiredVars[@]}"

# nice cleanup on exit, be it succesful or on fail
trap gardener::cleanup EXIT INT

RANDOM_NAME_SUFFIX=$(LC_ALL=C tr -dc 'a-z0-9' < /dev/urandom | head -c4)
readonly COMMON_NAME_PREFIX="grdnr"
COMMON_NAME=$(echo "${COMMON_NAME_PREFIX}${RANDOM_NAME_SUFFIX}" | tr "[:upper:]" "[:lower:]")

### Cluster name must be less than 10 characters!
export CLUSTER_NAME="${COMMON_NAME}"

# Local variables

#Used to detect errors for logging purposes
ERROR_LOGGING_GUARD="true"

log::info "Building Kyma CLI"
cd "${KYMA_PROJECT_DIR}/cli"
make build-linux
mv "${KYMA_PROJECT_DIR}/cli/bin/kyma-linux" "${KYMA_PROJECT_DIR}/cli/bin/kyma"
export PATH="${KYMA_PROJECT_DIR}/cli/bin:${PATH}"

log::info "Provision cluster: \"${CLUSTER_NAME}\""

gardener::set_machine_type

gardener::provision_cluster

log::info "Installing Kyma"

# Parallel-install library installs cluster-essentials, istio, and xip-patch before kyma installation. That's why they should not exist on the InstallationCR.
# Once we figure out a way to fix this, this custom CR can be deleted from this script.
cat << EOF > "/tmp/kyma-parallel-install-installationCR.yaml"
apiVersion: "installer.kyma-project.io/v1alpha1"
kind: Installation
metadata:
  name: kyma-installation
  namespace: default
spec:
  components:
    - name: "testing"
      namespace: "kyma-system"
    - name: "knative-eventing"
      namespace: "knative-eventing"
    - name: "dex"
      namespace: "kyma-system"
    - name: "ory"
      namespace: "kyma-system"
    - name: "api-gateway"
      namespace: "kyma-system"
    - name: "rafter"
      namespace: "kyma-system"
    - name: "service-catalog"
      namespace: "kyma-system"
    - name: "service-catalog-addons"
      namespace: "kyma-system"
    - name: "helm-broker"
      namespace: "kyma-system"
    - name: "nats-streaming"
      namespace: "natss"
    - name: "core"
      namespace: "kyma-system"
    - name: "cluster-users"
      namespace: "kyma-system"
    - name: "logging"
      namespace: "kyma-system"
    - name: "permission-controller"
      namespace: "kyma-system"
    - name: "apiserver-proxy"
      namespace: "kyma-system"
    - name: "iam-kubeconfig-service"
      namespace: "kyma-system"
    - name: "serverless"
      namespace: "kyma-system"
    - name: "knative-provisioner-natss"
      namespace: "knative-eventing"
    - name: "event-sources"
      namespace: "kyma-system"
    - name: "application-connector"
      namespace: "kyma-integration"
    - name: "tracing"
      namespace: "kyma-system"
    - name: "monitoring"
      namespace: "kyma-system"
    - name: "kiali"
      namespace: "kyma-system"
    - name: "console"
      namespace: "kyma-system"
EOF

log::info "Get kyma 1.18.0 & run tests"

(
cd "${KYMA_PROJECT_DIR}/kyma"
git fetch --tags
# latestTag=$(git describe --tags "$(git rev-list --tags --max-count=1)")
# shout "Installing Kyma in version: $latestTag"
# git checkout "$latestTag"
git checkout 1.18.0
cli-alpha::deploy "${KYMA_PROJECT_DIR}/kyma/resources" "/tmp/kyma-parallel-install-installationCR.yaml"

kyma test run \
    --name "testsuite-alpha-$(date '+%Y-%m-%d-%H-%M')" \
    --concurrency 6 \
    --max-retries 1 \
    --timeout 60m \
    --watch \
    --non-interactive \
    istio-kyma-validate application-connector application-operator application-registry \
    connection-token-handler connector-service api-gateway apiserver-proxy cluster-users \
    console-backend core-test-external-solution dex-connection dex-integration kiali \
    logging monitoring rafter serverless serverless-long service-catalog
)

log::info "Upgrade to master & run tests"

(
cd "${KYMA_PROJECT_DIR}/kyma"
git checkout master
cli-alpha::deploy "${KYMA_PROJECT_DIR}/kyma/resources" "/tmp/kyma-parallel-install-installationCR.yaml"

kyma test run \
    --name "testsuite-alpha-$(date '+%Y-%m-%d-%H-%M')" \
    --concurrency 6 \
    --max-retries 1 \
    --timeout 60m \
    --watch \
    --non-interactive \
    istio-kyma-validate application-connector application-operator application-registry \
    connection-token-handler connector-service api-gateway apiserver-proxy cluster-users \
    console-backend core-test-external-solution dex-connection dex-integration kiali \
    logging monitoring rafter serverless serverless-long service-catalog
)

log::info "Success"

#!!! Must be at the end of the script !!!
ERROR_LOGGING_GUARD="false"