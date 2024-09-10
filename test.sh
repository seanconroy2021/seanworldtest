#!/usr/bin/env sh

SCRIPTDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

APPLICATION_NAME="seanworld"
COMPONENT_NAME="rhtap-service-push-component"
RELEASE_PLAN_NAME="rhtap-service-push-rp"
RELEASE_PLAN_ADMISSION_NAME="rhtap-service-push-rpa"
TIMEOUT_SECONDS=600

DEV_WORKSPACE="dev-release-team"
MANAGED_WORKSPACE="managed-release-team"
TOOLCHAIN_API_URL=https://api-toolchain-host-operator.apps.stone-stg-host.qc0p.p1.openshiftapps.com/workspaces

DEV_WORKSPACE_TENANT=${DEV_WORKSPACE}-tenant
MANAGED_WORKSPACE_TENANT=${MANAGED_WORKSPACE}-tenant

###
DEV_KUBECONFIG=${DEV_KUBECONFIG:=$(WORKSPACE=$DEV_WORKSPACE TOOLCHAIN_API_URL=$TOOLCHAIN_API_URL $SCRIPTDIR/../utils/generate-kubeconfig-file.sh)}
MANAGED_KUBECONFIG=${MANAGED_KUBECONFIG:=$(WORKSPACE=$MANAGED_WORKSPACE TOOLCHAIN_API_URL=$TOOLCHAIN_API_URL $SCRIPTDIR/../utils/generate-kubeconfig-file.sh)}

if [ -z "${DEV_KUBECONFIG}" ]; then
  echo "Error: could not access DEV_WORKSPACE: ${DEV_WORKSPACE}"
  exit 1
fi
if [ -z "${MANAGED_KUBECONFIG}" ]; then
  echo "Error: could not access MANAGED_WORKSPACE: ${MANAGED_WORKSPACE}"
  exit 1
fi

DEV_KUBECONFIG_ARG="--kubeconfig=${DEV_KUBECONFIG}"
MANAGED_KUBECONFIG_ARG="--kubeconfig=${MANAGED_KUBECONFIG}"

#trap "rm -f ${DEV_KUBECONFIG} ${MANAGED_KUBECONFIG}" EXIT

print_help(){
    echo -e "$0 [ --skip-cleanup ]\n"
    echo -e "\t--skip-cleanup\tDisable cleanup after test. Useful for debugging"
}

function setup() {

    echo "Creating Application"
    kubectl apply -f release-resources/application.yaml "${DEV_KUBECONFIG_ARG}"

    echo "Creating Component"
    kubectl apply -f release-resources/component.yaml "${DEV_KUBECONFIG_ARG}"
    
    echo "Creating ReleasePlan"
    kubectl apply -f release-resources/release-plan.yaml "${DEV_KUBECONFIG_ARG}"

    echo "Creating ReleasePlanAdmission"
    kubectl apply -f release-resources/release-plan-admission.yaml "${MANAGED_KUBECONFIG_ARG}"

    echo "Creating EnterpriseContractPolicy"
    kubectl apply -f release-resources/ec-policy.yaml "${MANAGED_KUBECONFIG_ARG}"

}

function teardown() {

    kubectl delete pr -l "appstudio.openshift.io/application=$APPLICATION_NAME,pipelines.appstudio.openshift.io/type=build,appstudio.openshift.io/component=$COMPONENT_NAME" "${DEV_KUBECONFIG_ARG}"
    kubectl delete pr -l "appstudio.openshift.io/application=$APPLICATION_NAME,pipelines.appstudio.openshift.io/type=release" "${MANAGED_KUBECONFIG_ARG}"
    kubectl delete release "${DEV_KUBECONFIG_ARG}" -o=jsonpath="{.items[?(@.spec.releasePlan==\"$RELEASE_PLAN_NAME\")].metadata.name}"
    kubectl delete releaseplanadmission "$RELEASE_PLAN_ADMISSION_NAME" "${MANAGED_KUBECONFIG_ARG}"

    if kubectl get application "$APPLICATION_NAME"  "${DEV_KUBECONFIG_ARG}" &> /dev/null; then
        echo "Application $APPLICATION_NAME exists. Deleting..."
        kubectl delete application "$APPLICATION_NAME" "${DEV_KUBECONFIG_ARG}"
    else
        echo "Application $APPLICATION_NAME does not exist."
    fi
}

