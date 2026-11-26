# mac-hotkeys

在 macOS 终端里，把全局快捷键、对应软件和动作导出为 Markdown。软件归属来自可读配置；注册冲突本身无法确定接收按键的进程。

## 安装

Apple Silicon 用户可[下载安装包](https://github.com/DayuGuo/mac-hotkeys/releases/latest/download/mac-hotkeys-arm64.zip)，解压后在该目录运行：

```sh
./install.sh
```

Intel Mac 可在安装 Apple 命令行开发工具后，克隆本仓库并运行同一脚本。最低构建目标为 macOS 12。

## 使用

```sh
mac-hotkeys                         # 在当前目录生成 mac-hotkeys.md
mac-hotkeys export ~/Desktop/快捷键.md  # 保存到指定位置
```

如果终端找不到命令，可直接运行 `~/.local/bin/mac-hotkeys`。更多选项见 `mac-hotkeys --help`。
