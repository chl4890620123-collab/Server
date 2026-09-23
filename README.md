# Server Infrastructure

이 저장소는 Windows 미니PC에서 사용하는 **운영 설정 저장소**입니다. 프로덕션 서버에 직접 접속하는 CI/CD 진입점은 이 저장소가 아니라 `EST-AI-Challengers-31/saver`입니다.

## 책임 분리

```text
chl4890620123-collab/hub
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
  = 운영 DB / runtime secret / 업로드 / 백업
```

`Server`의 GitHub Actions는 미니PC에 SSH하지 않고 self-hosted runner에서도 실행하지 않습니다. `.github/workflows/validate-operations.yml`은 PowerShell 구문, Hub Compose, Caddy 설정을 검증하고 `Server` workflow에 SSH credential 또는 self-hosted 실행이 다시 추가되면 실패하도록 경계를 검사합니다.

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

서비스 코드뿐 아니라 `Server`의 Compose/Caddy/PowerShell이 바뀐 경우에도 새 운영 SHA로 재적용합니다. Hub 배포는 `deploy-hub` concurrency group으로 직렬화되어, 재트리거 시 이전 시도를 즉시 취소하고 미니PC에 대한 SSH 변경 작업이 동시에 실행되지 않도록 합니다.

## Hub

| 로컬 Caddy | DB 데이터 | 추가 영속 데이터 | 애플리케이션 이미지 |
| --- | --- | --- | --- |
| `HUB_HOST_PORT` (기본 9070) | `D:\server-data\hub\postgres` | storage / backups | `hub-production-ai:latest`, `hub-production-backend:latest` |

Hub 애플리케이션 이미지는 `hub` 저장소의 Dockerfile을 사용해 미니PC에서 직접 빌드합니다 (`ai-service`, `backend` 두 이미지).

운영 파일:

```text
deploy/compose/hub.yml
deploy/caddy/hub.Caddyfile
deploy/runtime/hub.env.example
deploy/scripts/deploy-hub.ps1
```

서버 데이터:

```text
D:\server-data\hub\runtime\.env
D:\server-data\hub\postgres
D:\server-data\hub\storage
D:\server-data\hub\backups
```

컨테이너 이름과 Docker network는 `hub-*`로 분리합니다. DB 포트는 호스트에 publish하지 않습니다. Hub는 공유 Caddy(`saver-caddy-1`, dahum/moveai/yellow-server 전용)를 거치지 않고 `yellow.it.kr:HUB_HOST_PORT`로 직접 노출됩니다 (`deploy/scripts/ensure-public-route.ps1`은 다른 앱들을 위해 남아있을 뿐, hub 배포는 더 이상 호출하지 않습니다).

## 데이터 보호 원칙

- 운영 DB/runtime secret은 Git에 커밋하지 않습니다.
- `SERVER_HOST`, `SERVER_USER`, `SERVER_PORT`, `SERVER_SSH_KEY`, `SERVER_PASSWORD`는 saver에서만 사용합니다.
- 데이터가 있는 DB를 임의로 초기화하지 않습니다.
- 전역 `docker system prune`, `docker volume prune`은 배포 스크립트에서 실행하지 않습니다 (수동 트리거인 `cleanup-docker-images.yml`만 dangling 이미지를 정리합니다).
- raw SSH/컨테이너 진단 로그를 Git에 커밋하지 않습니다.
- 서버에서 애플리케이션 소스를 임의 수정하지 않습니다.

## 운영 CI

현재 `Server/.github/workflows`의 프로덕션 관련 역할은 정적 검증뿐입니다.

```text
.github/workflows/validate-operations.yml
```

실제 배포 실행, SSH 인증, 배포 상태의 중앙 기록은 saver에서 담당합니다.
