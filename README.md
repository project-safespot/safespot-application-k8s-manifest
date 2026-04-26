# SafeSpot Kubernetes Manifest Repository

## 1. 개요

이 저장소는 SafeSpot 서비스 배포를 위한 Kubernetes 매니페스트 및 Helm 차트를 관리한다.

애플리케이션 코드와 Docker 이미지는 별도의 저장소에서 관리된다:

* safespot-application (백엔드)
* safespot-front (프론트엔드)

---

## 2. 관리 범위 (Scope)

이 저장소는 아래 서비스만 관리한다:

* api-core
* api-public-read
* external-ingestion
* nginx (웹)

다음 인프라 구성 요소는 관리하지 않는다:

* PostgreSQL
* Redis
* LocalStack
* Exporter (Prometheus exporter 등)

---

## 3. Namespace

모든 애플리케이션 워크로드는 아래 namespace에 배포된다:

```text
application
```

---

## 4. Label 규칙 (필수)

모든 Kubernetes 리소스는 반드시 아래 label을 포함해야 한다:

```yaml
metadata:
  labels:
    app: <서비스명>
    service: <서비스명>
    env: dev
```

서비스별 매핑:

| 서비스                | app                | service            |
| ------------------ | ------------------ | ------------------ |
| api-core           | api-core           | api-core           |
| api-public-read    | api-public-read    | api-public-read    |
| external-ingestion | external-ingestion | external-ingestion |
| nginx              | nginx              | nginx              |

---

## 5. 인프라 엔드포인트

아래 인프라 서비스는 이미 클러스터에 구성되어 있다:

### PostgreSQL

```
postgres-postgresql.safespot-db.svc.cluster.local:5432
```

### Redis

```
redis-master.safespot-cache.svc.cluster.local:6379
```

### LocalStack

```
http://localstack.safespot-localstack.svc.cluster.local:4566
```

---

## 6. 네트워크 구성

### 내부 통신

```
Spring Boot → Redis / PostgreSQL / LocalStack
```

### 외부 접근

```
Ingress (nginx) + MetalLB
```

---

## 7. Ingress 라우팅

```
/           → nginx:80
/api/core   → api-core:8080
/api/public → api-public-read:8080
```

---

## 8. 환경 설정

### ConfigMap

```env
SPRING_PROFILES_ACTIVE=dev
DB_HOST=postgres-postgresql.safespot-db.svc.cluster.local
DB_PORT=5432
DB_NAME=safespot
REDIS_HOST=redis-master.safespot-cache.svc.cluster.local
REDIS_PORT=6379
AWS_REGION=ap-northeast-2
AWS_ENDPOINT=http://localstack.safespot-localstack.svc.cluster.local:4566
```

### Secret

```env
DB_USER=safespot
DB_PASSWORD=safespot1234
AWS_ACCESS_KEY_ID=test
AWS_SECRET_ACCESS_KEY=test
JWT_SECRET=<추후 정의>
```

---

## 9. 이미지 규칙

### 로컬 개발 (values-local.yaml)

```
safespot/api-core:local
safespot/api-public-read:local
safespot/external-ingestion:local
safespot/nginx:local
```

### CI/CD (values-dev.yaml)

```
ghcr.io/project-safespot/safespot-api-core:<IMAGE_TAG>
ghcr.io/project-safespot/safespot-api-public-read:<IMAGE_TAG>
ghcr.io/project-safespot/safespot-external-ingestion:<IMAGE_TAG>
ghcr.io/project-safespot/safespot-nginx:<IMAGE_TAG>
```

---

## 10. 배포 정책

```yaml
apiCore.enabled=true
apiPublicRead.enabled=true
externalIngestion.enabled=true
nginx.enabled=true
```

---

## 11. Helm Chart 구조

