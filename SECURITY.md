# 安全政策

## 报告漏洞

**请勿用公开 issue 报告安全漏洞。** 用 GitHub 的私密漏洞报告：仓库页 **Security → Advisories → Report a vulnerability**。讨论全程在 advisory 的私密会话里进行，确认修复并发布后再公开。

## 值得报告什么

Kiki 是一个会替用户动手的 app：读每一块屏幕、注入鼠标和键盘事件、把截图发给用户自己配置的 DeepSeek。它的攻击面包括但不限于：

- **凭据的存取路径。** DeepSeek key 只应存在于 macOS 钥匙串——任何把它写进日志、剪贴板、文件或发往 DeepSeek 之外的地方的路径都是漏洞。
- **本地命令套接字。** `~/Library/Application Support/Kiki/command.sock` 是一个本地 Unix 域套接字，本机进程都能连上并让 Kiki 点击、滚动、打字。任何削弱它的访问边界、或让它被未授权调用方驱动的路径值得报告。
- **权限边界。** 在权限缺失、「允许 Kiki 用鼠标操作 / 键盘操作」关闭、危险词拦截（删除、卸载、格式化……）这三层之外出现的任何事件注入路径。
- **录制与重放。** shift+option 录下的用户动作被第三方读取或改写的可能。

## 不在范围内

- 未公证安装包的 Gatekeeper 提示是预期行为，不是漏洞——安装说明里写了对应的去隔离命令。
- 用户主动把 key 交给恶意方、或运行被替换过的安装包，属于本机已被攻破的场景。

## 联系

仓库维护者：[@smarty-kiki](https://github.com/smarty-kiki)。
