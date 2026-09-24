# Kiki

一个 macOS 菜单栏伙伴。按住 **Control + Option** 开口问，一个蓝色光标会飞到你屏幕上答案所指的地方并指出来——当模型这么要求时，它还会真的动手：点下去，或者把内容滚出来。也可以按一下 **Shift + Option**，让 Kiki 看你怎么做一遍，然后照着循环做。

Kiki 完全住在状态栏里：没有 Dock 图标，没有主窗口。它看得见你的屏幕，听得见你说话，用中文出声回答，并且会用光标指给你看。

## 工作流程

1. **按住 Control + Option** 说话。按键期间麦克风持续采集。
2. **松开**，Apple 的 Speech framework 把你说的话转成文字——在端上完成。
3. 用 ScreenCaptureKit 抓取**每一块已连接显示器**的截图，同时识别每块屏幕上的文字。
4. 转写文本和截图一起发给 **DeepSeek**，回复以 SSE 流式返回。
5. 回复用 `AVSpeechSynthesizer` **在端上朗读**，同时在光标旁的气泡里显示。
6. 回复里若带指向标签，光标会**依次飞向每个元素**，节奏由朗读带着走——是话等光标，不是光标追话。
7. 一件事一步做不完的——「先开那个文件夹，再进下一层」——Kiki 会**自己接着往下做**，最多连着走二十步。它每往下走一步都**重新看一眼屏幕**，所以看到的永远是你上一步做完之后的样子，而不是它一开始猜的那个。

这一串动作是**一气呵成**的：旁白从第一句念到最后一句，中间不重新起头。面板上有个**任务读数**，写着这是第几件事、走了几步、以及「脑子用了百分之多少」——那是 Kiki 自己的记性，快满了它会自己把前面的步骤收成一段摘要，好把地方腾出来。

除了发给 DeepSeek 的截图和转写文本，没有任何东西离开你的机器。转写、文字转语音、抓屏全部在端上跑。

## 指向是怎么工作的

模型只负责**说出元素的名字**，位置由 app 自己找。标签长这样：

```
[POINT:x,y:label]         看这里
[CLICK:x,y:label]         点这里（单击）
[DOUBLECLICK:x,y:label]   双击这里
[TRIPLECLICK:x,y:label]   三击这里（在正文里选中一整段）
[RIGHTCLICK:x,y:label]    在这里点右键（打开右键菜单）
[SCROLLUP:x,y:label]      在这里往上滚
[SCROLLDOWN:x,y:label]    往下滚
[SCROLLLEFT:x,y:label]    往左滚
[SCROLLRIGHT:x,y:label]   往右滚
[DRAG:x,y:label>X,Y]      从这里拖到那儿
```

`label` 是元素在屏幕上的原文，逐字照抄。**真正定位元素的是这个 label**——app 对截图跑端上 OCR，把 label 和识别到的文本做匹配，所以标签里的坐标只是「是哪一个」的提示。label 匹配不上时，就退回用模型自己给的坐标；元素根本没有文字时（图标、空白面板），坐标就是唯一的依据，因此可能落得偏一点。

滚动默认一屏，要滚多少写在 label 后面：`[SCROLLDOWN:640,400:消息列表:x3]` 是把那个列表往下滚三屏，`[SCROLLDOWN:640,400:消息列表:x0.5]` 是半屏。**最小半屏，最大 20 屏**——一屏经常滚过头，把你正看着的那几行甩出去。所以 Kiki 只是**想往下读**的时候会自己挑半屏，一屏以上留给真的要赶路的情况。

**那个 `x` 不能省**——第二个冒号之后全是元素名字，裸写成 `:3` 会被当成名字的一部分，滚动就悄悄变回一屏。

拖拽是唯一一个**两个点**的手势：`x,y` 是被拖的那个元素（按下去的地方），`>` 之后的 `X,Y` 是撒手的地方，写到 label 外面。元素在别的屏幕上时 `:screenN` 写在 `>` **前面**：`[DRAG:420,330:季度报告:screen2>1100,600]`。落点只认坐标、不做文字识别——那里没有字可以给 Kiki 认，所以它得和元素的坐标一样量准。label 里不能出现 `>`。

