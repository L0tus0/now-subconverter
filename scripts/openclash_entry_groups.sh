#!/bin/sh
# 本地入口增强：双 DoH 对照；按出口地区和入口分组；组内 URLTest、组间 fallback。
# 默认同步节点解析到这两家 DoH，保留节点参数、应用 DNS 和分流规则。
# Ruby 先通过官方内核校验再原子写入；失败保留输入配置，不阻止 OpenClash 启动。
. /usr/share/openclash/log.sh

ENTRY_LOG_PREFIX='Custom Overwrite Scripts (entry grouping)'
ENTRY_LOG_DETAIL='/tmp/openclash-entry-grouping.log'
umask 077
LOG_OUT "$ENTRY_LOG_PREFIX 开始：本机双 DoH 核对入口，按出口地区 × 入口分组；组内自动测速、组间 fallback，并校验完整配置。"
ENTRY_LOG_RESULT=$(ruby /etc/openclash/custom/openclash_entry_groups.rb "$1" "${2:-/etc/openclash/custom/entry-groups.yaml}" 2>"$ENTRY_LOG_DETAIL")
ENTRY_LOG_STATUS=$?
case "$ENTRY_LOG_STATUS" in
  0) LOG_OUT "$ENTRY_LOG_PREFIX 完成：$ENTRY_LOG_RESULT" ;;
  3) LOG_OUT "$ENTRY_LOG_PREFIX $ENTRY_LOG_RESULT" ;;
  *)
    if [ -n "$ENTRY_LOG_RESULT" ]; then
      LOG_ERROR "$ENTRY_LOG_PREFIX $ENTRY_LOG_RESULT"
    else
      LOG_ERROR "$ENTRY_LOG_PREFIX 失败：脚本未正常完成（退出码 $ENTRY_LOG_STATUS），未确认增强成功。详情见 $ENTRY_LOG_DETAIL。"
    fi
    ;;
esac
# The caller can continue startup using the input config after an enhancement failure.
[ "$ENTRY_LOG_STATUS" -eq 3 ] && exit 0
exit "$ENTRY_LOG_STATUS"
