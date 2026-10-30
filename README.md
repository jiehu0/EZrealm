# EZrealm

Realm 转发规则管理脚本。本 Fork：https://github.com/jiehu0/EZrealm

## 安装和运行

在使用 systemd 的 Linux 服务器上以 root 身份运行。脚本会补装缺少的 `curl` 和 `lsof`（支持 apt/yum）。下载并运行脚本：

```bash
wget -N https://raw.githubusercontent.com/jiehu0/EZrealm/main/realm.sh && chmod +x realm.sh && ./realm.sh
```

国内网络入口：

```bash
wget -N https://ghfast.top/https://raw.githubusercontent.com/jiehu0/EZrealm/main/CN/realm.sh && chmod +x realm.sh && ./realm.sh
```

之后运行 `./realm.sh` 即可。脚本更新、版本检查及旧版脚本下载均指向本 Fork。国内入口更新时继续使用 `CN/realm.sh`。

Realm 内核的版本检查和下载来自其官方发布仓库 `zhboner/realm`，本仓库不提供内核二进制。

## 编辑规则（v1.2.0）

选择菜单 **11. 编辑转发规则**，输入规则序号后修改监听地址、监听端口、目标地址、目标端口及备注。

- 回车保留当前值，输入 `q` 取消，备注输入 `-` 清空。
- 地址和端口分开输入；IPv6 地址可带或不带方括号，目标地址支持域名。
- 检查端口范围（1–65535）、地址格式及明显的监听冲突；最终能否绑定由 Realm 启动结果决定。
- 保存前显示修改内容并要求确认；无变化时不写文件、不重启。
- 查看、编辑、删除按 `[[endpoints]]` 规则块读取，不依赖字段顺序；编辑保留其他字段、嵌套配置、注释及未选中的规则。
- 支持脚本生成的单行地址字符串；无法识别、缺失或重复的地址字段会拒绝编辑。
- 添加、编辑、删除均先备份 `/root/realm/config.toml`（文件名为 `config.toml.bak.*`），通过临时文件原子替换，并保留文件权限和归属。
- 服务重启失败或未处于 active 状态时恢复原配置，再尝试恢复服务；恢复失败时显示备份位置。
- 重启后按有效 TCP/UDP 配置检查端口是否由 Realm 主进程持有，避免单条规则绑定失败但进程仍存活时误报成功。删除最后一条规则时停止服务。
- 操作期间检测到外部配置变更时拒绝覆盖。

保存会重启整个 Realm 服务，现有连接可能中断。原有菜单编号保持不变。

## 测试

测试需要 Bash、awk 和 Python 3.11+，不需要 root 或 systemd；使用临时配置及模拟服务命令：

```bash
python3 -m unittest discover -s tests -v
```

安装 `lsof` 后，可使用真实 Realm 内核执行本地 TCP 转发集成测试（进程和配置均在临时目录中）：

```bash
REALM_BINARY=/absolute/path/to/realm python3 -m unittest discover -s tests -p 'integration_*.py' -v
```

GitHub Actions 还会在 Ubuntu 上创建临时 systemd 服务，验证真实服务重启、监听端口、IPv4/IPv6 转发及端口冲突回滚。手动运行该模式时，在上述命令前增加 `REALM_TEST_SYSTEMD=1`，需要可免密执行 sudo；不会使用服务器已有的 `realm.service`。

## 来源

本项目由 EZrealm Fork 修改，历史脚本最初来源于 Jaydooooooo/Port-forwarding。
