# Server Infrastructure

이 저장소는 Windows 미니PC에서 사용하는 **운영 설정 저장소**입니다. 프로덕션 서버에 직접 접속하는 CI/CD 진입점은 이 저장소가 아니라 `EST-AI-Challengers-31/saver`입니다.

## 책임 분리

```text
Aitm / Restok-Rangchain / maple
  = 애플리케이션 코드
  = Dockerfile
  = 앱 자체 CI / 테스트

EST-AI-Challengers-31/saver
  = 단일 배포 제어 지점
  = SERVER_* GitHub Secrets 소유
  = 이미지 사전 빌드
  = SSH / SCP
  = 배포 상태 기록

chl4890620123-collab/Server
  = Docker Compose
  = Caddy
  = runtime env example
  = PowerShell 배포/검증 스크립트
  = 운영 파일 정적 검증 CI

Windows mini PC
  = Docker 실행
  = 운영 DB / runtime secret / 업로드 / 영상 / 백업
```

`Server`의 GitHub Actions는 미니PC에 SSH하지 않고 self-hosted runner에서도 실행하지 않습니다. `.github/workflows/validate-operations.yml`은 PowerShell 구문, 세 서비스 Compose, Caddy 설정을 검증하고 `Server` workflow에 SSH credential 또는 self-hosted 실행이 다시 추가되면 실패하도록 경계를 검사합니다.

## 중앙 배포 흐름

```text
App main
   -> 앱 저장소 CI
   -> saver 중앙 배포 workflow
      -> App main SHA 확인
      -> Server main SHA 확인
      -> 변경 여부 비교
      -> GitHub-hosted runner에서 이미지 빌드
      -> docker save image bundle
      -> saver의 SERVER_* Secret으로 SSH/SCP
   -> Windows mini PC
      -> C:\home\server\app 에 Server main 동기화
      -> 정확한 App/Server SHA 재확인
      -> docker load
      -> Server deploy/scripts 실행
      -> DB 보호 / Compose / Caddy
      -> local + public 기능 검증
   -> saver/.ops-status 에 배포 결과 기록
```

서비스 코드뿐 아니라 `Server`의 Compose/Caddy/PowerShell이 바뀐 경우에도 새 운영 SHA로 재적용합니다. `saver`의 닿음 배포와 Aitm/Restok/Maple 배포는 동일 concurrency group을 사용해 미니PC에 대한 SSH 변경 작업이 동시에 실행되지 않도록 직렬화합니다.

## 서비스 분리

| 서비스 | 로컬 Caddy | DB 데이터 | 추가 영속 데이터 | 애플리케이션 이미지 |
| --- | --- | --- | --- | --- |
| Maple | `127.0.0.1:9040` | `D:\server-data\maple\mariadb` | runtime / backups | `maple-production-app:latest` |
| Restok | `127.0.0.1:9050` | `D:\server-data\restok\mariadb` | uploads / runtime / backups | `restok-production-*` |
| Aitm | `127.0.0.1:9060` | `D:\server-data\aitm\mariadb` | videos / runtime / backups | `aitm-production-*` |

앱별 컨테이너 이름과 Docker network는 각각 `maple-*`, `restok-*`, `aitm-*`로 분리합니다. MariaDB 포트는 호스트에 publish하지 않습니다.

## Maple

Maple 애플리케이션 이미지는 `maple` 저장소의 Dockerfile을 사용해 saver의 GitHub-hosted runner에서 먼저 빌드합니다. 미니PC에서는 소스 bind mount나 런타임 `pip install`을 애플리케이션 실행 방식으로 사용하지 않습니다.

운영 파일:

```text
deploy/compose/maple.yml
deploy/caddy/maple.Caddyfile
deploy/runtime/maple.env.example
deploy/scripts/run-maple-deploy.ps1
deploy/scripts/deploy-maple.ps1
deploy/scripts/verify-maple-rules.py
```

서버 데이터:

```text
D:\server-data\maple\runtime\.env
D:\server-data\maple\mariadb
D:\server-data\maple\backups
```

배포 검증에는 화면, 마이스터빌 카테고리/카탈로그, 재료 데이터, 고정 상점가, 길드 할인 계산 규칙이 포함됩니다.

## Restok-Rangchain

Restok의 AI, Spring Boot, React 이미지는 saver runner에서 사전 빌드한 뒤 image bundle로 미니PC에 전달합니다.

운영 파일:

```text
deploy/compose/restok.yml
deploy/caddy/restok.Caddyfile
deploy/runtime/restok.env.example
deploy/scripts/check-restok-legacy-data.ps1
deploy/scripts/deploy-restok.ps1
```

서버 데이터:

```text
D:\server-data\restok\runtime\.env
D:\server-data\restok\mariadb
D:\server-data\restok\uploads
D:\server-data\restok\backups
```

기존 Restok DB 데이터가 감지되는데 새 bind-mount DB 디렉터리가 비어 있으면 배포를 중단합니다. 기존 데이터를 자동 삭제하거나 빈 DB로 대체하지 않습니다. 앱 시작 시 charset migration은 운영 기본값 `false`입니다.

## Aitm

Aitm의 Pose AI, Spring Boot, Frontend 이미지는 saver runner에서 사전 빌드한 뒤 image bundle로 미니PC에 전달합니다.

운영 파일:

```text
deploy/compose/aitm.yml
deploy/caddy/aitm.Caddyfile
deploy/runtime/aitm.env.example
deploy/scripts/deploy-aitm.ps1
```

서버 데이터:

```text
D:\server-data\aitm\runtime\.env
D:\server-data\aitm\mariadb
D:\server-data\aitm\videos
D:\server-data\aitm\backups
```

Aitm 프론트의 `/api`와 `/media`는 Compose 내부 `backend` 서비스로 프록시합니다. `DB_CHARSET_MIGRATION_ENABLED=false`를 운영 기본값으로 사용하며, 대규모 charset 변경은 유지보수 창에서만 명시적으로 활성화합니다.

## 데이터 보호 원칙

- 운영 DB/runtime secret은 Git에 커밋하지 않습니다.
- `SERVER_HOST`, `SERVER_USER`, `SERVER_PORT`, `SERVER_SSH_KEY`, `SERVER_PASSWORD`는 saver에서만 사용합니다.
- 데이터가 있는 DB를 임의로 초기화하지 않습니다.
- 기존 DB 컨테이너가 실행 중이면 지원되는 서비스에서 배포 전 `mariadb-dump --single-transaction` 백업을 수행합니다.
- 백업 실패 시 데이터 보호를 우선하여 배포를 중단합니다.
- 전역 `docker system prune`, `docker volume prune`은 배포 스크립트에서 실행하지 않습니다.
- 앱별 DB 디렉터리, 네트워크, 컨테이너 이름, localhost 포트를 분리합니다.
- raw SSH/컨테이너 진단 로그를 Git에 커밋하지 않습니다.
- 서버에서 애플리케이션 소스를 임의 수정하지 않습니다.

## 운영 CI

현재 `Server/.github/workflows`의 프로덕션 관련 역할은 정적 검증뿐입니다.

```text
.github/workflows/validate-operations.yml
```

실제 배포 실행, SSH 인증, 배포 상태의 중앙 기록은 saver에서 담당합니다.
