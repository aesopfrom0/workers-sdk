# PR 초안 (한글) — 검토용

> 실제 제출은 영문 `PR-DRAFT.md`. 이 파일은 내용 확인용이고 **PR 에는 안 들어감**.
> 전체 맥락은 `이해하기.md` 참조.

---

## 본문 (영문과 1:1)

**#9193 관련** — 고아 `workerd` 로 가는 경로 **하나**를 막는다. 전부는 아니다.

`packages/miniflare/src/exit-hook.ts` 는 `exit`, `SIGINT`, `SIGTERM`, IPC `message` 를 듣지만
**`SIGHUP` 은 안 듣는다.** SIGHUP 이 오면 Node 가 기본 동작으로 그냥 죽어서, dispose 콜백이
실행되지 않고 `src/runtime/index.ts` 의 `runtimeProcess.kill("SIGKILL")` 에 **도달조차 못 한다.**
그래서 `workerd` 가 부모 없이 살아남는다.

이 신호 목록은 **고른 게 아니라 물려받은 것**이다. 이 파일이 대체한 `exit-hook` npm 패키지(#13515)와
같다. 일반 CLI 라면 무해하지만, **Miniflare 는 자식 프로세스를 소유**하므로 핸들러 없이 죽으면
자식이 샌다. (같은 트리에 있는 `signal-exit` 은 SIGHUP 을 듣는다.)

@kentonv 가 지목한 "**miniflare 가 어떤 상황에서 SIGKILL 전송에 실패한다**" 의 그 '어떤 상황'이 이것이다.
SIGKILL 코드는 멀쩡히 있고, 거기 도달을 못 할 뿐이다.

### 어디서 터지나

셸에서 `wrangler dev` 를 돌리면 `workerd` 가 **터미널과 같은 프로세스 그룹**에 들어간다.
SIGHUP 이 workerd 에 직접 닿아서 스스로 죽는다 — 정리 로직이 동작할 필요조차 없다.
**터미널 창을 닫는 걸로는 재현이 안 된다.** iTerm2, Zed 터미널, `tmux kill-session` 셋 다 확인함.

터지는 건 **Miniflare 를 임베드**할 때다. `vitest-pool-workers`, `@cloudflare/vite-plugin`,
`remote-bindings` 가 이렇게 쓴다. 이 경우 신호가 호스트 프로세스에만 가고,
**`vitest-pool-workers` 는 `dispose()` 를 아예 안 부르므로** 이 훅이 workerd 를 멈출 유일한 수단이다.
@koistya 의 "VSCode Vitest 확장에서 좀비 workerd", @petebacondarwin 의 "Vitest 러너 코드였을 수도"와
같은 모양이다.

최소 재현 — Miniflare 를 임베드하고 watch 모드처럼 살려둔 뒤 `kill -HUP`:

```js
const mf = new Miniflare({ script: "...", modules: true, port: 0 });
await mf.ready;
setInterval(() => {}, 1000);
```

수정 전 고아 3/3, 수정 후 정상 3/3.

### 측정

**부모에게만** 신호를 보낸다 — workerd 가 직접 받으면 스스로 죽어서 측정이 무의미해진다.
조합당 3회, GitHub 러너, wrangler 4.107.0 + miniflare 4.20260701.0:

| OS | | SIGHUP | SIGTERM | SIGINT |
|---|---|---|---|---|
| Linux | 전 | **고아 3/3** | 정상 | 정상 |
| Linux | 후 | **정상 3/3** | 정상 | 정상 |
| macOS | 전 | **고아 3/3** | 정상 | 정상 |
| macOS | 후 | **정상 3/3** | 정상 | 정상 |

앞선 macOS 30회도 같은 결과. SIGTERM/SIGINT 는 양쪽 다 정상 = **회귀 없음.**
SIGHUP 일 때 임시 디렉토리도 같이 샜는데(`removeDirSync` 가 같은 콜백에 있음) 그것도 해결된다.

### 범위

부모에 `SIGKILL` 이 오는 경우는 **원리상 못 막는다** (핸들러 등록 불가). 크래시도 마찬가지.
내가 처음 발견한 고아들은 **다른 경로였고 특정 못 했다** — 각자 다른 프로세스 그룹에 있고
그룹 리더는 이미 죽어서, 신호가 아예 안 갔다. #9193 의 "유휴 서버", "에디터 통합" 보고들은
아마 그쪽이라 **이 수정 후에도 남을 것**이다. 그건 프로세스 트리 전체를 죽여야 하는 더 큰 변경이다.

**Windows 는 미검증.** 플랫폼 분기가 없으니 같은 구멍이 있을 것 같지만,
`process.kill()` 로 SIGHUP 전달이 안 되고 `GenerateConsoleCtrlEvent` 는 `CTRL_C`/`CTRL_BREAK` 만
받아서 CI 로 측정이 불가능하다. **근거 없는 숫자를 내놓느니 안 밝히는 쪽**을 택했다.

프로세스 그룹 / `tree-kill` 방식(@danawoodman, @petebacondarwin 언급)이 더 넓게 커버한다.
이 PR 은 그것과 충돌하지 않는다 — 12줄이고 spawn 방식을 안 건드린다.

---

## 형식 점검 (2026-08-17)

### 길이

| | 설명부 단어수 |
|---|---|
| 머지된 외부 기여 PR | 8, 44, 47, 61, 101, 125, 196 |
| CF 직원 (큰 변경) | 212, 328, 360, 441, 826 |
| **내 초안 (압축 전)** | **992** ← 너무 길었음 |
| **내 초안 (압축 후)** | **636** |

여전히 외부 기여자 평균보단 길다. 다만 **근거가 실측 데이터라 줄이면 설득력이 깎인다**는 판단.
CF 직원의 큰 변경 PR 범위 안에는 들어간다.

### 압축하며 뺀 것

- kentonv + petebacondarwin **인용 2개 → 1개** (인라인으로)
- "손으로 재현하는 법" 문단 — 임베드 재현과 중복이라 삭제
- 내 고아 17개 얘기 — 특정 못 한 경로라 **길게 쓸 이유 없음**, 한 문장으로
- Windows 기술 근거 — API 이름만 남기고 설명 축소
- "실수 아니라 상속" 문단 2개 → 1개로 병합

### CI 검증 (`tools/deployments/validate-pr-description.ts`)

| 항목 | 상태 |
|---|---|
| 테스트 체크박스 `[x]` | 통과 |
| 문서 체크박스 `[x]` + 사유 | 통과 |
| changeset 파일 | 통과 |

### PR 제목

`[miniflare] Terminate workerd when the parent receives SIGHUP`
→ 리포 규칙 `[패키지명] 설명` 형식 준수

---

## AI 기여 명시 — 넣기로 한 근거

리포 PR 템플릿이 요청하는 항목이고, 실제로 쓰는 사람들이 있다:

| PR | 작성자 | 명시 |
|---|---|---|
| #15114 | **petebacondarwin** (CF, #9193 담당자) | opencode, claude-opus-5 |
| #15000 | **edmundhung** (CF) | Codex, GPT-5 |
| #15010 | **LeSingh1** (외부, 9일 만에 머지) | **Claude Code** |

- 메인테이너 본인이 쓴다 → "AI 썼으면 감점" 이 아니라 운영 관례
- 같은 도구로 명시한 외부 PR 이 이미 머지됨
- 안 쓰는 사람도 많다 (머지 40건 중 18건) → 안 써도 거절 사유는 아님

**관여 범위까지 밝히는 이유**: 템플릿이 이 항목을 요청하는 목적이 "메인테이너가 어떤 응답을
기대할지 알기 위해서"다. "AI 씀" 한 줄로는 정보가 없다.
**진단·하네스는 에이전트 / CI 크로스플랫폼 검증 판단과 범위 결정은 사람**으로 나눠 적었다.

---

## 남은 판단

1. **Windows 검증 없이 지금 낼지** — 주 근거가 "터미널 닫기"에서 "임베드"로 바뀌면서
   Windows 창 닫기 검증의 가치가 떨어졌다. 게다가 임베드 경로는 Windows 에서 **측정 자체가 불가능**하다
   (`process.kill` 로 SIGHUP 전달 불가). 지금 내도 잃는 게 거의 없다는 판단.
2. **636단어가 여전히 긴지** — 더 줄이려면 측정 표나 범위 설명을 깎아야 하는데, 그건 설득력 손실.
