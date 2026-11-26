# mac-hotkeys

在 macOS 终端里，把全局快捷键、对应软件和动作导出为 Markdown。软件归属来自可读配置，注册冲突本身无法确定接收按键的进程。

## 安装或更新

在终端复制这一行即可下载并安装最新发布版到 `~/.local/bin`。Apple Silicon 支持 macOS 12 及以上，Intel 支持 macOS 13 及以上。无需 Xcode 或 sudo。

```sh
(installer=$(curl -fsSL https://raw.githubusercontent.com/DayuGuo/mac-hotkeys/main/install-online.sh) && /bin/bash -c "$installer")
```

## 使用

```sh
mac-hotkeys                          # 在当前目录生成 mac-hotkeys.md
mac-hotkeys export ~/Desktop/快捷键.md  # 指定报告位置
mac-hotkeys apps                     # 列出已安装的应用，方便核对遗漏
```

如果终端找不到命令，可直接运行 `~/.local/bin/mac-hotkeys`。更多选项见 `mac-hotkeys --help`。

新增应用支持或发布版本，请参见[协作说明](CONTRIBUTING.md)。
