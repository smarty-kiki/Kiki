# 发版

维护者发一个版本的完整流程。workflow 能自动核对的都写进了 [`.github/workflows/release.yml`](.github/workflows/release.yml)，这里写人要做的部分。

## 版本号规则

语义化版本 `X.Y.Z`（预发布加后缀，如 `1.1.0-rc.1`），Git 标签写 `vX.Y.Z`。

同一个版本号写在三个地方，release workflow 打包前逐一核对，对不上就直接失败：

| 写在哪 | 写成什么 |
|---|---|
| Git 标签 | `v1.0.0` |
| app target 的 `MARKETING_VERSION`（Debug、Release 两处，Xcode 里对应 target 的 Version） | `1.0.0` |
| `CHANGELOG.md` 的版本标题 | `## [1.0.0] - 2026-10-02` |

带 `-` 的版本号（如 `1.1.0-rc.1`）会发成 pre-release。

## 发一个版本

1. **改 CHANGELOG。** 把 `[Unreleased]` 下攒的条目移进新的 `## [X.Y.Z] - 日期` 一节，`[Unreleased]` 留空。这一节会原样变成 Release 说明。
2. **改版本号。** pbxproj 里 app target 的 `MARKETING_VERSION` 两处（Debug、Release）都改成 `X.Y.Z`。
3. **合进 main。** 走 PR，CI 绿。
4. **打 tag 推送。** `git tag -a vX.Y.Z -m "Kiki X.Y.Z" && git push origin vX.Y.Z`。
5. **等草稿。** workflow 构建、核对三个版本号、打包、附来源证明、建一个**草稿** Release。绿了去 Releases 页面看草稿：附件（dmg、zip、SHA256SUMS）、说明里的 CHANGELOG 一节、安装步骤都在。
6. **亲手验一遍。** 下载草稿附件，照说明装一遍：dmg 拖进「应用程序」（或 zip 解压），去隔离、`open`、给五项权限、按住 Control+Option 问一句。命令行也要过一遍：面板「命令行」卡片上点「安装命令行工具」，输密码过一次系统授权，那行应变成绿色的「已装好」；再随便跑一条 `kiki` 命令，看它能不能找到并连上 app。最好装在一台没构建过这个项目的机器上。
7. **发布。** 在 GitHub 上把草稿点成公开。

## 发错了怎么办

- **草稿阶段**：改代码、删掉本地和远端的 tag（`git push origin :vX.Y.Z`），重新打。公开之前没有代价。重推同一个 tag 时 workflow 会先删掉同名旧草稿再建新的；已发布的 Release 它不碰，遇到就报错停下。
- **已发布**：不重打同一个 tag，不换已发布的附件——下载过的人核对不上。发一个补丁版本，在 CHANGELOG 里写清楚修了什么。

## 一次性仓库设置（GitHub 网页侧）

仓库文件管不到这些，建仓库时做一遍：

- **main 分支保护**：必须走 PR、CI 必须绿、禁止 force push 和删除。
- **tag 保护**：`v*` 只允许维护者创建。
- **Release immutability**：已发布的 Release 不允许再改附件。
- **私密漏洞报告**（Settings → Security）：打开——[SECURITY.md](SECURITY.md) 指的就是这个入口。
- **Actions 权限**（Settings → Actions → General）：默认 `Read repository contents` 即可；release workflow 自己声明了需要的写权限，不受影响。
- **仓库简介和 topics**：建议 `macos`、`swift`、`swiftui`、`menu-bar`、`macos-app`、`ai-agent`、`deepseek`。

## 来源证明

release workflow 给 dmg 和 zip 都附 GitHub 来源证明（`actions/attest`），说明里带核对命令，每个附件都可以单独核：

```bash
gh attestation verify Kiki-X.Y.Z.dmg --repo smarty-kiki/Kiki
```

这一条只在**公开仓库**有效；私有仓库要 GitHub Enterprise Cloud 才能生成证明，跑不到就删掉 workflow 里那一步。
