# RHOAI and Model-as-a-Service Manifests

Manifests for bringing up **Red Hat OpenShift AI (RHOAI) 3** and **Models-as-a-Service (MaaS)** on OpenShift.

## Recommended: Install with Kustomize

Use Kustomize for a repeatable, phased install of RHOAI and MaaS.

- **RHOAI 3.4:** run `./bootstrap.sh` or see **[rhoai-3_4/KUSTOMIZE.md](rhoai-3_4/KUSTOMIZE.md)**
- **RHOAI 3.3 (legacy):** **[rhoai-3_3/KUSTOMIZE.md](rhoai-3_3/KUSTOMIZE.md)** 

-----

## Notes
Install maas using kustomize. 

Install notes:
1. Install operators Cert manager and leader worker set

2. Apply lws-operator-cr

3. Install rhcl
~~Make sure csv for rhcl has: - name: ISTIO_GATEWAY_CONTROLLER_NAMES~~

    ~~value: 'istio.io/gateway-controller,openshift.io/gateway-controller/v1'~~

4. Check tls cert for Gateway/maas-default-gateway.yaml in openshift-ingress and apply

5. Apply Kuadrant custom resource in rh-connectivity-link

6. Deploy postgres... MaaS **REQUIRES** a database for RHOAI 3.4. maas-api will look for this database by `maas-db-config` secret.

6. Install rhoai.... Make sure odhdashboard config is updated and dsc is updated. Llamastack needs to be enabled too

7. The Tenant resource is for `maas-controller` deployment. The `default-tenant` lives in `model-as-a-service` namespace. The tenant resource is created by the dsc, but Authorino will need to be updated with the cert.

7.1 Update Kuadrant / rh-connectivity-link ns — service authorinio-authorinio-authorization

```
annotations:
    service.beta.openshift.io/serving-cert-secret-name: authorino-server-cert
```

7.2 Update Authorino authorinio:spec:

```
  clusterWide: true
  healthz: {}
  listener:
    ports: {}
    tls:
      certSecretRef:
        name: authorino-server-cert
      enabled: true
```

8. Update rhoai dashboard with OdhDashboardConfig. Restart rhoai-dashboard pods.

9. Delete kuadrant-operator-controller-manager in rh-connectivity-link if llm doesn’t come up because of authoring. check authpolicy - maas-api-auth-policy (it said to restart kuadrant operator-controller-manager pod).

10. Apply simulated models

11. Apply maas-subscriptions

| Resource | Purpose |
|----------|---------|
| **LLMInferenceService** | The LLM workload — the actual inference service (simulator, vLLM, etc.) |
| **MaaSModelRef** | Gives the MaaS system a reference to the model so it appears in the model catalog |
| **MaaSAuthPolicy** | Grants access to the model for specified groups (who can use it) |
| **MaaSSubscription** | Defines rate limits (token quotas) for specific groups |

12. TokenRatePolicy is automatically created per model. Search for this in the model namespace and update it.

13. RHOAI Observability Dashboard needs these operators:
 - Cluster Observability Operator: Deploys and manages Prometheus and Alertmanager for metrics and alerts.
 - Tempo Operator: Provides the Tempo backend for distributed tracing.
 - Red Hat build of OpenTelemetry: Deploys the OpenTelemetry Collector for collecting and exporting telemetry data.

 Update RHOAI default-dsci in the `spec.monitoring`. Look at `rhoai-3_4/base/instances/rhoai-observability-dashboard/default-dsci.yaml`.
 OdhDashboardConfig `spec.dashboardConfig`: `observabilityDashboard: true`. (Already updated already in `rhoai-3_4/base/instances/odhdashboard/odh-dashboard-config.yaml`)

## Validation

Please use for validation: https://opendatahub-io.github.io/models-as-a-service/v0.1.1/install/validation/