---
description: deploy-gate hook 을 우회할 수 있도록 bypass 상태를 기록 (긴급 핫픽스 전용)
argument-hint: <reason>
---

긴급 prod 핫픽스 등 정식 `/ship` 검증을 거칠 시간이 없을 때만 사용하는 escape hatch.

## 진행 순서

1. `$ARGUMENTS` 파싱:
    - 전체를 한 줄짜리 `reason` 으로 사용 (큰따옴표 안 포함)
    - 비어 있으면 즉시 사용법 안내 후 종료

2. 사용자에게 다음 정보 확인 후 OK 받기:
    - 어떤 사유로 우회하는지
    - "이건 escape hatch 입니다. 가급적 /ship 으로 정식 검증을 거치세요" 경고

3. 상태 파일 기록:
    - `.claude/state/gate.json` 에 작성 (디렉토리 없으면 mkdir -p):
        ```json
        {
            "bypass": true,
            "bypassReason": "<reason>",
            "bypassAt": "<ISO timestamp>",
            "bypassedBy": "user"
        }
        ```

4. 메모리에 이력 기록:
    - `/Users/macbookpro/.claude/projects/-Users-macbookpro-Documents-workspace-claude-token-visualizer/memory/bypass-log.md` 에 한 줄 append:
        ```
        - <ISO> | <reason>
        ```
    - 파일 없으면 새로 생성하고 MEMORY.md 에 인덱스 추가

5. 사용자에게 안내:
    - "bypass 적용됨. 이제 `git push` 가능."
    - "push 성공 후 gate.json 은 자동 삭제됨 (PostToolUse hook). 다음 변경부터 다시 정식 검증 강제."
    - "이 bypass 가 무엇이었는지 회고 권장."

## 절대 규칙

- bypass 는 1회용. push 후 자동 삭제됨.
- 사용자 OK 없이 bypass 기록하지 말 것.
- bypass 후에도 push 자체는 사용자가 명시 큐사인 해야 진행.