# Function to watch Build or Release PipelineRun and wait till succeeds.
function wait_for_pr_to_complete() {
    local kube_config
    local type=$1
    local start_time=$(date +%s)

    if [ "$type" = "release" ]; then
        kube_config="${DEV_KUBECONFIG_ARG}"
        crd_labels="appstudio.openshift.io/application=$APPLICATION_NAME"
    else
        kube_config="${DEV_KUBECONFIG_ARG}"
        crd_labels="appstudio.openshift.io/application=$APPLICATION_NAME,pipelines.appstudio.openshift.io/type=$type,appstudio.openshift.io/component=$COMPONENT_NAME"
    fi

    while true; do
        crd_json=$(kubectl get PipelineRun -l "$crd_labels" "$kube_config" -o=json)

        reason=$(echo "$crd_json" | jq -r '.items[0].status.conditions[0].reason')
        status=$(echo "$crd_json" | jq -r '.items[0].status.conditions[0].status')
        type=$(echo "$crd_json" | jq -r '.items[0].status.conditions[0].type')
        name=$(echo "$crd_json" | jq -r '.items[0].metadata.name')
        namespace=$(echo "$crd_json" | jq -r '.items[0].metadata.namespace')

        if [ "$type" = "Failed" ]; then
            echo "PipelineRun $name failed."
            return 1
        fi

        if [ "$status" = "True" ] && [ "$type" = "Succeeded" ]; then
            echo "PipelineRun $name succeeded."
            return 0
        else
            current_time=$(date +%s)
            elapsed_time=$((current_time - start_time))

            if [ "$elapsed_time" -ge "$TIMEOUT_SECONDS" ] ; then
                echo "Timeout: PipelineRun $name in namespace $namespace did not succeeded within $TIMEOUT_SECONDS seconds."
                return 1
            fi
            echo "Waiting for PipelineRun $name in namespace $namespace to succeed."
            sleep 5
        fi
    done
}

OPTIONS=$(getopt -l "skip-cleanup,help" -o "sc,h" -a -- "$@")
eval set -- "$OPTIONS"
while true; do
    case "$1" in
        -sc|--skip-cleanup)
            CLEANUP="true"
            ;;
        -h|--help)
            print_help
            exit
            ;;
        --)
            shift
            break
            ;;
    esac
    shift
done

#if [ "${CLEANUP}" != "true" ]; then
#  trap teardown EXIT
#fi

#echo "Cleaning up before setup"
teardown
sleep 5

echo "Setting up resources"
setup

echo "Wait for build PipelineRun to finish"
wait_for_pr_to_complete "build"

echo "Wait for release PipelineRun to finish"
wait_for_pr_to_complete "release"

echo "Waiting for the Release to be updated"
sleep 15

echo "Checking Release status"
# Get name of Release CR associated with Release Plan "rhtap-service-push-rp".
release_name=$(kubectl get release  "${DEV_KUBECONFIG_ARG}" -o jsonpath="{range .items[?(@.spec.releasePlan=='$RELEASE_PLAN_NAME')]}{.metadata.name}{'\n'}{end}" --sort-by={metadata.creationTimestamp} | tail -1)
echo "release_name: $release_name"

# Get the Released Status and Reason values to identify if fail or succeeded
release_status=$(kubectl get release "$release_name" "${DEV_KUBECONFIG_ARG}" -o jsonpath='{.status.conditions[?(@.type=="Released")].status}' 2>/dev/null)
release_reason=$(kubectl get release "$release_name" "${DEV_KUBECONFIG_ARG}" -o jsonpath='{.status.conditions[?(@.type=="Released")].reason}' 2>/dev/null)

echo "Status: $release_status"
echo "Reason: $release_reason"

if [ "$release_status" = "True" ] && [ "$release_reason" = "Succeeded" ]; then
    echo "Release $release_name succeeded."
elif [ "$release_status" = "Failed" ]; then
    echo "Release $release_name failed."
fi
