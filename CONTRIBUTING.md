# 协作

每个改动开一个短期分支，两人都从最新的 `main` 开始。例如，为某款应用补充快捷键读取时，可以这样创建分支：

```sh
git switch main
git pull --ff-only
git switch -c feature/app-shortcuts
```

提交后运行 `git push -u origin HEAD`，向 `main` 开 pull request。两人同时改同一处时，先在自己的分支运行 `git fetch origin` 和 `git merge origin/main`，解决冲突后重新测试并推送。由另一人复核交叠的改动，再合并 PR。

## 新增应用支持

用 `mac-hotkeys apps` 找到应用的 Bundle ID，然后核实哪个设置保存全局快捷键、它如何表示已启用、停用和未配置。PR 写明应用版本、数据格式和验证方法，示例使用虚构的键位和动作名。完整应用清单和个人快捷键报告留在本机。

在临时目录编译并对比结果：

```sh
build_dir=$(mktemp -d)
./install.sh "$build_dir"
"$build_dir/mac-hotkeys" list --json
"$build_dir/mac-hotkeys" export "$build_dir/report.md" --no-probe
```

## 发布

合并后由一人负责发版。同步 `main`，确认 `mac-hotkeys --version` 对应的新版本已提交，从该提交运行 `./scripts/package.sh`。把同一提交标记为 `vX.Y.Z` 并推送标签，在 GitHub Release 附上 `dist/mac-hotkeys-arm64.zip` 与 `dist/mac-hotkeys-x86_64.zip`，再发布为最新版本。README 的安装命令会自动选择对应的包。

修改主动扫描或规则解码时，运行 `./scripts/test-discovery.sh`。这组回归使用虚构配置和事件样本，验证候选排除、观察证据、基线和扫描轮换。涉及系统投递的变更需要用独立、无动作的接收器对照，分别记录是否收到热键回调以及扫描器实际看到的事件。
