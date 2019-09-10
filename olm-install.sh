#!/bin/bash

set -e



#Global namespace in OpenShift version 4.2 supposed to be openshift-marketplace 


CUSTOM_APPREGISTRY=${CUSTOM_APPREGISTRY:-true}
NAMESPACED_SUBSCR=${NAMESPACED_SUBSCR:-true}

APP_REGISTRY="${APP_REGISTRY:-rh-osbs-operators}"
PACKAGE="${PACKAGE:-kubevirt-hyperconverged}"
TARGET_NAMESPACE="${TARGET_NAMESPACE:-openshift-cnv}"
CLUSTER="${CLUSTER:-OPENSHIFT}"
OPERATOR_NAME="${OPERATOR_NAME:-hco-operatorhub}"
GLOBAL_NAMESPACE="${GLOBAL_NAMESPACE:-openshift-marketplace}"
CHANNEL_VERSION="${CHANNEL_VERSION:-2.1.0}"

WAIT_FOR_OBJECT_CREATION=${WAIT_FOR_OBJECT_CREATION:-60}



if [[ ${CUSTOM_APPREGISTRY} ]]
  then 

    ####################
    QUAY_USERNAME="${QUAY_USERNAME:-}"
    QUAY_PASSWORD="${QUAY_PASSWORD:-}"

    if [ -z "${QUAY_USERNAME}" ]; then
        echo "QUAY_USERNAME"
        read QUAY_USERNAME
    fi

    if [ -z "${QUAY_PASSWORD}" ]; then
        echo "QUAY_PASSWORD"
        read -s QUAY_PASSWORD
    fi

    TOKEN=$(curl -sH "Content-Type: application/json" -XPOST https://quay.io/cnr/api/v1/users/login -d '
    {
        "user": {
            "username": "'"${QUAY_USERNAME}"'",
            "password": "'"${QUAY_PASSWORD}"'"
        }
    }' | jq -r '.token')

    if [ "${TOKEN}" == "null" ]; then
        echo "TOKEN was 'null'.  Did you enter the correct quay Username & Password?"
        exit 1
    fi

    echo ">>> Creating registry secret"
    cat <<EOF | oc apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: "quay-registry-${APP_REGISTRY}"
  namespace: "${GLOBAL_NAMESPACE}"
type: Opaque
stringData:
      token: "${TOKEN}"
EOF

fi

if ! `oc get project ${TARGET_NAMESPACE} &>/dev/null`
then
    oc create ns ${TARGET_NAMESPACE}
fi

# Create OperatorGroup 
echo ">>> Creating operatorgroup ${TARGET_NAMESPACE}-group"
if ! `oc get operatorgroup ${TARGET_NAMESPACE}-group -n ${TARGET_NAMESPACE} &>/dev/null` ; then
  if [[ ${NAMESPACED_SUBSCR} ]]; then

    echo "Creating OperatorGroup"
    cat <<EOF | oc create -f - || true
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: "${TARGET_NAMESPACE}-group"
  namespace: "${TARGET_NAMESPACE}"
spec:
  targetNamespaces:
  - ${TARGET_NAMESPACE}
EOF
else
    cat <<EOF | oc create -f - || true
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: "${TARGET_NAMESPACE}-group"
  namespace: "${TARGET_NAMESPACE}"
spec: {}
EOF
  fi
fi


echo ">>> Creating OperatorSource and CatalogSource..."
if ! `oc get operatorsource ${APP_REGISTRY} -n ${GLOBAL_NAMESPACE} &>/dev/null`  && [ ${CUSTOM_APPREGISTRY} ]; then

  echo "OperatorSource ${APP_REGISTRY} doesn't exist, creating ..."
  cat <<EOF | oc create -f -
apiVersion: operators.coreos.com/v1
kind: OperatorSource
metadata:
  name: "${APP_REGISTRY}"
  namespace: "${GLOBAL_NAMESPACE}"
spec:
  type: appregistry
  endpoint: https://quay.io/cnr
  registryNamespace: "${APP_REGISTRY}"
  displayName: "${APP_REGISTRY}"
  publisher: "Red Hat"
  authorizationToken:
    secretName: "quay-registry-${APP_REGISTRY}"
EOF
  tempCounter=0
  while [[ `oc get operatorsource ${APP_REGISTRY} -n ${GLOBAL_NAMESPACE} -o jsonpath='{.status.currentPhase.phase.name}'` != "Succeeded" ]] \
  && \
  [ ${tempCounter} -lt $((WAIT_FOR_OBJECT_CREATION/5)) ];do
    sleep 5
    echo "Waiting for all objects defined by subscription to be created ..." 
    let tempCounter=${tempCount}+1
  done
  if [[ ${temCounter} -gt $((WAIT_FOR_OBJECT_CREATION/5)) ]]; then 
     echo "OperatorSource creation has timeout..."
     exit 1
  fi
fi

echo ">>> Waiting for packagemanifest ${PACKAGE} to be created ..."
tempCounter=0
while `oc get packagemanifest  -l catalog=${APP_REGISTRY} --field-selector metadata.name=${PACKAGE}` \
&& \
[ ${tempCounter} -lt $((WAIT_FOR_OBJECT_CREATION/5)) ];do
  sleep 5
  echo "Waiting for packagemanifest to be created ..." 
  let tempCounter=${tempCount}+1
done
if [[ ${temCounter} -gt $((WAIT_FOR_OBJECT_CREATION/5)) ]]; then 
    echo "Packagemanifest ${PACKAGE} doesn't exist or packagemancreation has timeout..."
    exit 1
fi

echo ">>> Creating Subscription"
if [[ "`oc get subscription ${OPERATOR_NAME} -n ${TARGET_NAMESPACE} -o jsonpath='{.spec.channel}'`" == "${CHANNEL_VERSION}" ]]; then
  echo "Subscrition ${OPERATOR_NAME} already exist, skipping creation..."
else
    cat <<EOF | oc create -f - 
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: "${OPERATOR_NAME}"
  namespace: "${TARGET_NAMESPACE}"
spec:
  source: "${APP_REGISTRY}"
  sourceNamespace: "${GLOBAL_NAMESPACE}"
  name: ${PACKAGE}
  channel: "${CHANNEL_VERSION}"
  installPlanApproval: Manual
EOF
  oc wait subscription ${OPERATOR_NAME} -n ${TARGET_NAMESPACE} --for=condition=InstallPlanPending --timeout="${WAIT_FOR_OBJECT_CREATION}s"
fi 



echo ">>> Approving installPlan for subscription ${OPERATOR_NAME}"
if [[ `oc get subscription ${OPERATOR_NAME} -n ${TARGET_NAMESPACE} -o jsonpath='{.spec.installPlanApproval}'` == "Manual" ]]; then 
    oc patch installplan `oc get subscription ${OPERATOR_NAME} -n ${TARGET_NAMESPACE} -o jsonpath='{.status.installplan.name}'` -n ${TARGET_NAMESPACE} --type=json -p='[{"op":"replace", "path":"/spec/approved","value":true}]' --loglevel=5
fi

# Unfortunately CSV object doesn't set status.conditions correctly for kubectl or oc wait command to work correctly. Replaced with while 
echo "Creating all required objects for subscription ${OPERATOR_NAME}"
tempCounter=0
while [[ `oc get csv $(oc get subscription ${OPERATOR_NAME} -n ${TARGET_NAMESPACE} -o jsonpath='{.status.installedCSV}') -n ${TARGET_NAMESPACE} -o jsonpath='{.status.phase}'` != "Succeeded" ]] \
&& \
[ ${tempCounter} -lt $((WAIT_FOR_OBJECT_CREATION/5)) ];do
  sleep 5
  echo "Waiting for all objects defined by subscription to be created ..." 
  let tempCounter=${tempCount}+1
done
if [[ ${temCounter} -gt $((WAIT_FOR_OBJECT_CREATION/5)) ]]; then 
    echo "OperatorSource creation has timeout..."
    exit 1
fi