# zorn 实机验证通过

后续应用修复：Manager 1.0.1 已修复下面记录的旧客户端问题并在实机连接成功；
Zygisk Next 也已恢复并验证 zygote 注入。详见 `manager-zygisk-repair.md`。

修复后的 KernelPatch small-model 内核已完成实机开机及 KPM 功能验证。
只向 `boot_a` 写入镜像；没有手工修改其他分区。
当前保留已通过验证的内核，不回滚。

## 环境与镜像

- 设备：`zorn`，运行系统报告 Android 17 / `OS4.0.0.13.XOKCNXM`。
- 内核：`6.1.176-android14-11-g0b76321acf29-dirty-ab14529422-nbkernel`。
- KernelPatch：`0.13.9`，使用 small code model 并保留 Android 宏。
- 槽位：`_a`；只写入 `boot_a`，写后回读哈希一致。
- `boot.img` SHA256：`98a3636a69015c688b74ddd92fe40d5fd0abeabdf2d69416f39525f71ef5736a`。
- Image SHA256：`9fe4f75a96f0a17fde046ac1c45f3d718bcf4d24ba805c67a1760a90c16605ec`。
- AnyKernel3 包 SHA256：`13444152dee432665a86325988924d7de4131db5ecaf6e51a43f19015f3e61b5`。

实际刷入的是将包内 Image.gz 放回当前设备 boot 封装后的镜像。
zip 内容和 boot 内的内核都已与上述 Image 哈希比对。
未使用 AnyKernel3 安装器执行刷入，因此本次不等同于验证了安装器的全部执行路径。

## 验证结果

| 检查 | 实测结果 |
| --- | --- |
| Android 完成启动 | `sys.boot_completed=1`；发现 ADB 时内核 uptime 约91秒 |
| 实际启动镜像 | 运行中读取 `boot_a`，哈希与目标一致 |
| 原有 root | `su -c id` 成功，仍为 `u:r:ksu:s0` |
| KPM 通道 | `OK hello kp=3337`，版本 `0.13.9` |
| 加载示例模块 | `OK load`，模块计数从0变为1 |
| 列表和信息 | 列表出现 `kpm-nbdemo`，信息为版本 `1.0.0` |
| 控制请求 | 返回 `echo: device-smoke` |
| 卸载模块 | `OK unload`，计数从1恢复0 |
| 命名空间 | MNT、UTS、IPC、PID、NET 的 `unshare()` 成功 |
| 文件系统支持 | `/proc/filesystems` 列出 cgroup2、devtmpfs、overlay |
| SELinux | 验证后仍为 `Enforcing` |

完整记录：`device-boot-result.json`、`device-kpm-verification.json`。
测试代码为 `scripts/verify-device-kpm.py`；superkey 从 stdin 传入并在输出中脱敏。
namespace 探针只改变自身进程的命名空间；没有挂载或修改其他设备分区。
所有工具均放在 `/dev` tmpfs，验证后已清理。示例 KPM 已卸载。

这验证了容器所需的内核原语；未运行完整 Droidspaces 用户态发行版、Docker 工作负载，
也未做 GPU、相机、网络吞吐或长时间稳定性测试。

## 管理器客户端的独立问题

APK 自带 `libkpctl.so` 提取后运行，被当前 ROM 的静态 Bionic 启动代码拒绝：

```text
executable's TLS segment is underaligned: alignment is 8 (skew 0),
needs to be at least 64 for ARM64 Bionic
```

该错误发生在用户态客户端初始化阶段，尚未发出 KPM syscall。
本轮改用独立的静态客户端后，全部 KPM 请求成功。
因此可确认内核 KPM 能力正常；现有管理器 APK 仍需单独修复客户端兼容性。
本轮未安装或改写管理器 APP。

## 回滚材料

试刷前从当前实际可启动系统重新备份：
`artifacts/device-backup/boot_a-working-baseline.img`。
SHA256：`e3774043f0e8cb914653f44b05b63ca10acad6250eb668431aa5217657f1aec1`。
它与早先的 `boot_a-before-kpm.img` 是不同文件；后续回滚应优先使用这份已确认可启动的基线。
所有设备分区备份均由 `.gitignore` 排除，未发布。