```
charts/safespot/
├── Chart.yaml
├── values.yaml              # 공통 기본값 (tag: latest, pullPolicy: Always)
├── values-local.yaml        # 로컬 오버라이드 (tag: local, pullPolicy: IfNotPresent)
├── values-dev.yaml          # CI/CD 오버라이드 (GHCR 이미지, pullPolicy: Always)
└── templates/
    ├── namespace.yaml
    ├── configmap.yaml
    ├── secret.yaml
    ├── deployment-api-core.yaml
    ├── deployment-api-public-read.yaml
    ├── deployment-external-ingestion.yaml
    ├── deployment-nginx.yaml
    ├── service-api-core.yaml
    ├── service-api-public-read.yaml
    ├── service-external-ingestion.yaml
    ├── service-nginx.yaml
    ├── ingress.yaml
    ├── hpa-api-core.yaml
    ├── hpa-api-public-read.yaml
    └── hpa-external-ingestion.yaml
```

### values 파일 분리 전략

| 파일 | 용도 | 사용 주체 |
| --- | --- | --- |
| `values.yaml` | 공통 기본값. 모든 환경의 베이스 | 직접 사용하지 않음 |
| `values-local.yaml` | 로컬 개발용. `tag: local`, `pullPolicy: IfNotPresent` | 개발자 로컬 |
| `values-dev.yaml` | CI/CD용. GHCR 이미지, `pullPolicy: Always` | GitHub Actions / Argo CD |

---

## 12. 배포 명령어

### 로컬 검증

```bash
helm lint charts/safespot

helm template safespot charts/safespot \
  -f charts/safespot/values-local.yaml
```

### 로컬 설치 / 업그레이드

```bash
helm upgrade --install safespot charts/safespot \
  -f charts/safespot/values-local.yaml \
  --namespace application \
  --create-namespace
```

### 삭제

```bash
helm uninstall safespot --namespace application
```

---

## 13. CI/CD and Argo CD Workflow

### 배포 흐름

```
GitHub Actions (safespot-application)
  → Docker 이미지 빌드 및 GHCR 푸시
  → k8s-manifest 저장소의 values-dev.yaml 이미지 태그 업데이트
  → Git push (main 브랜치)
  → Argo CD가 변경 감지
  → Kubernetes 자동 배포 (selfHeal + prune)
```

### Argo CD Application

Argo CD 매니페스트는 `argocd/application-safespot.yaml`에 위치한다.

```yaml
source:
  repoURL: https://github.com/project-safespot/k8s-manifest.git
  targetRevision: main
  path: charts/safespot
  helm:
    valueFiles:
      - values-dev.yaml

syncPolicy:
  automated:
    prune: true
    selfHeal: true
  syncOptions:
    - CreateNamespace=true
```

Argo CD 등록 명령어:

```bash
kubectl apply -f argocd/application-safespot.yaml
```

### CI에서 이미지 태그 주입 예시

```bash
helm upgrade --install safespot charts/safespot \
  -f charts/safespot/values-dev.yaml \
  --set apiCore.image.tag=<IMAGE_TAG> \
  --set apiPublicRead.image.tag=<IMAGE_TAG> \
  --set externalIngestion.image.tag=<IMAGE_TAG> \
  --set nginx.image.tag=<IMAGE_TAG>
```

### 환경별 values 파일 사용 원칙

* `values-local.yaml` — 개발자 로컬 환경 전용. `docker build`로 생성한 로컬 이미지를 사용한다.
* `values-dev.yaml` — CI/CD 전용. GitHub Actions가 이미지 태그를 주입하며, Argo CD가 이 파일을 기준으로 동기화한다.
* Argo CD는 항상 `values-dev.yaml`을 사용한다.

---

## 14. 주의사항

* 이 저장소에서 인프라 리소스를 생성하지 않는다.
* 환경별 설정은 반드시 values 파일로 관리한다.
* 민감 정보는 Secret, 일반 설정은 ConfigMap을 사용한다.
* `values-dev.yaml`의 `tag: PLACEHOLDER`는 CI 파이프라인이 실제 이미지 태그로 교체한다. 직접 수정하지 않는다.
