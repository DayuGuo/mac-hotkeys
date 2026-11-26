# mac-hotkeys

在终端发现之前漏掉的 macOS 全局快捷键。工具从已安装应用的配置和宏规则中读取键位、动作和来源，导出 Markdown，并单列本次新发现。

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

默认仅读取配置，包含未运行应用的已保存键位。首次运行建立本机快照，以后自动比较。已有旧报告时可运行 `mac-hotkeys export --baseline 旧清单.md`。

### 可选的主动扫描

```sh
mac-hotkeys scan --dry-run          # 预览清单外的候选组合
mac-hotkeys scan --self-test        # 核对权限和按键拦截
mac-hotkeys scan --limit 8          # 发送最多 8 个组合，把观察写进新报告
```

主动扫描可能触发其他软件的全局动作。工具会跳过高风险键，要求辅助功能及事件权限，并在每次开始发候选键前验证拦截。[扫描范围和结果解读](docs/scanning.md)

如果终端找不到命令，可直接运行 `~/.local/bin/mac-hotkeys`。更多选项见 `mac-hotkeys --help`。

新增应用支持或发布版本，请参见[协作说明](CONTRIBUTING.md)。
