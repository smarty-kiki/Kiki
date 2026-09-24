# Kiki

**一个住在 macOS 菜单栏里的中文伙伴。** 按住 **Control+Option** 说一句话，它一边用中文回答，一边让一个紫色光标飞到屏幕上答案所说的那个东西上，指给你看。该点的时候，它真的会点。

没有 Dock 图标，没有主窗口，没有账号，没有服务器。它在菜单栏上等着，你按住键，它就在。

> 按住说话 → 松手 → 它看一眼每块屏幕 → 一边回答，一边指给你看。

## 它好玩在哪儿

**它指给你看，不是干说。**
你问「哪个文件是季度报告」，话出口的同时，一个紫色光标已经飞过去停在那份文件上。再清楚的描述也不如指一下。

**它不只是指，它真的动手。**
飞过去之前，光标会先变红、把你的鼠标指针也一起带过去——「Kiki 要按这个了」你看得见——然后才真的按下去。单击、双击、三击、右键、上下左右滚、按住一个东西拖到另一个地方，都行。

**一句话说不完的事，它自己接着做。**
「先打开那个文件夹，再进下一层」——它做完一步就重新看一眼屏幕，再决定下一步，最多连着走二十步。它是看着做完之后的屏幕往下走的，不是一开始猜完就一路照做。面板上那句「脑子用了 18%」说的是它自己的记性：快满了，它会把前面的步骤收成一段摘要，腾出地方接着做。

**它是念着做的。**
回复一边往外写一边就被念出来，光标跟着念到的那句话走：话到哪儿，光标到哪儿。不是先念完再演一遍。

**它跟着你做一遍就会。**
按一下 **Shift+Option**，你照平常那样点、拖、滚一遍；再按一下，这串动作开始循环重放——真的在拖，不是在演。再按一下停下、忘掉。录的时候指针旁边有个红点。

**打字也行。**
不想说话就 `kiki command '看看哪些是新闻类的网站，帮我点开'`：看屏幕、指、点，一样不少，回复流回终端。另外九条子命令只动一下鼠标，不问模型、不出声，给脚本和快捷键用。

**它知道自己什么时候不该动手。**
读起来像「删除」「卸载」「格式化」的东西它不点，会直接告诉你；权限没给就不动；正在说话、正在录的时候，新请求会被挡回来并说明原因，不会乱套。

## 试试看

