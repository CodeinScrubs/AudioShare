# AudioShare USB 自定义版

本分支专注于一个产品场景：通过 USB ADB，把 **Windows 的全部普通系统音频**
传输到 Android 手机扬声器。macOS、Wi-Fi 传输和按进程选择音频不属于本分支的
产品范围。

## 工作方式

```text
Windows 应用与系统声音
        -> 全局进程回环捕获（首选）
        -> 默认输出设备回环（兼容回退）
        -> 48 kHz / 双声道 / PCM16
        -> 仅连接 127.0.0.1 的 Windows 客户端
        -> USB ADB forward
        -> Android 配套应用 LocalServerSocket
        -> AudioTrack
        -> 手机扬声器
```

在 Windows 支持时，主机使用端点无关的 Application Process Loopback，并排除
AudioShare 自己的进程树。因此不需要选择 `idplayer.exe`，Chrome、VLC、系统提示音
以及其他普通共享模式音频都会被包含。若功能探测失败，程序会明确切换到“默认输出
兼容模式”；该模式目前无法保证捕获被手动路由到其他输出设备的应用。

Windows 主程序不创建入站音频监听端口。Android 主 APK 不申请 `INTERNET`、
麦克风、相机、位置或存储权限。正常运行不需要管理员权限、Windows 服务、虚拟声卡、
防火墙规则、Wi-Fi 或互联网。

## 首次使用

1. 完整解压 Windows 包。
2. 在手机上开启开发者选项和 USB 调试。
3. 使用支持数据传输的 USB 线连接手机。
4. 解锁手机并允许此电脑进行 USB 调试。
5. 启动 AudioShare；如有提示，点击“安装配套应用”。
6. 首次连接并确认 Windows 系统声音能从手机播放。

Windows 必须已经能识别手机的 ADB USB 接口。缺失的厂商 USB 驱动可能需要管理员
安装；AudioShare 不会提权或绕过组织安全策略。

## 当前验证边界

已完成：Flutter 静态分析与单元测试、Windows 原生严格编译、全局捕获与默认输出
回退的本地假接收端集成测试、Android 单元测试/检查/构建及权限清单检查。

仍需真机：USB forward、Android 自动启动、锁屏/息屏播放、手机扬声器路由、防火墙
提示、端到端延迟、反复重连和长时间漂移测试。

详细信息请查看：

- [架构](COMPANION_ARCHITECTURE.md)
- [POC 结果](POC_RESULTS.md)
- [手动测试计划](MY_TEST_PLAN.md)
- [故障排查](TROUBLESHOOTING.md)

许可证为 [LGPL-3.0-or-later](../LICENSE)。
