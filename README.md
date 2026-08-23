# Server Infrastructure

이 저장소는 미니PC의 **중앙 인프라 연결 경로를 먼저 검증하기 위한 최소 구성**입니다.

현재 단계에서는 Maple/AITM/Restok 같은 실제 애플리케이션을 연결하지 않습니다. 먼저 아래 한 줄만 성공시키는 것이 목적입니다.

```text
GitHub Actions
  -> Self-hosted Windows Runner
  -> Docker Compose
  -> Nginx 테스트 프론트
  -> /health = ok
```

## 현재 포함하는 것

- Self-hosted Windows Runner에서 실행되는 수동 workflow 1개
- Dockerfile
- Docker Compose
- Nginx
- 임시 테스트 프론트
- `/health` 엔드포인트

## 현재 의도적으로 뺀 것

- 외부 SSH 배포
- 서버 비밀번호/SSH Secret
- GHCR 이미지 배포
- Maple 전용 배포
- MariaDB
- Caddy / 도메인 연결
- 자동 스케줄 배포
- 전역 Docker prune/cleanup

첫 연결을 단순하게 검증하기 위해 모두 제거했습니다.

## 1단계: Self-hosted Runner 등록

GitHub에서 다음 메뉴로 이동합니다.

```text
Server
-> Settings
-> Actions
-> Runners
-> New self-hosted runner
-> Windows / x64
```

GitHub가 화면에 보여주는 등록 명령을 **미니PC PowerShell에서 그대로 한 번 실행**합니다.

첫 smoke test에서는 Windows 서비스로 등록하지 말고, 로그인된 사용자 세션에서 `run.cmd`를 직접 실행하는 방식을 권장합니다. Docker Desktop이 사용자 세션에서 실행되는 환경에서는 이 방식이 가장 단순합니다.

Runner 화면에 `Listening for Jobs`가 보이고 GitHub에서 상태가 `Idle`이면 준비 완료입니다.

Docker Desktop도 실행 중이어야 합니다.

## 2단계: 테스트 배포 실행

GitHub에서:

```text
Server
-> Actions
-> Infrastructure smoke test
-> Run workflow
```

workflow는 미니PC 자체에서 실행됩니다. 외부에서 22번 SSH로 들어오지 않습니다.

기본 테스트 포트는 `9010`입니다. 필요하면 Repository Variable `TEST_PORT`만 다른 빈 포트로 지정하면 됩니다.

## 3단계: 성공 확인

미니PC에서:

```text
http://127.0.0.1:9010
```

또는 같은 내부망에서:

```text
http://<미니PC-내부-IP>:9010
```

Health check:

```text
http://127.0.0.1:9010/health
```

응답:

```text
ok
```

## 성공 후 다음 단계

테스트 프론트가 정상적으로 뜨는 것을 확인하면 `public/`, 테스트용 Nginx 이미지와 smoke Compose를 제거합니다.

그 다음 이 저장소에는 실제 애플리케이션 연결 정의만 추가합니다.

```text
maple repo ----\
AITM repo -------+--> Server infrastructure --> Mini PC Docker
Restok repo ----/
```

그 단계에서 GHCR, 공용 Docker network, reverse proxy, 앱별 runtime env를 하나씩 추가합니다. 한 번에 여러 요소를 넣지 않습니다.
