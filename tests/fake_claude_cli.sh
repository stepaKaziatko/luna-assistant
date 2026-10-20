#!/bin/sh
# Поддельный `claude` для scripts/test-claude-cli.sh: записывает, что получил, и отвечает по сценарию.
#   FAKE_CLAUDE_MODE    stream (по умолчанию) | hang | silent | fail
#   FAKE_CLAUDE_FIXTURE построчно отдаётся в stdout в режимах stream и hang
#   FAKE_CLAUDE_*_FILE  куда писать аргументы, stdin, окружение, pid и рабочую папку (CWD)
#   `claude auth status`: печатает FAKE_CLAUDE_AUTH_JSON, код выхода FAKE_CLAUDE_AUTH_EXIT
if [ "$1" = "auth" ]; then
  [ -n "$FAKE_CLAUDE_AUTH_JSON" ] && cat "$FAKE_CLAUDE_AUTH_JSON"
  [ "$FAKE_CLAUDE_AUTH_MODE" = "hang" ] && exec sleep 30
  exit "${FAKE_CLAUDE_AUTH_EXIT:-0}"
fi
echo $$ > "$FAKE_CLAUDE_PID_FILE"
printf '%s\n' "$@" > "$FAKE_CLAUDE_ARGS_FILE"
env > "$FAKE_CLAUDE_ENV_FILE"
[ -n "$FAKE_CLAUDE_CWD_FILE" ] && pwd -P > "$FAKE_CLAUDE_CWD_FILE"
cat > "$FAKE_CLAUDE_STDIN_FILE"
case "${FAKE_CLAUDE_MODE:-stream}" in
  stream)
    while IFS= read -r line; do printf '%s\n' "$line"; sleep 0.05; done < "$FAKE_CLAUDE_FIXTURE"
    ;;
  hang)
    head -n 1 "$FAKE_CLAUDE_FIXTURE"
    exec sleep 30
    ;;
  silent)
    exec sleep 30
    ;;
  fail)
    i=0
    while [ $i -lt 60 ]; do printf 'boom boom boom\n' >&2; i=$((i+1)); done
    printf 'the real reason\n' >&2
    exit 3
    ;;
esac
