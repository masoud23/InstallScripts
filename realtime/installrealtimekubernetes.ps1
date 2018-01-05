Write-Output "Version 2017.12.20.1"

# curl -useb https://raw.githubusercontent.com/HealthCatalyst/InstallScripts/master/realtime/installrealtimekubernetes.ps1 | iex;

$GITHUB_URL = "https://raw.githubusercontent.com/HealthCatalyst/InstallScripts/master"
$GITHUB_URL = "."

$loggedInUser = az account show --query "user.name"  --output tsv

Write-Output "user: $loggedInUser"

if ( "$loggedInUser" ) {
    $SUBSCRIPTION_NAME = az account show --query "name"  --output tsv
    Write-Output "You are currently logged in as [$loggedInUser] into subscription [$SUBSCRIPTION_NAME]"

    Do { $confirmation = Read-Host "Do you want to use this account? (y/n)"}
    while ([string]::IsNullOrWhiteSpace($confirmation))
    
    if ($confirmation -eq 'n') {
        az login
    }    
}
else {
    # login
    az login
}

Do { $AKS_PERS_RESOURCE_GROUP = Read-Host "Resource Group (e.g., fabricnlp-rg)"}
while ([string]::IsNullOrWhiteSpace($AKS_PERS_RESOURCE_GROUP))

kubectl create namespace fabricrealtime

function AskForPassword ($secretname, $prompt) {
    if ([string]::IsNullOrWhiteSpace($(kubectl get secret $secretname -n fabricrealtime -o jsonpath='{.data.password}'))) {

        # MySQL password requirements: https://dev.mysql.com/doc/refman/5.6/en/validate-password-plugin.html
        # we also use sed to replace configs: https://unix.stackexchange.com/questions/32907/what-characters-do-i-need-to-escape-when-using-sed-in-a-sh-script
        Do {
            $mysqlrootpasswordsecure = Read-host "$prompt" -AsSecureString 
            $mysqlrootpassword = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($mysqlrootpasswordsecure))
        }
        while (($mysqlrootpassword -notmatch "^[a-z0-9!.*@\s]+$") -or ($mysqlrootpassword.Length -lt 8 ))
        kubectl create secret generic $secretname --namespace=fabricrealtime --from-literal=password=$mysqlrootpassword
    }
    else {
        Write-Output "$secretname secret already set so will reuse it"
    }
}

function AskForSecretValue ($secretname, $prompt) {
    if ([string]::IsNullOrWhiteSpace($(kubectl get secret $secretname -n fabricrealtime -o jsonpath='{.data.value}'))) {

        Do {
            $certhostname = Read-host "$prompt"
        }
        while ($certhostname.Length -lt 8 )
    
        kubectl create secret generic $secretname --namespace=fabricrealtime --from-literal=value=$certhostname
    }
    else {
        Write-Output "certhostname secret already set so will reuse it"
    }    
}

AskForPassword -secretname "mysqlrootpassword"  -prompt "MySQL root password (> 8 chars, min 1 number, 1 lowercase, 1 uppercase, 1 special [!.*@] )"

AskForPassword -secretname "mysqlpassword"  -prompt "MySQL root password (> 8 chars, min 1 number, 1 lowercase, 1 uppercase, 1 special [!.*@] )"

AskForSecretValue -secretname "certhostname" -prompt "Client Certificate hostname"

AskForPassword -secretname "certpassword"  -prompt "Client Certificate password (> 8 chars, min 1 number, 1 lowercase, 1 uppercase, 1 special [!.*@] )"

AskForPassword -secretname "rabbitmqmgmtuipassword"  -prompt "Admin password for RabbitMqMgmt"

Write-Output "Cleaning out any old resources in fabricrealtime"

# note kubectl doesn't like spaces in between commas below
kubectl delete --all 'deployments,pods,services,ingress,persistentvolumeclaims,persistentvolumes' --namespace=fabricrealtime

Write-Output "Waiting until all the resources are cleared up"

Do { $CLEANUP_DONE = $(kubectl get 'deployments,pods,services,ingress,persistentvolumeclaims,persistentvolumes' --namespace=fabricrealtime)}
while (![string]::IsNullOrWhiteSpace($CLEANUP_DONE))

kubectl create -f $GITHUB_URL/realtime/realtime-kubernetes-storage.yml