`[POINT:…]` 是默认的，因为邀请别人**看**一样东西永远不会错。另外九个是让 Kiki 自己去操作那个元素：光标飞过去时，它会**先把你的指针带过来、变成红色**，再把指针一路带到那个元素上，然后用 `CGEvent` 投出真实的动作——单击、双击、三击（在正文里选中一整段，按钮和菜单项不吃三下）、右键（右键菜单会真的在你屏幕上弹出来，指针就停在上面，接着自己选那一项就行），或者往某个方向滚动，屏幕上的内容就真的动起来，或者按住那个元素一路拖到另一个地方再松开。带指针这一下是「Kiki 要动手了」唯一的提示，所以被拒绝的动作不做这个动作，指针也不会被动。声音按**一次手势**算，不是一下按键一声，因此双击、三击和右键都只响一次；**滚动和拖拽不响**，内容动起来、东西搬过去本身就是反馈。

Kiki 不会点击它读起来有破坏性的东西——删除、清空、卸载、格式化、重置、还原、退出、关机、重启、注销、购买、支付、发送——没有辅助功能权限时也完全不动。被拒绝的点击**不会响**：那一声是「点了」的反馈，点在没发生的事上就是在说反话。**滚动和拖拽只受辅助功能权限管**：滚错了往回滚、拖错了拖回去就回去了，所以拦点击的那些字眼不拦它们。

这些标签让 Kiki 能指、能动，但**它看不见自己刚做的那一下**：弹出来的菜单里有什么、滚下去露出的是哪一段，它当场都不知道。所以一件事要接着做时它会写一个 `[LOOK]`——动作落地后重新看一眼屏幕，再决定下一步。看完再动，动完再看。

## 让 Kiki 跟着做

有些事说一遍说不清楚，做一遍就清楚了。

按一下 **Shift + Option** 开始记录：你在屏幕上怎么点、怎么拖、怎么滚，Kiki 都在看。再按一下，记录结束，它把这串动作**循环重放**出来。再按一下，停下来，忘掉。记录期间指针旁边有个**红点**，提醒你它正在看。

重放出来和你自己动手一模一样：光标飞过去、变红、把你的指针带上，然后真的做下去。录下来的那次拖拽，放出来是真的在拖，不是在演；滚出来的内容也是真的滚了。窗口挪了、那个按钮不在了，那一步就跳过，剩下的照放，不会因为一步失效就把整串停下来。

它自己**不问模型、不出声、不记历史**。录制和重放期间面板上是**记录中**和**重放中**——这时候你按 Control+Option 问一句，或者用 `kiki command` 打字提要求，录制就停了。一次只做一件事。

## DeepSeek API Key

这是 app 唯一的凭据，而且是你自己的。粘进设置面板，它就存进 **macOS 钥匙串**——不是 plist，不在二进制里，API 前面也没有代理服务器。构建产物里不含任何敏感信息，每个人为自己的用量付费。

存下 key 的那一刻设置就算完成：没有邮箱门槛，也没有「开始」按钮。

## 环境要求

