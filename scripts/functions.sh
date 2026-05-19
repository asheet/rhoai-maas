#!/bin/bash
set -e

TMP_DIR=tmp
SEALED_SECRETS_FOLDER=components/operators/sealed-secrets-operator/overlays/default/
SEALED_SECRETS_SECRET=bootstrap/base/sealed-secrets-secret.yaml
TIMEOUT_SECONDS=60

setup_bin(){
  mkdir -p ${TMP_DIR}/bin
  echo "${PATH}" | grep -q "${TMP_DIR}/bin" || \
    PATH=$(pwd)/${TMP_DIR}/bin:${PATH}
    export PATH
}

check_bin(){
  name=$1
  echo "Validating CLI tool: ${name}"
  
  which "${name}" || download_${name}
 
  case ${name} in
    oc|openshift-install|kustomize)
      echo "auto-complete: . <(${name} completion bash)"
      
      # shellcheck source=/dev/null
      . <(${name} completion bash)
      
      ${name} version
      ;;
    *)
      echo
      ${name} --version
      ;;
  esac
  echo
}

# Kubeseal releases can be found at:
# https://github.com/bitnami-labs/sealed-secrets/releases/
download_kubeseal(){
  KUBESEAL_VERSION="0.19.4"

  if [[ "$OSTYPE" == "darwin"* ]]; then
    # Mac OSX  
    if [[ $(uname -p) == 'arm' ]]; then
      DOWNLOAD_URL=https://github.com/bitnami-labs/sealed-secrets/releases/download/v${KUBESEAL_VERSION}/kubeseal-${KUBESEAL_VERSION}-darwin-arm64.tar.gz
    else
      DOWNLOAD_URL=https://github.com/bitnami-labs/sealed-secrets/releases/download/v${KUBESEAL_VERSION}/kubeseal-${KUBESEAL_VERSION}-darwin-amd64.tar.gz
    fi
  else
    # Linix
    if [[ $(uname -p) == 'arm' ]]; then
      DOWNLOAD_URL=https://github.com/bitnami-labs/sealed-secrets/releases/download/v${KUBESEAL_VERSION}/kubeseal-${KUBESEAL_VERSION}-linux-arm.tar.gz
    else
      DOWNLOAD_URL=https://github.com/bitnami-labs/sealed-secrets/releases/download/v${KUBESEAL_VERSION}/kubeseal-${KUBESEAL_VERSION}-linux-amd64.tar.gz
    fi  
  fi
  echo "Downloading Kubeseal: ${DOWNLOAD_URL}"

  curl "${DOWNLOAD_URL}" -L | tar vzx -C ${TMP_DIR}/bin kubeseal
}


download_ocp-install(){
  DOWNLOAD_URL=https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable-${OCP_VERSION}/openshift-install-linux.tar.gz
  curl "${DOWNLOAD_URL}" -L | tar vzx -C ${TMP_DIR}/bin openshift-install
}

download_oc(){
  if [[ ! "$OCP_VERSION" ]]; then
    echo "OCP version missing. Please provide OCP version when running this command!"
    exit 1
  fi
  if [[ "$OSTYPE" == "darwin"* ]]; then
    # Mac OSX  
    if [[ $(uname -p) == 'arm' ]]; then
      DOWNLOAD_URL=https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable-${OCP_VERSION}/openshift-client-mac-arm64.tar.gz
    else
      DOWNLOAD_URL=https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable-${OCP_VERSION}/openshift-client-mac.tar.gz
    fi
  else
    # Linux
    DOWNLOAD_URL=https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable-${OCP_VERSION}/openshift-client-linux.tar.gz
  fi
  echo "Downloading OpenShift CLI: ${DOWNLOAD_URL}" 
  
  curl "${DOWNLOAD_URL}" -L | tar vzx -C ${TMP_DIR}/bin oc
}

download_kustomize(){
  cd ${TMP_DIR}/bin
  curl -s "https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh" | bash
  cd ../..
}


# check login
check_oc_login(){
  oc cluster-info | head -n1
  oc whoami || exit 1
  echo
}

create_sealed_secret(){
  read -r -p "Create NEW [${SEALED_SECRETS_SECRET}]? [y/N] " input
  case $input in
    [yY][eE][sS]|[yY])

      oc apply -k ${SEALED_SECRETS_FOLDER}
      [ -e ${SEALED_SECRETS_SECRET} ] && return

      # TODO: explore using openssl
      # oc -n sealed-secrets -o yaml \
      #   create secret generic

      # just wait for it
      sleep 20

      oc -n sealed-secrets -o yaml \
        get secret \
        -l sealedsecrets.bitnami.com/sealed-secrets-key=active \
        > ${SEALED_SECRETS_SECRET}

      ;;
    [nN][oO]|[nN])
      echo
      ;;
    *)
      echo
      ;;
  esac
}

