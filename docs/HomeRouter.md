# HomeRouter 本地入口分组与自动容灾

在线订阅转换必须独立输出可运行的完整 YAML；本地入口聚合只是可选增强。转换服务不根据自身 ISP 解析结果替客户端划分入口，也不替换节点服务器域名。

基础路径为 `🚀 节点选择 → ♻️ 自动容灾 → 🧩 入口候选（URLTest）→ 实际节点`。应用分流、专用组和规则在基础配置中已完整存在；没有脚本或增强失败时仍可加载使用。配置可加载不代表机场线路一定可达。

## 本地增强后的结构

```text
应用分流 → 🚀 节点选择 → ♻️ 自动容灾（fallback，按以下顺序）
                          ├─ 香港入口 A（url-test）→ 节点
                          ├─ 香港入口 B（url-test）→ 节点
                          ├─ 香港入口 C（url-test）→ 节点
                          ├─ 台湾入口 A（url-test）→ 节点
                          └─ 新加坡入口 D（url-test）→ 节点
```

按“出口地区 × 已确认入口地址集合”分组。同一个入口 IP 上的香港、台湾节点分别成组；同地区共入口节点继续组内自动测速。地区从节点名称/旗帜识别，不把入口 IP 所在地当作出口地区。未识别的地区排在已配置地区之后。

默认顺序为香港、台湾、新加坡、日本、美国等。同地区的全部入口排在下一地区之前，避免香港 1 → 台湾 1 → 香港 2。地区内按成员域名排序，不硬编码机场 IP，也不因 IP 数字变化直接重排优先级；成员关系变化仍可能影响排序。地址显示在组名中，因此 IP 改变时组名可能改变。

各入口为 URLTest：主动检测间隔 60 秒、超时 3000 ms、容差 150 ms。外层为 fallback，按顺序选择可用入口组。各层关闭 `interrupt-existing-connections`，避免策略切换主动清理既有连接；这不能挽救已断开的连接。

## DNS 与分组证据

查询全部由运行客户端的路由器发出。`local_entry_dns.rb` 通过两个独立 HTTPS DNS 服务查询完整 A 记录集合；使用 IP 字面量 URL、验证 TLS 证书，不依赖 ISP DNS 解析 DoH 服务域名。默认服务为阿里 DNS 与腾讯 DNSPod。

- 两个 DoH 返回的非空公网 IPv4 集合完全一致，才视为该域名的已确认地址集合。
- 同地区的不同域名，只有已确认集合完全相同才合并。仅部分交集不合并，也不做传递交集合并。
- 结果冲突或其中一家查询失败时，保留“地区 × 原域名”的独立组，标记未确认；不把未知域名集中成一个故障域。
- 本地运营商 DNS 参与对照和记录，但不参与多数投票。差异只能提示需要调查，不能单凭差异认定污染。
- 默认把 Mihomo 的 `dns.proxy-server-nameserver` 改为同样的两个 DoH。原始节点域名、TLS/SNI 参数不变，应用域名的 DNS 策略不变。已有非空 `proxy-server-nameserver-policy` 时拒绝覆盖并保留基础配置。
- 若任一候选域名在两家 DoH 均没有有效结果，本轮放弃增强并保留原 YAML，避免直接安装无法解析该节点的 DNS 设置。

这使分组与实际节点解析使用相同来源，但不同时间、缓存、GeoDNS 调度仍可能产生不同结果；两个公共 DNS 也不保证给出最快线路。共享 IP 仅是共享入口的证据，不证明上游物理线路独立；不同 IP 也可能共用中转。

## OpenClash 安装

依赖路由器 Ruby、YAML、curl（支持 HTTPS 和 CA 校验）、nslookup 及官方 Mihomo 内核。不需要 Ruby json/socket 扩展。

1. 将 `scripts/openclash_entry_groups.rb` 和 `scripts/local_entry_dns.rb` 一起保存到 `/etc/openclash/custom/`。
2. 在现有 `/etc/openclash/custom/openclash_custom_overwrite.sh` 的 `exit 0` 前加入调用，保留已有覆盖逻辑；如果已有 DNS 覆盖脚本，应在其后调用：

   ```sh
   ruby /etc/openclash/custom/openclash_entry_groups.rb "$CONFIG_FILE" || LOG_OUT "Error: ingress grouping failed; original YAML retained"
   ```

