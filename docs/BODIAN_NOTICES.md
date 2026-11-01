# 第三方来源

无第三方运行时依赖。参考仓库存放在忽略的 work/。

## SMCKit / bclm

`Sources/SMCReadOnly/SMCReadOnly.c` 的 SMC 数据布局和调用模式参考并改编自 SMCKit：Copyright (C) 2014–2017 beltex，MIT 许可。完整许可见 [SMCKit MIT](LICENSES/SMCKit-MIT.txt)。

读取来源：https://github.com/zackelia/bclm/blob/ae2c209614755d81bf5b788513dba1d44280a6f6/Sources/bclm/SMC.swift 。本地参考仓库提交固定为 `ae2c209614755d81bf5b788513dba1d44280a6f6`。仅改编协议结构和读取调用，没有纳入风扇或其他写入功能。

batt 仅用于公开行为与问题记录研究，没有复制其 GPL 代码。

## Ampere 原生充电策略实验

`Experiments/native-hold.m` 的 PowerUI 偏好域、通知、动态客户端声明和恢复顺序参考并改编自 az-code-lab/ampere，固定提交 `843498d7beb711c0e1b18e48c8520debe67f6e3f`，Copyright (c) 2026 AZ Code Lab。完整 MIT 许可见 [Ampere MIT](LICENSES/Ampere-MIT.txt)。未纳入其 UI、sudoers 安装器、SMC 写入或防睡眠机制。

独立策略 archive 参考 PR：https://github.com/actuallymentor/battery/pull/479 ，提交 `2124764eef17aaba4b0f1ea97969d79185609029`。

`Experiments/native-policy.h`、`Experiments/test-native-policy.m` 及 native-hold.m 中 archive 读写和 powerd 重载部分改编自该提交的 MIT 原生补丁，归属 Battery macOS 27 compatibility patch contributors。完整许可见 [Native Policy MIT](LICENSES/NativePolicy-MIT.txt)。策略 reason 改为本项目独有的 `com.bodian.G0`，仅用于限时实验，没有执行上游安装程序或安装其服务。

## 原生控制运行时

`Sources/ChargeRuntime/NativeBackend.m` 中的原生策略机制与 PowerUI 恢复顺序，及 `Sources/ChargeRuntime/native-policy.h` 的有界 archive 解析和 token 隔离逻辑，分别改编自以上 Ampere 与 Battery macOS 27 MIT 代码，沿用同一固定提交和完整许可证。运行时策略 reason 为 `com.bodian.charge`。后台通信、签名哈希授权、纯策略规则、菜单栏界面和生命周期代码由本项目实现。