# Validate sealed secrets secret exists
check_sealed_secret(){
  if [ -f ${SEALED_SECRETS_SECRET} ]; then
    echo "Using Existing Sealed Secret: ${SEALED_SECRETS_SECRET}"
  else
    echo "Missing: ${SEALED_SECRETS_SECRET}"
    echo "The master key is required to bootstrap sealed secrets and CANNOT be checked into git."
    echo
    create_sealed_secret
  fi
}

wait_for_openshift_gitops(){
  echo "Checking status of all openshift-gitops pods"
  GITOPS_RESOURCES=(
    deployment/cluster:condition=Available \
    statefulset/openshift-gitops-application-controller:jsonpath='{.status.readyReplicas}'=1 \
    deployment/openshift-gitops-applicationset-controller:condition=Available \
    deployment/openshift-gitops-redis:condition=Available \
    deployment/openshift-gitops-repo-server:condition=Available \
    deployment/openshift-gitops-server:condition=Available \
  )

  for n in "${GITOPS_RESOURCES[@]}"
  do
    RESOURCE=$(echo $n | cut -d ":" -f 1)
    CONDITION=$(echo $n | cut -d ":" -f 2)

    echo "Waiting for ${RESOURCE} state to be ${CONDITION}..."

    if [[ "$RESOURCE" == "statefulset/openshift-gitops-application-controller" ]]; then

      # Here's a workaround for waiting for a stateful set to be deloyed:
      # https://github.com/kubernetes/kubernetes/issues/79606#issuecomment-1001246785
      # instead of: oc rollout status ${RESOURCE} -n ${ARGO_NS}

      oc wait pods --selector app.kubernetes.io/name=openshift-gitops-application-controller \
                   --for=condition=Ready -n ${ARGO_NS} --timeout=${TIMEOUT_SECONDS}s

    else   

      oc wait --for=${CONDITION} ${RESOURCE} -n ${ARGO_NS} --timeout=${TIMEOUT_SECONDS}s

    fi

  done
}

check_branch(){
  APP_PATCH_FILE="./components/argocd/apps/base/cluster-config-app-of-apps.yaml"
  APP_PATCH_PATH=".spec.source.targetRevision"

  if ! command -v yq &> /dev/null; then
    print_warning "yq could not be found.  We are unable to verify the branch of your repo."
    exit 1
  fi

  GIT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
  APP_BRANCH=$(yq -r "${APP_PATCH_PATH}" ${APP_PATCH_FILE})

  if [[ ${GIT_BRANCH} == ${APP_BRANCH} ]] ; then
    echo
    echo "Your working branch ${GIT_BRANCH}, matches your cluster overlay branch ${APP_BRANCH}"
  else 
    echo
    echo "Your current working branch is ${GIT_BRANCH}, and your cluster overlay branch is ${APP_BRANCH}."

    if [[ ${FORCE} == "true" ]] ; then
      echo "Updating to ${GIT_BRANCH}"
      update_branch ${CLUSTER_OVERLAY};
    else
      echo "Do you wish to update it to ${GIT_BRANCH}?"

      PS3="Please enter a number to select: "

      select yn in "Yes" "No"; do
          case $yn in
              Yes ) update_branch ${APP_PATCH_FILE} ${APP_PATCH_PATH}; break;;
              No ) break;;
          esac
      done
    fi
  fi

}

update_branch(){
 if [ -z "$1" ]; then
    echo "No patch file supplied."
    exit 1
  else
    APP_PATCH_FILE=$1
  fi

 if [ -z "$2" ]; then
    echo "No patch path supplied."
    exit 1
  else
    APP_PATCH_PATH=$2
  fi

  GIT_BRANCH=$(git rev-parse --abbrev-ref HEAD)

  yq "${APP_PATCH_PATH} = \"${GIT_BRANCH}\"" -i ${APP_PATCH_FILE}

  git add ${APP_PATCH_FILE}
  git commit -m "automatic update to branch by bootstrap script"
  git push origin ${GIT_BRANCH}
}

get_git_basename(){
  if [ -z "$1" ]; then
    echo "No repo provided."
    exit 1
  else
    REPO_URL=$1
  fi

  QUERY='s#(git@|https://)github.com[:/]([a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+)\.git#\2#'
  REPO_BASENAME=$(echo ${REPO_URL} | sed -E  ${QUERY})
  echo ${REPO_BASENAME}
}

