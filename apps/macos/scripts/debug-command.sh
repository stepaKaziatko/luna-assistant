#!/bin/sh
# Отправляет команду запущенной debug-сборке Luna (см. Sources/Luna/Debug/DebugCommands.swift).
# Примеры: debug-command.sh toggleInput
#          debug-command.sh "submit:что такое JSON-RPC?"
#          debug-command.sh "dump:/tmp/luna-state.json"
set -eu
LUNA_COMMAND="$1" exec osascript -l JavaScript -e '
ObjC.import("Foundation");
const command = $.NSProcessInfo.processInfo.environment.objectForKey("LUNA_COMMAND");
$.NSDistributedNotificationCenter.defaultCenter
  .postNotificationNameObjectUserInfoDeliverImmediately("dev.luna.debug", command, $(), true);
'
