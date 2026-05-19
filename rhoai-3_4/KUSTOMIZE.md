# Installing RHOAI 3.4 and Dependencies with Kustomize

This repo uses [Kustomize](https://kustomize.io/) to install Red Hat OpenShift AI (RHOAI) 3.4, its operator dependencies, and the Models-as-a-Service (MaaS) stack in a repeatable, GitOps-friendly way.

## Install order (phased)

Apply overlays **in order** and wait for each phase before the next.

| Phase | Overlay | What it does |
|-------|---------|--------------|
| 1 | `overlays/01-operators` | NFD, NVIDIA, cert-manager, RHCL, LWS, RHOAI 3.4, Cluster Observability, Tempo, OpenTelemetry |
| 2 | `overlays/02-nfd-nvidia-lws-instances` | NFD instance, NVIDIA ClusterPolicy, LWS instance, Kuadrant |
| 3 | `overlays/03-gateway` | GatewayClass and MaaS Gateway (hostname set by `bootstrap.sh`) |
| 4 | `overlays/04-rhoai` | DataScienceCluster and Authorino NetworkPolicy |
| 10 | `overlays/10-observability-dashboard-rhoai` | DSCInitialization with managed monitoring/traces |
| 5 | `overlays/05-odhdashboard` | OdhDashboardConfig (MaaS, GenAI Studio, observability dashboard) |
| 6 | `overlays/06-postgres` | Postgres + `maas-db-config` secret |
| 7 | `overlays/07-maas-controller` | MaaS CRDs, RBAC, gateway policies |
| 8 | `overlays/08-simulated-models` | Demo LLMInferenceServices |
| 9 | `overlays/09-maas-subscriptions` | MaaSModelRef, MaaSAuthPolicy, MaaSSubscription |

## One-click install

```bash
# From repo root, with oc logged in
./bootstrap.sh
```

`bootstrap.sh` waits for operator install plans, patches the gateway hostname from the cluster ingress domain, configures Authorino TLS, and applies all overlays above.

## Manual steps (if needed)

1. After RHCL operator install, confirm `ISTIO_GATEWAY_CONTROLLER_NAMES=istio.io/gateway-controller,openshift.io/gateway-controller/v1` on the RHCL CSV/deployment.
2. Ensure `cert-manager-ingress-cert` exists in `openshift-ingress` for the Gateway HTTPS listener.
3. After postgres is up, confirm the DSC-managed `maas-api` deployment uses `maas-db-config` (see `base/instances/postgres/maas-api.yaml` as reference).
4. If tokens fail, restart `kuadrant-operator-controller-manager` in `rh-connectivity-link` (see README).

## Validation

https://opendatahub-io.github.io/models-as-a-service/latest/install/validation/