update_repo(){
 if [ -z "$1" ]; then
    echo "No patch file supplied."
    exit 1
  else
    APP_PATCH_FILE=$1
  fi

 if [ -z "$2" ]; then
    echo "No patch path supplied."
    exit 1
  else
    APP_PATCH_PATH=$2
  fi

  if [ -z "$3" ]; then
    echo "No repo url provided."
    exit 1
  else
    REPO_URL=$3
  fi

  GIT_BRANCH=$(git rev-parse --abbrev-ref HEAD)

  yq "${APP_PATCH_PATH} = \"${REPO_URL}\"" -i ${APP_PATCH_FILE}

  git add ${APP_PATCH_FILE}
  git commit -m "automatic update to repo by bootstrap script"
  git push origin ${GIT_BRANCH}
}

check_repo(){
  APP_PATCH_FILE="./components/argocd/apps/base/cluster-config-app-of-apps.yaml"
  APP_PATCH_PATH=".spec.source.repoURL"

  if ! command -v yq &> /dev/null; then
    echo "yq could not be found.  We are unable to verify the repo."
  else

    GIT_REPO=$(git config --get remote.origin.url)
    GIT_REPO_BASENAME=$(get_git_basename ${GIT_REPO})
    APP_REPO=$(yq -r "${APP_PATCH_PATH}" ${APP_PATCH_FILE})
    APP_REPO_BASENAME=$(get_git_basename ${APP_REPO})

    if [[ ${GIT_REPO_BASENAME} == ${APP_REPO_BASENAME} ]] ; then
      echo "Your working repo ${GIT_REPO}, matches your cluster overlay branch ${APP_REPO}"
    else 

      GITHUB_URL="https://github.com/${GIT_REPO_BASENAME}.git"

      echo
      echo "Your current working repo is"
      echo "  ${GIT_REPO}"
      echo
      echo "Your cluster overlay repo is"
      echo "  ${APP_REPO}"

      if [[ ${FORCE} == "true" ]] ; then
        echo "Updating to ${GITHUB_URL}"
        update_repo ${APP_PATCH_FILE} ${APP_PATCH_PATH} ${GITHUB_URL};
      else

        echo
        echo "Do you wish to update it to the following?"
        echo "  ${GITHUB_URL}"
        echo

        PS3="Please enter a number to select: "

        select yn in "Yes" "No"; do
            case $yn in
                Yes ) update_repo ${APP_PATCH_FILE} ${APP_PATCH_PATH} ${GITHUB_URL}; break;;
                No ) break;;
            esac
        done
      fi
    fi
  fi
}

patch_file () {
  APP_PATCH_FILE=$1
  NEW_VALUE=$2
  YQ_PATH=$3

  CURRENT_VALUE=$(yq -r ${YQ_PATH} ${APP_PATCH_FILE})

  if [[ ${CURRENT_VALUE} == ${NEW_VALUE} ]]; then
    echo "${APP_PATCH_FILE} already has value ${NEW_VALUE}"
    return
  fi

  yq "${YQ_PATH} = \"${NEW_VALUE}\"" -i ${APP_PATCH_FILE}
}

apply_firmly(){
  if [ ! -f "${1}/kustomization.yaml" ]; then
    print_error "Please provide a dir with \"kustomization.yaml\""
    return 1
  fi

  # kludge
  until oc kustomize "${1}" --enable-helm | oc apply -f- 2>/dev/null
  do
    echo -n "."
    sleep 5
  done
  echo ""
  # until_true oc apply -k "${1}" 2>/dev/null
}

wait_for_install_plan_completion(){
  if [ -z "$1" ]; then
    echo "ERROR: No operator namespace argument supplied."
    exit 1
  else
    OPERATOR_NS=$1
  fi

  if [ -z "$2" ]; then
    echo "ERROR: No subscription argument supplied."
    exit 1
  else
    OPERATOR_SUB=$2
  fi

  echo -n "Retrieving the InstallPlan name: "
  INSTALL_PLAN_NAME=$(oc get sub ${OPERATOR_SUB} -n ${OPERATOR_NS} -o jsonpath='{.status.installPlanRef.name}')
  echo "$INSTALL_PLAN_NAME was found in the namespace $OPERATOR_NS for subscription ${OPERATOR_SUB}"

  echo -n "Retrieving the CSV name: "
  CSV_NAME=$(oc get installplan $INSTALL_PLAN_NAME -n ${OPERATOR_NS} -o jsonpath='{.spec.clusterServiceVersionNames[0]}')
  echo "$CSV_NAME"

  echo "Waiting for the operator installtion of ${OPERATOR_SUB} to complete..."
  oc wait --for jsonpath='{.status.phase}'=Succeeded csv/$CSV_NAME -n ${OPERATOR_NS}

  echo "${OPERATOR_SUB}/${OPERATOR_NS} successfully installed."
  echo ""
}