kubectl create -f $GITHUB_URL/realtime/realtime-kubernetes.yml

kubectl create -f $GITHUB_URL/realtime/realtime-kubernetes-public.yml

$ipname="InterfaceEnginePublicIP"
$publicip = az network public-ip show -g $AKS_PERS_RESOURCE_GROUP -n $ipname --query "ipAddress" -o tsv;
if ([string]::IsNullOrWhiteSpace($publicip)) {
    az network public-ip create -g $AKS_PERS_RESOURCE_GROUP -n $ipname --allocation-method Static
    $publicip = az network public-ip show -g $AKS_PERS_RESOURCE_GROUP -n $ipname --query "ipAddress" -o tsv;
} 
Write-Host "Using Interface Engine Public IP: [$publicip]"

# Write-Output "Checking if DNS entries exist"
# https://kubernetes.io/docs/reference/kubectl/jsonpath/

# setup DNS
# az network dns zone create -g $AKS_PERS_RESOURCE_GROUP -n nlp.allina.healthcatalyst.net
# az network dns record-set a add-record --ipv4-address j `
#                                        --record-set-name nlp.allina.healthcatalyst.net `
#                                        --resource-group $AKS_PERS_RESOURCE_GROUP `
#                                        --zone-name 

$serviceyaml = @"
kind: Service
apiVersion: v1
metadata:
  name: interfaceengine-direct-port
  namespace: fabricrealtime
spec:
  selector:
    app: interfaceengine
  ports:
  - name: interfaceengine
    protocol: TCP
    port: 6661
    targetPort: 6661
  type: LoadBalancer  
  # Special notes for Azure: To use user-specified public type loadBalancerIP, a static type public IP address resource needs to be created first, 
  # and it should be in the same resource group of the cluster. 
  # Then you could specify the assigned IP address as loadBalancerIP
  # https://kubernetes.io/docs/concepts/services-networking/service/#type-loadbalancer
  loadBalancerIP: $publicip
---
"@

    Write-Output $serviceyaml | kubectl create -f -


$serviceyaml = @"
apiVersion: extensions/v1beta1
kind: Ingress
metadata:
  name: realtime-ingress
  namespace: fabricrealtime
  annotations:
    kubernetes.io/ingress.class: traefik
spec:
  rules:
  - http:
      paths:
      - backend:
          serviceName: certificateserverpublic
          servicePort: 80
---
"@

    Write-Output $serviceyaml | kubectl create -f -

kubectl get 'deployments,pods,services,ingress,secrets,persistentvolumeclaims,persistentvolumes,nodes' --namespace=fabricrealtime

# to get a shell
# kubectl exec -it fabric.nlp.nlpwebserver-85c8cb86b5-gkphh bash --namespace=fabricrealtime

# kubectl create secret generic azure-secret --namespace=fabricrealtime --from-literal=azurestorageaccountname="fabricrealtime7storage" --from-literal=azurestorageaccountkey="/bYhXNstTodg3MdOvTMog/vDLSFrQDpxG/Zgkp2MlnjtOWhDBNQ2xOs6zjRoZYNjmJHya34MfzqdfOwXkMDN2A=="

Write-Output "To get status of Fabric.NLP run:"
Write-Output "kubectl get deployments,pods,services,ingress,secrets,persistentvolumeclaims,persistentvolumes,nodes --namespace=fabricrealtime"

Write-Output "To launch the dashboard UI, run:"
Write-Output "kubectl proxy"
Write-Output "and then in your browser, navigate to: http://127.0.0.1:8001/ui"

$loadBalancerIP = kubectl get svc traefik-ingress-service-public -n kube-system -o jsonpath='{.status.loadBalancer.ingress[].ip}'
if([string]::IsNullOrWhiteSpace($loadBalancerIP)){
    $loadBalancerIP = kubectl get svc traefik-ingress-service-private -n kube-system -o jsonpath='{.status.loadBalancer.ingress[].ip}'
}

Write-Output "if you want, you can download the CA (Certificate Authority) cert from this url"
Write-Output "http://$loadBalancerIP/client/fabric_ca_cert.p12"

Write-Output "-------------------------------"
Write-Output "you can download the client certificate from this url:"
Write-Output "http://$loadBalancerIP/client/fabricrabbitmquser_client_cert.p12"
Write-Output "-------------------------------"
