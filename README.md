# Server Infrastructure

이 저장소는 Windows 미니PC의 중앙 배포/운영 진입점입니다.

## 책임 분리

```text
각 앱 저장소
  = 앱 코드 + Dockerfile + 앱 자체 CI

Server 저장소
  = Self-hosted Runner + 운영 Compose + Caddy + 배포 스크립트

D:\server-data
  = 운영 DB + runtime env + 백업
```

외부 SSH 배포를 기본 경로로 사용하지 않습니다. GitHub Actions의 Windows self-hosted runner가 미니PC에서 직접 Docker 명령을 실행합니다.

## Infrastructure smoke test

기존 smoke test는 그대로 유지합니다.

```text
GitHub Actions
  -> Self-hosted Windows Runner
  -> Docker Compose
  -> Nginx 테스트 화면
  -> HTTP 200
```

기본 포트는 `9010`입니다.

## Maple 배포

Maple은 Server가 최신 `chl4890620123-collab/maple` main을 직접 가져와 배포합니다.

```text
Maple main
   -> Server self-hosted runner
   -> Maple Docker build
   -> MariaDB 11.4
   -> Caddy internal reverse proxy
   -> Cloudflare Quick Tunnel
   -> public HTTPS preview URL
```

운영 Compose:

```text
deploy/compose/maple.yml
```

배포 스크립트:

```text
deploy/scripts/deploy-maple.ps1
```

Caddy 설정:

```text
deploy/caddy/maple.Caddyfile
```

### 서버 전용 데이터

GitHub 저장소에는 실제 운영 비밀번호를 저장하지 않습니다.

```text
D:\server-data\maple\runtime\.env
D:\server-data\maple\mariadb
D:\server-data\maple\backups
```

첫 배포 때 runtime `.env`가 없으면 긴 랜덤 `ADMIN_TOKEN`, DB 비밀번호, DB root 비밀번호를 서버에서 자동 생성합니다.

MariaDB의 `3306` 포트는 호스트나 인터넷에 publish하지 않습니다.

### 로컬 검증 주소

Caddy는 기존 80/443 서비스와 충돌하지 않도록 localhost 전용 포트를 사용합니다.

```text
http://127.0.0.1:9040
```

포트가 이미 다른 서비스에 사용 중이면 배포를 중단합니다. 기존 서비스 포트를 강제로 종료하거나 변경하지 않습니다.

### 공개 검수 URL

별도 도메인 정보가 없는 현재 단계에서는 Cloudflare Quick Tunnel을 사용해 임시 HTTPS URL을 자동 발급합니다.

```text
https://<random>.trycloudflare.com
```

배포 스크립트는 공개 `/api/health`와 실제 Maple 화면의 HTTP 200을 모두 확인한 뒤에만 성공 처리합니다.

성공한 URL은 다음 파일에 기록됩니다.

```text
deploy/status/maple.txt
```

이 Quick Tunnel은 검수/프리뷰용이며 컨테이너를 새로 만들면 URL이 변경될 수 있습니다. 실제 고정 Gabia 도메인이 Server에 등록되면 동일한 Caddy upstream을 고정 도메인으로 교체하면 됩니다.

## 자동 배포

`.github/workflows/deploy-maple.yml`은 다음 경우 실행됩니다.

- Server의 Maple 운영 파일 변경
- 수동 `workflow_dispatch`
- 15분 주기 동기화

15분 주기 실행에서 Maple `main`이 변경되면 최신 코드를 가져옵니다. Docker layer cache는 미니PC에 유지됩니다.

## 데이터 보호

기존 MariaDB 컨테이너가 실행 중이면 새 배포 전에 `mariadb-dump` 백업을 먼저 생성합니다.

```text
D:\server-data\maple\backups\maple_YYYYMMDD_HHMMSS.sql
```

백업에 실패하면 기존 DB를 보호하기 위해 배포를 중단합니다. 28일이 지난 자동 백업만 정리하며, 전역 `docker system prune`이나 `docker volume prune`은 실행하지 않습니다.
