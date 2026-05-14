---
description: claude-token-visualizer 검증·배포 워크플로우 (simplify → typecheck/build → prettier → review → push)
---

claude-token-visualizer 프로젝트의 변경분을 4단계 검증 후 배포한다. 변경 파일의 언어(TypeScript / Swift)에 따라 typecheck/build 와 review 단계는 자동 분기한다.

## 진행 순서

### 0. 변경분 확인

- 이 프로젝트는 `dev`에서 작업하고 `main`에 머지하는 흐름. /ship 은 **현재 브랜치에서 base 대비 ahead 된 커밋의 변경 파일**을 검증 대상으로 본다 (working tree 가 아님).
- 우선 working tree 가 깨끗한지 확인 (`git status --porcelain` 이 비어야 함). 비어있지 않으면 "커밋되지 않은 변경분 있음. /ship 전에 커밋 또는 stash 필요" 보고하고 종료.
- base 결정 순서:
    1. 현재 브랜치에 upstream(`@{u}`) 있으면 그것
    2. 없고 현재 브랜치가 `main` 아니면 로컬 `main`
    3. 둘 다 아니면 (예: 첫 push 의 `main` 자체) HEAD 의 모든 파일을 대상으로 본다
- 변경 파일 목록: `git diff <base>...HEAD --name-only` (또는 fallback 시 `git ls-tree -r HEAD --name-only`)
- 변경분이 없으면 "배포할 변경분 없음 (base=<base>, branch=<current>)" 보고하고 종료

### 1. simplify (sub-agent 위임)

- `claude` (general-purpose) sub-agent 1개에 변경된 파일 목록 전달
- `/ecc:simplify` 또는 simplify skill 을 호출해 변경분을 리뷰하고 발견된 이슈 정리
- 결과 보고: 어떤 정리가 일어났는지, 추가로 변경된 파일
- **commit/merge/push 금지** 명시
- 변경된 파일이 .ts/.js/.cjs/.mjs/.swift 가 하나도 없으면 skip (단순 docs/Asset 변경 등)

### 2. typecheck / build (메인이 직접)

언어별로 분기. 변경된 파일 확장자에 따라:

- 변경된 `.ts` 파일이 있으면 `npm run typecheck` (tsc --noEmit) 실행
- 변경된 `.swift` 파일이 있으면 `xcodebuild -project app/ClaudeTokenViz/ClaudeTokenViz.xcodeproj -scheme ClaudeTokenViz -configuration Debug -destination 'generic/platform=macOS' build` 실행
    - 출력이 길면 `| grep -E '(error:|warning:|BUILD)' | tail -20` 으로 요약
- 둘 다 있으면 둘 다 실행, 모두 통과해야 함
- 하나라도 실패하면 fail 처리 후 사용자에게 보고하고 종료
- 해당 파일이 하나도 없으면 skip

### 3. prettier check (메인이 직접)

- 변경된 파일 중 prettier 가 처리하는 확장자(.ts .js .cjs .mjs .json .md 등) 만 추려서
  `npx prettier --check <files>` 실행
- `.swift` 는 prettier 대상 아님 — Xcode 자체 포맷 사용. swift-format 도입 시점은 별도 결정.
- `.pbxproj` 와 Xcode Asset Catalog (`*.xcassets/*/Contents.json`) 는 Xcode 가 관리하므로 prettier 검사 제외 (실수로 포함되면 fail 위험 → 명시적 제외 필요)
- 실패하면 fail. (자동 fix `--write` 금지 — 의도하지 않은 포맷 변경 방지)
- 해당 파일이 없으면 skip

### 4. code review (sub-agent 위임)

변경된 파일의 언어에 따라 reviewer 분기:

- 변경된 `.ts`/`.js`/`.cjs`/`.mjs` 파일이 있으면 `ecc:typescript-reviewer` 호출
- 변경된 `.swift` 파일이 있으면 `general-purpose` 호출 (전용 Swift reviewer 없음). 프롬프트에 다음 Swift/SwiftUI 관점 명시:
    - 메모리 안전 / 강한 참조 사이클
    - `@MainActor` 격리, `Sendable` 적합성, structured concurrency 사용
    - `MenuBarExtra` / `NSStatusItem` 특이사항
    - Keychain 접근 (Security framework, sandbox 영향)
    - `URLSession` async/await 에러 처리
    - SwiftUI `@State` / `@StateObject` / `@Observable` 적절성
- 위임 프롬프트에 변경 파일 목록 + `git diff <base>...HEAD -- <ext-filtered-files>` 컨텍스트 전달 (step 0 의 base 와 동일)
- 위임 프롬프트 끝에 반드시 다음 문구 포함:
    > 리뷰 결과의 **마지막 줄에 정확히 `APPROVE` 또는 `BLOCK: <한 줄 사유>` 만** 출력해. 다른 어떤 텍스트도 마지막 줄에 두지 마.
- 응답의 마지막 비공백 줄을 파싱
- 두 reviewer 모두 호출한 경우 양쪽 모두 `APPROVE` 여야 통과. 하나라도 `BLOCK:` 이면 차단.
- 해당 파일이 하나도 없으면 skip

### 5. 상태 기록

- 위 단계 모두 통과한 경우에만:
    - `.claude/state/gate.json` 작성 (디렉토리 없으면 mkdir -p)
    - 구조:
        ```json
        {
            "verified": true,
            "verifiedAt": "<ISO timestamp>",
            "stages": {
                "simplify": true,
                "typecheck_ts": true,
                "build_swift": true,
                "prettier": true,
                "review_ts": true,
                "review_swift": true
            },
            "changedFiles": ["..."],
            "reviewerSummary": "<reviewer 가 준 한 줄 요약 (ts/swift 합쳐서)>"
        }
        ```
- skip 된 단계는 `stages` 에 `"skipped"` 로 기록

### 6. 사용자 큐사인 대기

- 검증 결과 표로 보고:
  | 단계 | 결과 |
  |---|---|
  | simplify | ✅ / skipped / ❌ |
  | typecheck (ts) | ✅ / skipped / ❌ |
  | build (swift) | ✅ / skipped / ❌ |
  | prettier | ✅ / skipped / ❌ |
  | review (ts) | ✅ / skipped |
  | review (swift) | ✅ / skipped |
- "push 진행할까?" 물어봄
- 사용자가 명시적 OK ("ㅇㅇ", "진행", "yes", "push" 등) 줄 때까지 대기

### 7. push (사용자 OK 후)

- 현재 브랜치 확인 (`git branch --show-current`)
- remote 가 설정되어 있는지 확인 (`git remote -v`)
- **remote 없음**: gate.json 만 기록하고 "remote 미설정 — 로컬 verified 상태. 나중에 remote 추가 후 push 하면 hook 이 통과시킴" 안내
- **remote 있음**: 현재 브랜치를 그대로 origin 에 push
    - upstream 없으면 `git push -u origin <current-branch>` (첫 push)
    - upstream 있으면 `git push`
- `main` 브랜치로의 머지는 /ship 범위 밖 — 별도 워크플로우. /ship 은 "현재 브랜치 검증 + push" 까지만 책임.
- push 성공 시 PostToolUse hook 이 자동으로 gate.json 삭제

### 8. 최종 보고

- 각 단계 결과, push 결과(성공/실패), remote URL
- 실패한 단계가 있으면 사유와 후속 액션 정리

## 절대 규칙

- 한 단계라도 실패하면 더 진행하지 말고 사용자에게 보고
- 사용자 명시 큐사인 없이 절대 push 하지 않음 [[feedback-deploy-cue]]
- 검증 대상은 변경된 파일만. 프로젝트 전체 lint/review 돌리지 말 것
- 모든 sub-agent 위임에 **"commit/merge/push 금지, 변경만"** 명시
- prettier 자동 fix(`--write`) 금지
- reviewer (ts / swift) 응답 파싱은 마지막 비공백 줄 기준
