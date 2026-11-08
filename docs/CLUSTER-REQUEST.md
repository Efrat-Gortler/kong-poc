# Request: test OpenShift cluster access for the Kong Enterprise POC

**To:** Infrastructure / OpenShift platform team
**Purpose:** a small proof of concept for replacing the nginx reverse proxy in `flow-client` with Kong Enterprise
(DB-less, managed by the Kong Ingress Controller from Git via ArgoCD). Two simulated "legs" in one test cluster.
**Duration:** about 4–6 weeks. Everything is removable by deleting the namespaces and the cluster-scoped items below.
**Repo:** all manifests and Helm charts are in Git; nothing is applied by hand except the bootstrap below.

## 1. Cluster

- OpenShift **4.19 or later** (Gateway API CRDs are managed by the platform from 4.19; we use them, we do not install our own).
- A test/non-production cluster. No production data is involved; all users and tokens are synthetic (Keycloak inside the POC).

## 2. Namespaces

| Namespace | Contents |
|---|---|
| `leg1`, `leg2` | per leg: Kong gateway pods, Kong Ingress Controller, 3 echo backends, OPA |
| `gw-shared` | one Redis (rate-limit counters only, no persistence) |
| `idp` | Keycloak (simulates ADFS) |
| `blocking` | blocking service (.NET) + PostgreSQL (1 Gi PVC) |
| `gslb-sim` | HAProxy simulating the GSLB (round robin between the two legs) |

Label on the two leg namespaces: `kong-poc/role=leg` (used by NetworkPolicies).
Project admin (`admin` role) on all six for the requester.

## 3. Cluster-scoped items (need cluster-admin once, or done by your team)

| Item | Detail |
|---|---|
| Kong CRDs | from Kong Ingress Controller **v3.5.14** (`config/crd`): KongPlugin, KongClusterPlugin, KongConsumer, KongLicense, … |
| GatewayClass | `kong-leg1`, `kong-leg2` (controller names `konghq.com/kic-gateway-controller-leg1/2`) |
| IngressClass | `kong-leg1`, `kong-leg2` |
| KongClusterPlugin objects | a few per leg, names prefixed `leg1-` / `leg2-` |
| ClusterRole / ClusterRoleBinding | created by the official `kong/ingress` Helm chart for each controller |
| GitOps | either the **OpenShift GitOps operator** with an Argo CD instance we may use, or permission for an existing Argo CD to deploy to the namespaces above **including the cluster-scoped items in this table** |

Security context constraints: we expect **`restricted-v2` to be enough** (no root, no privileged, no host ports).
Please tell us if your policy requires anything else.

## 4. Resource quota (total for all six namespaces)

| | Requests | Limits |
|---|---|---|
| CPU | 6 cores | 12 cores |
| Memory | 12 GiB | 24 GiB |
| Storage | 2 GiB (one PVC) | |

Basis: about 3 cores / 6 GiB requested at steady state; Kong autoscales 2→5 pods per leg under the load test,
and the in-cluster image build of the .NET service needs up to 2 GiB for a few minutes.

## 5. Images (pull from Docker Hub / Quay / MCR, or mirrored to the internal registry — please tell us the path)

```
docker.io/kong/kong-gateway:3.14.0.16
docker.io/kong/kubernetes-ingress-controller:3.5.14
quay.io/keycloak/keycloak:26.0.7
docker.io/library/redis:7.4.2
docker.io/library/postgres:16.6
docker.io/library/haproxy:3.0.5
docker.io/library/python:3.12.8-slim
docker.io/openpolicyagent/opa:1.4.2-static
mcr.microsoft.com/dotnet/sdk:10.0        (build only)
mcr.microsoft.com/dotnet/aspnet:10.0
```
Helm chart: `https://charts.konghq.com`, chart `ingress`, version `0.24.0`.

The blocking service image is built **in the cluster** with a BuildConfig (Docker strategy) from the Git repo.
If Docker-strategy builds are not allowed, we will build it elsewhere and push to a registry you name.

## 6. Egress from the cluster (HTTPS 443)

| Destination | Used by | Why |
|---|---|---|
| `github.com` | Argo CD, BuildConfig | Git source of all configuration and code |
| `charts.konghq.com` | Argo CD | official Kong Helm chart |
| `eu.api.konghq.com`, `eu.kic.api.konghq.com`, `*.eu.tp0.konghq.com` | Kong Ingress Controller, Kong gateways | Kong Konnect (EU region): **Enterprise license** for the trial; receives configuration metadata (no request data) |
| image registries above | nodes | unless mirrored |

No inbound access from outside the company network is needed.

## 7. Exposure

Four OpenShift Routes on the cluster's apps domain (edge TLS): the GSLB simulator, its drain/ready control
endpoint, Keycloak, and the blocking service's Swagger UI. Please send us the **apps wildcard domain**.

## 8. What we need back

1. API URL and the apps wildcard domain.
2. Confirmation of the namespaces, quota and project admin rights.
3. Who installs the cluster-scoped items in section 3 (us with temporary cluster-admin, or your team).
4. Image source (direct pulls or internal mirror paths) and the egress rules in section 6.
5. Which Argo CD to use.
