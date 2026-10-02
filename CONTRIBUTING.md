# 参与贡献

谢谢你愿意给 Kiki 出力。动手之前请先读一遍 [AGENTS.md](AGENTS.md)——它是这个仓库唯一的事实来源：架构、每个文件干什么、以及「Rules That Bite If Broken」里那些踩了会疼的坑。不看那些坑就改代码，最先踩上的往往就是它们。

## 环境

- macOS 14.2+，Xcode 26+（工程按 Xcode 26 的 Swift 并发默认隔离写就，Xcode 16 的编译器构建不过）
- 一个 DeepSeek API Key，只在自测时需要；仓库里没有任何密钥，key 只进你本机的钥匙串

## 构建与运行

一条命令同时构建 `Kiki.app` 和命令行工具 `kiki`，命令在 [README](README.md) 里，这里不抄第二份。两个注意点：

- **用 `open` 启动 app，别从终端直接跑二进制。** 屏幕录制权限会被 macOS 算到终端头上，面板里怎么授权都不对；从终端构建没有问题。
- README 的构建命令用 ad-hoc 签名（`CODE_SIGN_IDENTITY="-"`），谁都能跑；代价是每次重新构建都要重新授权五项权限。想授权跨构建保留，在「钥匙串访问 → 证书助理」里给自己创建一个代码签名证书，把命令里的 `-` 换成证书的名字。

## 改动规矩

- **不做没被要求的事。** 不顺手重构，不给没改到的文件补注释，不修 [AGENTS.md](AGENTS.md) 点名不修的警告。
- **命名、注释、文案有明确规矩**，见 [AGENTS.md](AGENTS.md) 的 Code Style 一节：名字宁长勿短，注释解释为什么，用户读到、听到的都是简体中文，日志行不带 emoji。
- **改了行为，就同步 AGENTS.md。** 新文件进 Key Files 表，新坑进 Rules That Bite If Broken，行数变化超过 50 行更新近似值——AGENTS.md 自己的 Self-Update Instructions 一节列了完整条目。
- **`scripts/` 里的三个探针复制了 app 的提示词、解析器和事件形状**，改到对应源码时要把探针同步回去，否则它量测的是一条 app 已经没有的流水线。

## 提交

- 提交信息用祈使句，解释为什么而不是复述做了什么，英文。
- 分支命名 `feature/描述` 或 `fix/描述`。
- 大改动先开 issue 说清楚再动手。
- PR 按 [.github/PULL_REQUEST_TEMPLATE.md](.github/PULL_REQUEST_TEMPLATE.md) 的自查清单过一遍，CI 绿。这个项目的很多问题只有驱动真的 app 才会暴露——权限、TCC、事件注入都是——所以「真实验证过」指的是跑起来的 app，不只是编译通过。
- 发版是维护者的事：一个版本的完整流程和一次性仓库设置见 [RELEASING.md](RELEASING.md)。
