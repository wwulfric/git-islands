# git-islands

[English](README.md) | 简体中文

为 Emacs 提供 IntelliJ 风格的 Git 工具窗口：界面在 Emacs 中绘制，Git 操作由
[Magit](https://magit.vc) 驱动。

- **Commit 工具窗口**：改动文件按 changelist 和文件夹分组。文件的复选框就是
  index，勾选即暂存。下方是提交信息，带有 Amend、Commit 和 Commit and Push。
- **Git log**：带提交图的提交列表，可按分支、作者、日期、路径和文本过滤，
  旁边有分支窗格和详情窗格。用 Shift 和 Cmd-点击选中多个提交，可以
  cherry-pick、revert 或对比。
- **分支弹窗**：checkout、新建分支、update、push、merge 和 rebase。
- **Diff 与合并**：左右对照的 diff，每处改动都能单独暂存或撤销；冲突用三栏合并解决。
- **Annotate**：在边栏显示 blame，并与 log 联动。

只有在第一次打开工具窗口，或执行会改动仓库的命令时，才会加载 Magit。

## 依赖

- Emacs 29.1 或更高版本，需支持 SVG（用于绘制提交图、复选框和选中行）
- Magit 4.7 或更高版本
- [expui-icons](https://github.com/wwulfric/expui-icons) 0.2 或更高版本

## 安装

仓库发布到上述地址后，可以用 `package-vc`（Emacs 29）安装：

```elisp
(package-vc-install "https://github.com/wwulfric/git-islands")
```

或者从本地 checkout 加载：

```elisp
(add-to-list 'load-path "/path/to/git-islands")
(require 'git-islands)
```

默认不绑定任何按键。可以单独绑定需要的命令，或把整个按键表挂在一个前缀下：

```elisp
(keymap-global-set "C-c g" git-islands-command-map)
;; 或者沿用 IntelliJ 的按键：
(keymap-global-set "s-0" #'git-islands-commit-toggle)
(keymap-global-set "s-9" #'git-islands-log-toggle)
(keymap-global-set "C-~" #'git-islands-branches-popup)
```

| 按键表中的键 | 命令 |
|---|---|
| `c` | `git-islands-commit-toggle`：Commit 工具窗口 |
| `k` | `git-islands-message-focus`：编写提交信息 |
| `l` | `git-islands-log-toggle`：Git log |
| `f` | `git-islands-log-file`：当前文件的历史 |
| `b` | `git-islands-branches-popup`：分支弹窗 |
| `a` | `git-islands-annotate`：annotate 当前文件 |
| `m` | `git-islands-conflicts`：解决合并冲突 |

## 融入你的配置

工具窗口从不直接调用你的配置。凡是属于编辑器本身的东西，都通过下面这些变量来询问；
它们的默认值在不加任何配置的 Emacs 里就能工作：

| 变量 | 决定什么 |
|---|---|
| `git-islands-mode-line-format` | 每个列表下方的 mode line |
| `git-islands-header-function` | 包装每个表头，比如加上圆角 |
| `git-islands-background-function` | 工具窗口的背景色 |
| `git-islands-with-anchor-function` | 过滤器的 minibuffer 弹窗从哪里弹出 |
| `git-islands-fallback-directory-function` | 不在任何仓库中时，对哪个项目操作 |
| `git-islands-side-window-width` | Commit 工具窗口的宽度 |
| `git-islands-side-window-hook` | Commit 工具窗口占据左侧之前运行 |

绘制用到的 face 有 `git-islands-ui-font`、`git-islands-title`、`git-islands-hl-line`
等，定义在 `git-islands-ui.el`；表示改动类型的颜色在 `git-islands-faces.el`。
可以直接设置 face 的 spec，也可以让它继承你自己的 face：

```elisp
(face-spec-set 'git-islands-hl-line '((t :inherit my-selection))
               'face-defface-spec)
```

仓库状态变化时，会以仓库根目录为参数运行 `git-islands-status-functions`。
`git-islands-status` 返回最新的状态快照，文件树或状态栏可以据此给文件着色、显示分支。

## 开发

```sh
make compile   # 字节编译，警告视为错误
make test      # 运行 ERT 测试
```

Makefile 在 `DEPS` 下查找依赖，每个依赖一个目录。默认在本 checkout 的同级目录中查找，
即作为子模块与 Magit、expui-icons 放在一起的情况。也可以指定其他位置，例如
`make test DEPS=~/.emacs.d/elpa`。

## 许可证

Apache License 2.0，见 [LICENSE](LICENSE)。
