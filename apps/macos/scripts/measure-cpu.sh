#!/usr/bin/env bash
# Замер нагрузки на процессор запущенной Luna: среднее по `top` за минуту.
#
#   measure-cpu.sh [метка] [pid]
#
# pid по умолчанию — процесс `Luna`. Берёт 13 отсчётов через 5 секунд (около минуты),
# первый отсчёт `top` — среднее с момента запуска процесса — отбрасывает и печатает среднее
# остальных двенадцати. Если экран спит или заблокирован, кадры не просятся и цифра ложная:
# скрипт выходит с кодом 2, ничего не печатая о нагрузке.
#
# Условия честного замера (см. docs/AGENTS.md): релизный бандл, остров свёрнут (или скрыт для
# сценария «hidden»), курсор вне острова и вне полосы вокруг него, реальных сессий агентов нет.
set -euo pipefail

LABEL="${1:-sample}"
PID="${2:-$(pgrep -x Luna | head -1 || true)}"
SAMPLES="${LUNA_CPU_SAMPLES:-13}"
INTERVAL="${LUNA_CPU_INTERVAL:-5}"

if [ -z "$PID" ]; then
    echo "measure-cpu: процесс Luna не найден" >&2
    exit 1
fi

# Экран включён и разблокирован: CGDisplayIsAsleep и CGSSessionScreenIsLocked.
SCREEN="$(osascript -l JavaScript -e '
ObjC.import("CoreGraphics");
var asleep = $.CGDisplayIsAsleep($.CGMainDisplayID());
var locked = false;
try { locked = !!ObjC.deepUnwrap($.CGSessionCopyCurrentDictionary()).CGSSessionScreenIsLocked; } catch (e) {}
(asleep ? "asleep" : "awake") + " " + (locked ? "locked" : "unlocked");
')"
case "$SCREEN" in
    "awake unlocked") ;;
    *)
        echo "measure-cpu: экран не включён и не разблокирован ($SCREEN): замер не засчитывается" >&2
        exit 2
        ;;
esac

OUT="$(top -pid "$PID" -l "$SAMPLES" -s "$INTERVAL" -stats pid,cpu | awk -v pid="$PID" '$1 == pid { print $2 }')"
# Экран мог погаснуть посреди замера.
AFTER="$(osascript -l JavaScript -e 'ObjC.import("CoreGraphics"); $.CGDisplayIsAsleep($.CGMainDisplayID()) ? "asleep" : "awake"')"
if [ "$AFTER" != "awake" ]; then
    echo "measure-cpu: экран погас во время замера: не засчитывается" >&2
    exit 2
fi

printf '%s\n' "$OUT" | awk -v label="$LABEL" -v pid="$PID" '
    NR > 1 { sum += $1; n++; vals = vals (n > 1 ? " " : "") $1 }
    END {
        if (n == 0) { print "measure-cpu: нет отсчётов" > "/dev/stderr"; exit 1 }
        printf "%s pid=%s screen=awake/unlocked samples=%d avg=%.1f%% [%s]\n", label, pid, n, sum / n, vals
    }'