- macOS 14.2 或更新（ScreenCaptureKit）
- Xcode 16 或更新
- 一个 **DeepSeek** API Key —— [platform.deepseek.com](https://platform.deepseek.com)

## 构建与运行

```bash
xcodebuild -project kiki-desktop-agent.xcodeproj -scheme kiki-desktop-agent \
  -configuration Debug \
  CODE_SIGN_IDENTITY="Smarty Kiki Signing" \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM="" \
  build
```

这条命令同时构建 `Kiki.app` 和命令行工具 `kiki`，两个产物落在同一个 `Build/Products/Debug/` 下。然后用 Finder 启动，或者 `open …/Kiki.app`。

> **从终端构建，但不要从终端启动。** 在终端里跑 `Kiki.app/Contents/MacOS/Kiki`，**屏幕录制**这一项会被 macOS 算到**终端**头上：设置面板会报告它没授权，无论你给 app 授权多少次，点那一行的「授权」按钮打开的还是一个已经打上勾的开关。用 `open` 启动，它才会被当作它自己来评判。辅助功能、麦克风和语音识别读的是 app 自己的签名记录，这条路启动也是好的。

工程目录和 scheme 是 `kiki-desktop-agent`，产物是 `Kiki.app`（`PRODUCT_NAME = Kiki`）。两者故意不同名。

### 权限

Kiki 需要五项，设置面板会逐条显示状态：

| 权限 | 用途 |
|---|---|
| **麦克风** | 按住说话时的语音采集 |
| **语音识别** | Apple 的端上转写——和麦克风是**两个独立**的 TCC 服务 |
| **辅助功能** | 全局 Control+Option 和 Shift+Option 快捷键，以及投出点击、滚动和拖拽 |
| **屏幕录制** | 抓取屏幕给模型看 |
| **屏幕内容** | ScreenCaptureKit 访问 |

首次的引导演示会等这些权限。它的全部意义就是让光标在屏幕上指东西，所以如果你在授权屏幕录制之前就先把 key 粘好了，演示会等权限到位后再放，而不是跳过。

### 代码签名

App 用的是本地**自签名证书** `Smarty Kiki Signing`，不是 Apple 开发者证书。它从不分发，也不需要描述文件——而自签名证书正是让权限授权**跨重新构建依然有效**的原因：

```
designated => identifier "com.smarty.kiki" and certificate root = H"ee5a2ca6f89d8ca593a7ccf0582da31449acaa83"
```

那个 `certificate root` 子句指向的是证书而不是某一次构建，所以重新构建出来的二进制仍然满足 TCC 当初记录下的要求。用 ad-hoc 签名的话这里会变成 `designated => cdhash H"…"`，每次重新构建都会变，于是每次都得重新授权一遍。

有一个构建设置纯粹是因为自签名证书没有 Team ID 才存在，而且**缺了它就起不来**：

- **`ENABLE_DEBUG_DYLIB = NO`**（Debug 配置）。Xcode 的 debug-dylib 功能会把 Debug 构建拆成一个 stub 加一个 `Kiki.debug.dylib`，而精简运行时的库校验在两边都没有 Team ID 时会拒绝这个组合——app 会以 *Library not loaded: @rpath/Kiki.debug.dylib* 挂掉。Release 构建本来就是单个二进制，不受影响。

Kiki 不内嵌任何第三方 framework，所以精简运行时是**完整生效**的：W^X、禁止未签名可执行内存、禁止 DYLD 注入，以及库校验，一条都没放宽。将来若换成真正的开发者证书，这项设置也可以撤掉。

## 命令行

同一个 app 还有一条打字进去的入口：

```bash
kiki command '看看哪些是新闻类的网站，帮我点开'
```

看一遍每块屏幕、光标飞过去指、该点的地方点下去——都照旧。区别只在于需求是打进去的，而且回复会**同时流回这个终端**。

**默认不出声**：不合成也不播放语音。没有旁白，光标就自己打拍子，逐个走完回复里提到的每一个元素，每个停约 0.4 秒。想让 Kiki 念出来就加 `--speak`：

```bash
kiki command --speak '看看哪些是新闻类的网站，帮我点开'
```

读出来时每个元素停约 1 秒——那是为了让光标跟得上念到哪儿了。两种情况都照常记进对话历史，记的都是剥掉坐标标签的正文。

回复还在跑的时候按 **Control+C**，这一轮会真的停下来——收起光标、停下朗读，已经出来的部分照常记进历史。不是「只是不看输出了」。

**stdout 只有回复正文，进度全在 stderr**，所以可以直接重定向：

```bash
kiki command '总结一下这个页面' > summary.txt
```

这一条和下面那九条手势不一样：它的 stdout 被回复占着，所以连 Kiki 自己说的话（「Kiki 正在看屏幕…」）也走 stderr。手势没有回复流，stdout 就腾出来给 Kiki 说那一句。

| 退出码 | 含义 |
|---|---|
| `0` | 这一轮跑完了 |
| `1` | 这一轮没能跑完（网络、额度、或者 Kiki 中途退出） |
| `2` | 命令**没有发出去**：Kiki 起不来、缺 DeepSeek API Key、缺屏幕录制权限，或者它正在休息 |
| `130` | 被 Control+C 停掉 |

Kiki 没在运行时，这条命令会**自己把它拉起来**再发送。但如果配置不具备（没填 key、或没有屏幕录制权限），它不会把命令发进去等它失败，而是直接打印缺什么并以 `2` 退出。

辅助功能权限**不在这份清单里**：没有它 Kiki 照样看得见、答得出、指得准，只是点击、滚动和拖拽会被拒掉——那和语音那条路完全一样。

**休息中**是光标正停在菜单栏图标里的那一段。那几秒里 Kiki 按设计不接收任何输入，命令会被挡住并说明原因，等光标出来再发就行——按住 Control+Option 的那条路也一样。

> 一次只有一条命令在跑。这条命令还在流的时候，在另一个终端再发一条，新的会**接管这一轮**，旧的终端被断开并说明原因。

### 只做一个鼠标动作

另外九条子命令**不问大模型、不出声、不写历史**，只是替你在某个地方动一下鼠标——给脚本和快捷键用：

```bash
kiki click -x 720 -y 450         # 点坐标 (720, 450)
kiki click -t 确定               # 点画面上第一个「确定」
kiki click -t 确定 -n 2          # 点画面上第 2 个「确定」
kiki doubleclick -t 报告.pdf     # 连点两下
kiki tripleclick -t 正文段落      # 连点三下，在正文里选中一整段
kiki rightclick   -t 报告.pdf    # 按右键，把那个文件的菜单打开
kiki scrolldown -t 消息列表       # 把消息列表往下滚一屏
kiki scrolldown -t 消息列表 -b 0.5 # 只滚半屏
kiki scrolldown -t 消息列表 -b 3  # 往下滚三屏
kiki scrollright -x 720 -y 450   # 在坐标 (720, 450) 往右滚一屏
kiki drag -t 报告.pdf --to-x 1160 --to-y 640   # 把「报告.pdf」拖到 (1160, 640)
kiki drag -x 420 -y 330 --to-x 1160 --to-y 640 # 从 (420, 330) 拖到 (1160, 640)
```

`-x`/`-y` 是全局屏幕坐标，主屏左上角为原点、y 向下，单位是点。两者必须成对出现，和 `-t` 只能给一组。`-b` 是滚几屏（**0.5 到 20，默认 1**，半屏写 `0.5`，也可以给 `1.5` 这种），只有四个滚动子命令收它；`--to-x`/`--to-y` 是拖拽的终点，必须成对出现，只有 `drag` 收——给别的子命令传这两个参数是参数错误，不是忽略。

`-t` 会**先在本机读一遍屏幕**，找到这段文字再动手，所以它比坐标慢一点。`-n` 是这段文字在画面上的第几个（从 1 起，默认 1）；多块屏幕时，指针所在的那块是第 1 块，`-n` 跨着屏数，`-s` 只数其中一块。

`doubleclick`、`tripleclick`、`rightclick`、四个 `scroll*` 和 `drag` 就是 `click` 换了手势，**九条的规则逐条相同**：参数、拒绝、退出码都一样。连点的间隔和 Kiki 自己回复里双击、三击一个元素时用的是同一个——三下必须落在同一次多击里，否则系统只会当成几次互不相干的点击；右键的菜单会真的弹出来，指针就停在上面，接着自己选那一项就行；滚动不响，也不拦破坏性字眼——滚错了往回滚一下就回去了。

`drag` 是九条里唯一一个动作发生在**两个点之间**的：它在起点按下鼠标，把东西一路搬到终点再松开，搬文件、搬图标、拉滑块、挪窗口都是它。终点只收坐标——那里没有文字可以认，Kiki 不做识别，按给的数落点。起点和终点要在同一块屏幕上，不在同一块时这次拖拽会被拒绝并说明，鼠标一动不动。它和滚动一样**不拦破坏性字眼**：拖错了拖回去就是了。

九条的 **stdout 就是 Kiki 对这一下的说法**：「Kiki 正在看屏幕…」（只有 `-t` 那种要读屏幕的才有这一行）和结果那句「已点击「确定」（第 1 个）。」。工具自己的毛病——参数写错、找不到 app、连接断了、等超时——都走 stderr，所以管道里收到的永远只有 Kiki 的话：

```bash
kiki click -t 确定 2>/dev/null    # 只要 Kiki 说的话
```

| 退出码 | 含义 |
|---|---|
| `0` | 动了 |
| `1` | 没能做成 |
| `2` | Kiki 说不行（原因就在 stdout 上，是它拒绝的那句话） |

成没成**看退出码，别去解析文字**：拒绝时 stdout 上那句（「「删除」这种字眼的东西 Kiki 不点，你自己来吧。」）是给人看的，话术会改，`2` 不会。

九条都只在面板显示**等待中**时才动。它在听你说话、在处理、在回复，或者光标正停在菜单栏图标里，都会被拒绝、鼠标一动不动。关掉的「允许 Kiki 用鼠标操作」和没给的**辅助功能**权限同样拒绝；破坏性的字眼（删除、卸载、格式化……）只拦四条点击，不拦滚动和拖拽。

滚动、三击、拖拽，还有**带小数的 `-b`**，各多一条：**正在运行的那个 Kiki 得认识它**。刚重新构建完但没重启 app 时会碰上——它不会把一次滚动、三击或拖拽当成别的动作，而是直接说明并以 `2` 退出。

> 动作**不打断任何东西**：它不会顶掉正在跑的回复。真的撞上另一个动作时，后者被拒绝而不是排队——但每条命令都会等到自己那一下落地才返回，所以脚本里连着写几条 `kiki click` 本来就是串行的。

Kiki 没在运行时，这九条同样会**自己把它拉起来**。点击、滚动和拖拽都**不需要 DeepSeek API Key**（不花你一分钱），但 `-t` 要真的看一眼屏幕，所以需要**屏幕录制**权限；`-x`/`-y` 不需要。

**只有 app 能发出点击、滚动和拖拽**——`CGEvent` 由 TCC 归属于发出它的进程，从工具里合成会被算在终端头上，所以 `kiki` 只能请求，动手的始终是 app。

装到 `PATH` 上（`/usr/local/bin` 需要 `sudo`）：

```bash
ln -s <DerivedData>/Build/Products/Debug/kiki /usr/local/bin/kiki
```

工具按「自己所在目录的隔壁就是 `Kiki.app`」来找 app，所以直接写全路径调用也行，不装也可以。拷去 `/Applications` 的情况也能认出来。

## 项目结构

```
kiki-desktop-agent/                Swift 源码 —— app target
  KikiApp.swift                      入口，只有菜单栏
  CompanionManager.swift             状态机：听写 → 抓屏 → 模型 → 朗读 → 指向，以及一轮里的多步循环
  CompanionCommandSocketServer.swift 命令行工具进来的那个套接字
  CompanionPanelView.swift           设置面板
  MenuBarPanelManager.swift          NSStatusItem + 浮动 NSPanel
  OverlayWindow.swift                光标覆盖层，每块显示器一个
  CompanionResponseOverlay.swift     光标旁的气泡与波形
  DeepSeekAPI.swift                  带图片输入的流式对话客户端
  DeepSeekAPIKeyStore.swift          key 的钥匙串存储
  AppleSpeechTranscriptionProvider.swift   端上语音转文字
  AppleTTSClient.swift               端上文字转语音
  ScreenshotTextRecognizer.swift     OCR，以及把标签的 label 在屏幕上找出来的匹配器
  ElementClicker.swift               点击 / 滚动 / 拖拽 / 带指针，投出真实事件；全 app 唯一会操作机器的地方
  ElementLocationDetector.swift      在截图里找 UI 元素的位置
  ElementClickSoundPlayer.swift      点击时那一声轻响（点击被拒绝时不响，滚动不响）
  UserActionRecorder.swift           听你自己的鼠标操作，把「跟着做」录成一串动作
  CompanionScreenCaptureUtility.swift      多显示器抓屏
  BuddyDictationManager.swift        按住说话的语音管线
  GlobalPushToTalkShortcutMonitor.swift    全局 Control+Option 的监听
  WindowPositionManager.swift        窗口摆放、权限流程
  DesignSystem.swift                 设计令牌
  KikiAnalytics.swift                PostHog
kiki-command-protocol/             app 和命令行工具共用的那一个文件（只有一份路径推导）
kiki-cli/                          Swift 源码 —— kiki 命令行工具 target
  main.swift                         参数、找 app、拉起、读取、渲染、退出码
  KikiCommandSocketClient.swift      连接、分帧、解码
kiki-desktop-agentTests/           单元测试（Xcode 模板桩，没有真实覆盖）
kiki-desktop-agentUITests/         UI 测试（同上）
scripts/pointing-calibration.swift      测量模型读坐标的准确度
scripts/click-injection-check.swift      测量各种点击注入方式对指针做了什么
scripts/scroll-injection-check.swift     测量合成的滚轮事件落到哪、哪个符号是往下
AGENTS.md                          开发约定：架构、不能踩的坑、文件清单
```

`CLAUDE.md` 是指向 `AGENTS.md` 的符号链接，所以 agent 读哪一个拿到的都是同一份文档。那份文档讲的是**约束**——架构、踩了会疼的坑、文件清单、构建与签名，以及每一处决定背后的理由（写在代码里那条注释旁边）。

## 许可

**MIT 许可**，完整文本见 [`LICENSE`](LICENSE)。

第三方依赖只有 [PostHog](https://github.com/PostHog/posthog-ios)（匿名使用统计），走 Swift Package Manager，版权归 PostHog 所有，同样是 MIT。
