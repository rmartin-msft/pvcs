

# Steps 
1. Create the storage accounts for each namespace

    ```bash
    az storage account create -g rg-aks-scarlett-snail --name stscarlettappsteam1 --location ukwest --kind "FileStorage" --sku "StandardV2_LRS"
    az storage account create -g rg-aks-scarlett-snail --name stscarlettappsteam2 --location ukwest --kind "FileStorage" --sku "StandardV2_LRS"
    ```

2. Update the parameters for your cluster in the json file, and run  the shell script `azure-phase.sh apps1.json`. The script will complete the Azure Configuration and output the parameters for the helm chart which deploys the storage claim and a smoke test container.

>```
>    ✅ Azure phase complete
>
>    Use the following values in Helm:
>    --------------------------------
>    workloadIdentity.clientId: <_clientId_>
>    namespace: TeamNamespace
>    serviceAccount: TeamServiceAccount
>```

3. Install the helm chart for each namespace - the chart will deploy a smoketest pod in the namespace with a pvc.

    ```bash
    helm install apps-team-1 namespace-storage --set namespace=apps-team-1 --set workloadIdentity.clientId=$clientId  --set azureFiles.storageClass.resourceGroup="rg-aks-scarlett-snail" --set azureFiles.storageClass.storageAccount="stscarlettappsteam1"
    ```

4. Check the pvc, by insepecting the smoke test pod

```
robert@Nostromo64:~/source/pvcs$ kubectl get pods -n apps-team-1
NAME                    READY   STATUS    RESTARTS   AGE
smoke-64d98c7c4-fcpqm   1/1     Running   0          9h

robert@Nostromo64:~/source/pvcs$ kubectl describe pod smoke-64d98c7c4-fcpqm -n apps-team-1
Name:             smoke-64d98c7c4-fcpqm
Namespace:        apps-team-1
Priority:         0
Service Account:  apps-team-1-sa
Node:             aks-nodepool1-12976242-vmss000002/10.224.0.6

    <--- SNIP --->

Volumes:
  vol:
    Type:       PersistentVolumeClaim (a reference to a PersistentVolumeClaim in the same namespace)
    ClaimName:  data
    ReadOnly:   false

```

Finally, you should be able to exec onto the pod to verify it's writting to the filestore

```
kubectl exec -n apps-team-1 smoke-64d98c7c4-fcpqm -- ls -l /mnt/azurefile
```

## OPA policy to enforce PVC pod workload identity

The manifests in `policies/gatekeeper` enforce that any pod in scope mounting a `PersistentVolumeClaim`:

- Uses a real `ServiceAccount` in the same namespace
- Uses `azure.workload.identity/client-id` on that `ServiceAccount`
- Optionally sets pod label `azure.workload.identity/use=true`
- Uses the expected client ID for that namespace

Apply in this order:

```bash
kubectl apply -f policies/gatekeeper/config-sync-serviceaccounts.yaml
kubectl apply -f policies/gatekeeper/constrainttemplate-pvcpod-workload-identity.yaml
kubectl apply -f policies/gatekeeper/constraint-pvcpod-workload-identity.yaml
```

Update `policies/gatekeeper/constraint-pvcpod-workload-identity.yaml` with the real per-namespace IDs:

```yaml
spec:
    parameters:
        namespaceClientIds:
            apps-team-1: "<client-id-for-apps-team-1>"
            apps-team-2: "<client-id-for-apps-team-2>"
```

Quick validation:

```bash
# should be denied if service account client-id is wrong or missing
kubectl apply -f bad-pod.yaml

# check constraint violations
kubectl get k8spvcpodworkloadidentity.constraints.gatekeeper.sh pvc-pod-workload-identity -o yaml
```