get_cluster_domain(){
  oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}'
}

patch_gateway_hostname(){
  local cluster_domain="$1"
  local kustomize_dir="$2"
  local gateway_host="maas.${cluster_domain}"

  if [ -z "${cluster_domain}" ]; then
    echo "ERROR: Could not determine cluster ingress domain."
    exit 1
  fi

  echo "Using MaaS gateway hostname: ${gateway_host}"
  kustomize build "${kustomize_dir}/overlays/03-gateway" \
    | sed "s|maas.apps.cluster-\${UPDATEME}.opentlc.com|${gateway_host}|g" \
    | oc apply -f-
}

patch_rhcl_gateway_controller_names(){
  local csv_name
  csv_name=$(oc get csv -n rh-connectivity-link \
    -l operators.coreos.com/rhcl-operator.rh-connectivity-link='' \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

  if [ -z "${csv_name}" ]; then
    echo "WARNING: RHCL CSV not found; skip ISTIO_GATEWAY_CONTROLLER_NAMES patch."
    return 0
  fi

  echo "Patching ${csv_name} with ISTIO_GATEWAY_CONTROLLER_NAMES..."
  oc patch csv "${csv_name}" -n rh-connectivity-link --type=json -p='[
    {"op": "add", "path": "/spec/install/spec/deployments/0/spec/template/spec/containers/0/env/-",
     "value": {"name": "ISTIO_GATEWAY_CONTROLLER_NAMES",
               "value": "istio.io/gateway-controller,openshift.io/gateway-controller/v1"}}
  ]' 2>/dev/null || \
  oc set env deployment/rhcl-operator-controller-manager \
    -n rh-connectivity-link \
    ISTIO_GATEWAY_CONTROLLER_NAMES='istio.io/gateway-controller,openshift.io/gateway-controller/v1' \
    --containers=manager 2>/dev/null || \
    echo "WARNING: Could not patch RHCL for gateway controllers; verify ISTIO_GATEWAY_CONTROLLER_NAMES manually."
}

configure_authorino_tls(){
  echo "Configuring Authorino serving certificate in rh-connectivity-link..."
  oc annotate service authorino-authorino-authorization \
    -n rh-connectivity-link \
    service.beta.openshift.io/serving-cert-secret-name=authorino-server-cert \
    --overwrite 2>/dev/null || \
    echo "WARNING: authorino-authorino-authorization service not found yet; retry after RHCL is ready."

  oc patch authorino authorino -n rh-connectivity-link --type=merge -p '{
    "spec": {
      "clusterWide": true,
      "healthz": {},
      "listener": {
        "ports": {},
        "tls": {
          "certSecretRef": {"name": "authorino-server-cert"},
          "enabled": true
        }
      }
    }
  }' 2>/dev/null || \
    echo "WARNING: Could not patch Authorino CR; see rhoai-3_4/KUSTOMIZE.md."

  oc delete pod -n rh-connectivity-link -l control-plane=controller-manager,app.kubernetes.io/name=kuadrant-operator 2>/dev/null || true
}

wait_for_datascience_cluster(){
  echo "Waiting for DataScienceCluster/default-dsc to become Ready..."
  oc wait datasciencecluster/default-dsc \
    -n redhat-ods-applications \
    --for=condition=Ready \
    --timeout=45m 2>/dev/null || \
  oc wait datasciencecluster/default-dsc \
    -n redhat-ods-applications \
    --for=jsonpath='{.status.phase}'=Ready \
    --timeout=45m 2>/dev/null || \
    echo "WARNING: DSC wait timed out; verify: oc get dsc -n redhat-ods-applications"
}

wait_for_postgres(){
  echo "Waiting for postgres deployment in redhat-ods-applications..."
  oc rollout status deployment/postgres -n redhat-ods-applications --timeout=15m
}

apply_overlay(){
  local kustomize_dir="$1"
  local overlay="$2"
  echo ""
  echo "=========================================================================="
  echo " Applying ${kustomize_dir}/overlays/${overlay}"
  echo "=========================================================================="
  apply_firmly "${kustomize_dir}/overlays/${overlay}"
}

wait_for_observability_operators(){
  wait_for_install_plan_completion "openshift-cluster-observability-operator" "cluster-observability-operator"
  wait_for_install_plan_completion "openshift-tempo-operator" "tempo-product"
  wait_for_install_plan_completion "openshift-opentelemetry-operator" "opentelemetry-product"
}
