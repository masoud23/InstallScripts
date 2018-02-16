#!/bin/bash
set -e
#
# This script is meant for quick & easy install via:
#   curl -sSL https://raw.githubusercontent.com/HealthCatalyst/InstallScripts/master/nlp/installnlpkubernetes.sh | bash
#
GITHUB_URL="https://raw.githubusercontent.com/HealthCatalyst/InstallScripts/master"
version="2018.02.16.02"

echo "---- installrealtimekubernetes.sh version $version ------"

source <(curl -sSL "$GITHUB_URL/kubernetes/common.sh")

# source ./kubernetes/common.sh

namespace="fabricrealtime"

datafolder="/mnt/data/fabricrealtime"
if [ ! -d "$datafolder" ]; then
    sudo mkdir -p $datafolder
fi

if [[ -z $(kubectl get namespace $namespace --ignore-not-found=true) ]]; then
    echo "Creating namespace: $namespace"
    # kubectl create -f $GITHUB_URL/nlp/nlp-namespace.yml
    kubectl create namespace $namespace
else
    while : ; do
        read -p "Namespace exists.  Do you want to delete passwords and ALL data stored in this namespace? (y/n): " deleteSecrets < /dev/tty
        if [[ ! -z "$deleteSecrets" ]]; then
            break
        fi
    done

    if [[ $deleteSecrets == "y" ]]; then    
        echo "Deleting passwords"
        kubectl delete secret mysqlrootpassword -n $namespace --ignore-not-found=true
        kubectl delete secret mysqlpassword -n $namespace --ignore-not-found=true
        kubectl delete secret certhostname -n $namespace --ignore-not-found=true
        kubectl delete secret certpassword -n $namespace --ignore-not-found=true
        kubectl delete secret rabbitmqmgmtuipassword -n $namespace --ignore-not-found=true

        sudo rm -rf /mnt/data/*
    fi
fi

customerid="$(ReadSecret customerid)"
if [[ -z "$customerid" ]]; then
    echo "customerid not set"
fi
customerid="${customerid,,}"
echo "Customer ID: $customerid"

AskForPassword  "mysqlrootpassword" "MySQL root password (> 8 chars, min 1 number, 1 lowercase, 1 uppercase, 1 special [!.*@] )" "$namespace"

AskForPassword "mysqlpassword" "MySQL root password (> 8 chars, min 1 number, 1 lowercase, 1 uppercase, 1 special [!.*@] )" "$namespace"

AskForSecretValue "certhostname" "Client Certificate hostname" "$namespace"

AskForPassword "certpassword" "Client Certificate password (> 8 chars, min 1 number, 1 lowercase, 1 uppercase, 1 special [!.*@] )" "$namespace"

AskForPassword "rabbitmqmgmtuipassword" "Admin password for RabbitMqMgmt" "$namespace"

CleanOutNamespace $namespace

echo "-- Deploying volumes --"
folder="volumes"
for fname in "certificateserver.onprem.yaml" "mysqlserver.onprem.yaml" "rabbitmq-cert.onprem.yaml" "rabbitmq.onprem.yaml"
do
    echo "Deploying realtime/$folder/$fname"
    ReadYmlAndReplaceCustomer $GITHUB_URL "realtime/$folder/$fname" $customerid | kubectl create -f -
done

echo "-- Deploying volume claims --"
folder="volumeclaims"
for fname in "certificateserver.yaml" "mysqlserver.yaml" "rabbitmq-cert.yaml" "rabbitmq.yaml"
do
    echo "Deploying realtime/$folder/$fname"
    ReadYmlAndReplaceCustomer $GITHUB_URL "realtime/$folder/$fname" $customerid | kubectl create -f -
done

echo "-- Deploying pods --"
folder="pods"
for fname in "certificateserver.yaml" "mysqlserver.yaml" "interfaceengine.yaml" "rabbitmq.yaml"
do
    echo "Deploying realtime/$folder/$fname"
    ReadYmlAndReplaceCustomer $GITHUB_URL "realtime/$folder/$fname" $customerid | kubectl create -f -
done

echo "-- Deploying cluster services --"
folder="services/cluster"
for fname in "certificateserver.yaml" "mysqlserver.yaml" "interfaceengine.yaml" "rabbitmq.yaml"
do
    echo "Deploying realtime/$folder/$fname"
    ReadYmlAndReplaceCustomer $GITHUB_URL "realtime/$folder/$fname" $customerid | kubectl create -f -
done

echo "-- Deploying external services --"
folder="services/external"
for fname in "certificateserver.yaml"
do
    echo "Deploying realtime/$folder/$fname"
    ReadYmlAndReplaceCustomer $GITHUB_URL "realtime/$folder/$fname" $customerid | kubectl create -f -
done

echo "-- Deploying HTTP proxies --"
folder="ingress/http"
for fname in "web.onprem.yaml"
do
    echo "Deploying realtime/$folder/$fname"
    ReadYmlAndReplaceCustomer $GITHUB_URL "realtime/$folder/$fname" $customerid | kubectl create -f -
done

kubectl get 'deployments,pods,services,ingress,secrets,persistentvolumeclaims,persistentvolumes,nodes' --namespace=$namespace -o wide

WaitForPodsInNamespace $namespace 5

# to get a shell
# kubectl exec -it fabric.nlp.nlpwebserver-85c8cb86b5-gkphh bash --namespace=fabricnlp

# kubectl create secret generic azure-secret --namespace=fabricnlp --from-literal=azurestorageaccountname="fabricnlp7storage" --from-literal=azurestorageaccountkey="/bYhXNstTodg3MdOvTMog/vDLSFrQDpxG/Zgkp2MlnjtOWhDBNQ2xOs6zjRoZYNjmJHya34MfzqdfOwXkMDN2A=="

loadBalancerIP="$(dig +short myip.opendns.com @resolver1.opendns.com)"
echo "My WAN/Public IP address: ${loadBalancerIP}"

Write-Output "To test out the NLP services, open Git Bash and run:"
Write-Output "curl -L --verbose --header 'Host: certificates.$customerid.healthcatalyst.net' 'http://$loadBalancerIP/client'"

Write-Output "Connect to interface engine at: $publicip port 6661"

Write-Output "if you want, you can download the CA (Certificate Authority) cert from this url"
Write-Output "http://certificates.$customerid.healthcatalyst.net/client/fabric_ca_cert.p12"

Write-Output "-------------------------------"
Write-Output "you can download the client certificate from this url:"
Write-Output "http://certificates.$customerid.healthcatalyst.net/client/fabricrabbitmquser_client_cert.p12"
Write-Output "-------------------------------"

echo "If you didn't setup DNS, add the following entries in your c:\windows\system32\drivers\etc\hosts file to access the urls from your browser"
echo "$loadBalancerIP solr.$customerid.healthcatalyst.net"            
echo "$loadBalancerIP nlp.$customerid.healthcatalyst.net"            
echo "$loadBalancerIP nlpjobs.$customerid.healthcatalyst.net"            

echo "---- end of installrealtimekubernetes.sh version $version ------"