需要 **macOS 14.2+**、**Xcode 16+**，和一个 **DeepSeek API Key**（[platform.deepseek.com](https://platform.deepseek.com)）。

```bash
xcodebuild -project kiki-desktop-agent.xcodeproj -scheme kiki-desktop-agent \
  -configuration Debug \
  CODE_SIGN_IDENTITY="Smarty Kiki Signing" \
  CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" build

open ~/Library/Developer/Xcode/DerivedData/kiki-desktop-agent-*/Build/Products/Debug/Kiki.app
```

一条命令同时构建 `Kiki.app` 和命令行工具 `kiki`，两个产物落在同一个目录下。

然后：菜单栏点出面板 → 把 key 粘进去 → 按面板上的提示给五项权限。设置一完成，光标会在你屏幕上把引导演一遍，最后打出「嗨！我是 Kiki」——它演的就是它自己；如果你先粘了 key 再授权，它会等权限到位再放，不会跳过。那段视频就在仓库里：[`kiki-desktop-agent/kiki-intro.mp4`](kiki-desktop-agent/kiki-intro.mp4)。

随便打开一个窗口，按住 **Control+Option** 问：「这个窗口里有什么能点的？」

> **从终端构建没问题，但别从终端启动。** 直接跑 `Kiki.app/Contents/MacOS/Kiki`，**屏幕录制**这一项会被 macOS 算在**终端**头上，设置面板里怎么授权都不对。用 `open` 启动，它才会被当成它自己。

### 五项权限

| 权限 | 干什么用 |
|---|---|
| **麦克风** | 按住说话时的语音采集 |
| **语音识别** | 端上转写——和麦克风是两个独立的授权 |
| **辅助功能** | 全局快捷键，以及真的投出点击、滚动和拖拽 |
| **屏幕录制** | 抓屏幕给模型看 |
| **屏幕内容** | ScreenCaptureKit 的访问 |

面板会逐条显示状态，缺哪一条都写在上面。

## 它凭什么便宜、凭什么私密

**离开你机器的只有一个东西**：你要它看的那几屏截图，和它要回答的那句话。转写、朗读、抓屏、认字全都在端上跑（Apple 的 Speech 和 AVSpeechSynthesizer、ScreenCaptureKit、Vision），不联网也能转写。

**唯一的凭据是你自己的 DeepSeek API Key**，粘进面板就存进 **macOS 钥匙串**——不是 plist，不在二进制里，API 前面也没有代理。没有账号，没有邮箱门槛，没有「开始」按钮，用量是你自己的。

**零第三方依赖。** 纯原生 Swift 和 SwiftUI，仓库里没有 Swift Package，没有 Electron，没有一坨 node_modules。MIT。

## 命令行

```bash
kiki command '看看哪些是新闻类的网站，帮我点开'
```

同一条流水线，只是需求是打进去的，回复流回终端。**默认不出声**（加 `--speak` 才念）；stdout 只有回复正文，进度全走 stderr，所以可以直接重定向。回复还在跑的时候按 **Control+C** 会真的停掉这一轮。

另外九条只动一下鼠标——不问模型、不出声、不写历史：

```bash
kiki click -t 确定                  # 点画面上第一个「确定」
kiki click -x 720 -y 450            # 或者直接给坐标
kiki click -t 确定 -n 2 -s 1         # 第 1 块屏上第 2 个「确定」
kiki doubleclick -t 报告.pdf         # 连点两下（打开文件、选一段字）
kiki tripleclick -t 正文             # 连点三下（在正文里选中一整段）
kiki rightclick  -t 报告.pdf         # 右键，把那个菜单打开
kiki scrolldown  -t 消息列表 -b 0.5 # 滚半屏（0.5–20，默认 1）
kiki drag -t 报告.pdf --to-x 1160 --to-y 640 # 拖到 (1160, 640)
```

`-t` 是**先在本机读一遍屏幕**、找到这段字再动手，`-x`/`-y` 是全局坐标直接给。九条的 stdout 就是 Kiki 对这一下的说法（「已点击「确定」（第 1 个）。」），工具自己的毛病走 stderr。**成没成看退出码**：`0` 动了，`1` 没做成，`2` Kiki 说不行（`command` 那条多一个 `130`，是被 Control+C 停掉的）。

Kiki 没在运行时它们会**自己把它拉起来**。点击、滚动、拖拽没有模型参与，不花你一分钱。装到 `PATH` 上：

```bash
ln -s ~/Library/Developer/Xcode/DerivedData/kiki-desktop-agent-*/Build/Products/Debug/kiki /usr/local/bin/kiki
```

不装也行，写全路径调用就好。敲一个不带参数的 `kiki` 会打印全部用法。

## 再往下

- 光标是怎么找到元素的、模型写出的指向标签长什么样：[`AGENTS.md`](AGENTS.md) 的 Architecture 一节。
- 工程里都有什么：同一份文档的 Key Files 表，一个文件一行。
- 踩了会疼的坑，以及每一处决定背后的理由：也在 [`AGENTS.md`](AGENTS.md)。
- [`scripts/`](scripts) 里三个量测工具：模型读坐标准不准、点击怎么注入、滚轮哪个符号是往下。

`CLAUDE.md` 是指向 `AGENTS.md` 的符号链接，读哪个拿到的都是同一份文档。

## 许可

**MIT**，完整文本见 [`LICENSE`](LICENSE)。