3. 创建 `/etc/openclash/custom/entry-groups.yaml`：

   ```yaml
   core_gid: 65534
   doh:
     - https://223.5.5.5/dns-query
     - https://1.12.12.12/dns-query
   diagnostic_dns: 223.5.5.5
   resolution_budget: 25
   harden_node_dns: true
   region_order: [香港, 台湾, 新加坡, 日本, 美国, 韩国, 加拿大, 英国, 德国, 法国, 荷兰, 土耳其, 澳大利亚, 印度]
   report_path: /etc/openclash/custom/entry-groups-report.yaml
   ```

   `diagnostic_dns` 可改为当地运营商 DNS；它只用于对照。查询进程使用 `core_gid` 绕过 OpenClash 本机 DNS 重定向，部署时必须核对当地防火墙和内核运行 GID。DoH 端点应先在本机验证可直连且证书有效。查询使用 12 个工作线程，总预算 25 秒，正在执行的子查询最多再占约 4 秒。

   可选 `core` 默认 `/etc/openclash/clash`，`core_home` 默认 `/etc/openclash`。诊断报告含节点域名及解析证据，权限为 0600，请勿公开上传。

4. 使用 `config/HomeRouter.ini` 更新订阅并完整重新生成配置。主组选择 `♻️ 自动容灾` 一次，此后不用手选节点。检查运行配置和 API，外层应引用 `🧩 香港入口 …` 等 URLTest 组。

脚本先在内存生成候选，再由官方内核 `-t` 验证完整配置，成功后才原子替换目标 YAML。解析、分组或校验失败均不改动输入文件；钩子继续使用生成到当前阶段的可运行基础配置。若手动处理已增强文件，因已无候选池标记而直接返回，避免重复增强。

订阅更新/配置重生成会重新运行脚本；OpenClash 快速启动复用旧运行配置时不会重新查询。需要强制生成时，可在备份后移除 `/tmp/openclash.change` 再重启 OpenClash。部署前保存旧脚本、设置和钩子；回滚时恢复这些文件并重新生成配置。

## 保留与限制

- 原始节点连接参数、规则顺序、AI/ChatBot、巴哈姆特台湾组、土耳其商店等专用分流保持不变；增强只作用于普通自动代理路径。
- 地区测速组仍保留。已经单独选定地区/节点的应用组不一定跟随主组。
- Smart 自动转换应关闭；脚本不修改 Mihomo 二进制，普通内核更新无需重打补丁。固件升级/重置前仍需备份自定义目录。
- 当前实现针对 IPv4；全局 IPv6 开启时拒绝增强并保留原 YAML。没有候选时使用 REJECT，不回落 DIRECT。
- DNS 不是持续探测，入口地址在配置重生成时重算。故障切换由运行中的内核健康检测负责；60 秒检测间隔不是每次业务失败的恢复时限。
- fallback 不保证重试当前请求、不迁移 TCP 连接，也不会按历史失败率隔离入口。健康 URL 成功不保证视频或所有网站可用。
- 本仓库提供 OpenClash 适配。Clash Verge Rev 需另做本地执行与配置提交适配，不能直接照搬 root/GID/OpenClash 路径。

## 验证

`ruby scripts/test_entry_groups.rb` 覆盖地区连续排序、共享入口跨地区拆分、完整集合合并、未知域名隔离、DNS 协议校验、FakeIP 排除、配置保留和原子发布失败回退。部署还需验证：

1. 未增强订阅的组引用完整，并通过官方内核完整校验。
2. 实际生成配置的节点、规则、应用 DNS 与部署前相同，仅自动组和节点 DNS 有预期变化。
3. 运行 API 确认入口组为 URLTest、外层为 Fallback、没有 Smart/手动固定节点。
4. 经实际路由路径访问业务；短时 HTTP 成功不等同于视频播放或长期稳定性保证。

嵌套策略曾在隔离官方内核上通过可控代理验证组内选优、单节点失败接替、入口失败跨组回退和恢复回归；生产环境不主动制造断网。
