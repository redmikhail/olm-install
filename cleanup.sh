#!/bin/bash

set -ex

. ./myenv.sh

APP_REGISTRY="${APP_REGISTRY:-rh-osbs-operators}"
PACKAGE="${PACKAGE:-kubevirt-hyperconverged}"
TARGET_NAMESPACE="${TARGET_NAMESPACE:-openshift-cnv}"
CLUSTER="${CLUSTER:-OPENSHIFT}"
OPERATOR_NAME="${OPERATOR_NAME:-hco-operatorhub}"
GLOBAL_NAMESPACE="${GLOBAL_NAMESPACE:-openshift-marketplace}"
CHANNEL_VERSION="${CHANNEL_VERSION:-2.1.0}"

WAIT_FOR_OBJECT_CREATION=${WAIT_FOR_OBJECT_CREATION:-60}

if [[ -d ./kustomize ]]; then   
  if [[  -f ./kustomize/${OPERATOR_NAME}/kustomization.yaml ]]; then
    echo ">>> Deleting ${OPERATOR_NAME} as defined in kustomization.yaml file"
    oc delete -k ./kustomize/${OPERATOR_NAME}
  fi
  echo ">>> kustomization.yaml file is not present."
else
  echo ">>> Directory kustomize is not present , skipping trigering operator. Manually apply required CRs"
fi
# Cleanup Subscription 
if `oc get subscription ${OPERATOR_NAME} -n ${TARGET_NAMESPACE} &> /dev/null`; then
    CSV_NAME=$(oc get subscription ${OPERATOR_NAME} -n ${TARGET_NAMESPACE} -o jsonpath='{.status.installedCSV}')
    oc delete subscription ${OPERATOR_NAME} -n ${TARGET_NAMESPACE} 
else 
    echo "Subscription ${OPERATOR_NAME} is not avaiable, can not retrieve CSV name . Proceed with manual cleanup"
    exit 1
fi 

#Cleanup CSV 
if `oc get csv ${CSV_NAME} -n ${TARGET_NAMESPACE} &> /dev/null`; then
    oc delete csv ${CSV_NAME} -n ${TARGET_NAMESPACE} 
    oc wait --for=delete csv ${CSV_NAME} -n ${TARGET_NAMESPACE} --timeout=60s || true
fi 
# Cleanup operatorgroups if any 
if `oc get operatorgroups ${TARGET_NAMESPACE}-group -n ${TARGET_NAMESPACE} &> /dev/null`; then
    oc delete operatorgroups ${TARGET_NAMESPACE}-group -n ${TARGET_NAMESPACE} 
fi 
# Remove operatorsource 
if `oc get operatorsource ${APP_REGISTRY} -n ${GLOBAL_NAMESPACE} &> /dev/null`; then
    oc delete operatorsource ${APP_REGISTRY} -n ${GLOBAL_NAMESPACE} 
    oc wait --for=delete operatorsource ${APP_REGISTRY} -n ${GLOBAL_NAMESPACE} --timeout=60s || true
fi 
if `oc get secret quay-registry-${APP_REGISTRY} -n ${GLOBAL_NAMESPACE} &> /dev/null`; then
    oc delete secret quay-registry-${APP_REGISTRY}  -n ${GLOBAL_NAMESPACE} 
fi 

