# 🏫 EduSphere — CI/CD & Infrastructure Guide

## 📁 Project Structure

```
school-app/
├── .github/
│   └── workflows/
│       ├── ci-cd.yml        ← Main CI/CD pipeline
│       └── destroy.yml      ← Manual infra teardown (staging only)
├── terraform/
│   └── main.tf              ← VPC, EKS, ECR, RDS, S3 on AWS (ap-south-1)
├── k8s/
│   └── deployment.yaml      ← Deployment, Service, Ingress, HPA, PDB
├── monitoring/
│   ├── prometheus-values.yaml   ← Helm values for kube-prometheus-stack
│   ├── prometheus-rules.yaml    ← Custom alerting rules
│   └── service-monitor.yaml     ← ServiceMonitor + Grafana dashboard
├── Dockerfile               ← Multi-stage production build
└── README.md
```

---

## 🔐 Required GitHub Secrets

Go to: **Settings → Secrets → Actions → New repository secret**

| Secret Name              | Description                                      |
|--------------------------|--------------------------------------------------|
| `AWS_ACCESS_KEY_ID`      | IAM user access key (SRE deploy role)            |
| `AWS_SECRET_ACCESS_KEY`  | IAM user secret key                              |
| `TF_STATE_BUCKET`        | S3 bucket name for Terraform remote state        |
| `TF_API_TOKEN`           | Terraform Cloud token (if using TF Cloud)        |
| `DB_PASSWORD`            | RDS PostgreSQL password (min 16 chars)           |
| `GRAFANA_ADMIN_PASSWORD` | Grafana admin login password                     |
| `SLACK_WEBHOOK_URL`      | Slack incoming webhook for deploy notifications  |
| `CODECOV_TOKEN`          | Codecov.io token for coverage reports            |

---

## 🚀 Pipeline Flow

```
Push to main/develop
        │
        ▼
┌─────────────────┐     ┌─────────────────┐
│ Lint & Security │     │   Run Tests     │
│  (Trivy, OWASP) │     │  (Unit + Integ) │
└────────┬────────┘     └────────┬────────┘
         └──────────┬────────────┘
                    ▼
         ┌─────────────────────┐
         │  Build & Push to    │
         │  AWS ECR (ap-south) │
         │  + Trivy image scan │
         └──────────┬──────────┘
                    ▼
         ┌─────────────────────┐
         │  Terraform Apply    │
         │  VPC + EKS + RDS    │
         │  + ECR + S3         │
         └──────────┬──────────┘
                    ▼
         ┌─────────────────────┐
         │  Deploy to EKS      │
         │  Rolling update     │
         │  Smoke tests        │
         └──────────┬──────────┘
                    ▼
         ┌─────────────────────┐
         │ Deploy Monitoring   │
         │ Prometheus + Grafana│
         │ kube-prometheus-    │
         │ stack via Helm      │
         └──────────┬──────────┘
                    ▼
        ┌──────────────────────┐
        │  Notify Slack ✅     │
        │  (or rollback ↩️ )   │
        └──────────────────────┘
```

---

## 🏗️ Infrastructure (Terraform — ap-south-1 Mumbai)

| Resource        | Staging          | Production         |
|-----------------|------------------|--------------------|
| **VPC**         | 10.0.0.0/16, single NAT | 10.0.0.0/16, multi-NAT |
| **EKS**         | t3.small, 1–2 nodes | t3.medium, 2–6 nodes |
| **RDS**         | db.t3.micro, 20GB | db.t3.small, 50GB, Multi-AZ |
| **ECR**         | Shared, retains 20 images | Same |
| **S3**          | Static assets, private | Same |

---

## ☸️ Kubernetes Resources

| Resource              | Details                              |
|-----------------------|--------------------------------------|
| **Deployment**        | RollingUpdate, maxUnavailable=0      |
| **HPA**               | CPU >70% or Memory >80% → scale up  |
| **PodDisruptionBudget** | minAvailable=1 (zero-downtime)    |
| **Ingress**           | AWS ALB, HTTPS, SSL redirect         |
| **SecurityContext**   | Non-root, readOnly FS, no privileges |

---

## 📊 Monitoring (Prometheus + Grafana)

### Dashboards
- **EduSphere Overview** — RPS, error rate, P50/P95/P99 latency, pod count, CPU/memory

### Alerts Configured
| Alert                              | Severity | Threshold         |
|------------------------------------|----------|-------------------|
| App Down                           | Critical | 1 min             |
| HTTP Error Rate > 5%               | Critical | 2 min             |
| P95 Latency > 2s                   | Warning  | 5 min             |
| Pod CrashLooping                   | Critical | 3 restarts/15min  |
| CPU > 80%                          | Warning  | 10 min            |
| Memory > 85%                       | Warning  | 5 min             |
| HPA at Max Replicas                | Warning  | 10 min            |

### Access Grafana
```
https://grafana.edusphere.yourdomain.com
Username: admin
Password: (set via GRAFANA_ADMIN_PASSWORD secret)
```

---

## 🔄 Manual Operations

```bash
# Trigger deploy to staging manually
gh workflow run ci-cd.yml -f environment=staging

# Rollback to previous version
kubectl rollout undo deployment/school-demo -n production

# Check app logs
kubectl logs -l app=school-demo -n production --tail=100 -f

# Port-forward Grafana locally
kubectl port-forward svc/kube-prometheus-stack-grafana 3001:80 -n monitoring
```

---

## ⚠️ Important Notes

1. **IAM Permissions** — The deploy IAM user needs: `AmazonEKSClusterPolicy`, `AmazonEC2ContainerRegistryPowerUser`, `AmazonRDSFullAccess`, `AmazonS3FullAccess`
2. **Rotate IAM keys** regularly (every 90 days) — never commit keys to the repo
3. **ACM Certificate** — Update the certificate ARN in `k8s/deployment.yaml` before deploying to production
4. **Terraform State Lock** — Create a DynamoDB table named `edusphere-tf-locks` before first run
