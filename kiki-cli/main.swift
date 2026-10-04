import AppKit
import Foundation

/// Exit codes, so a script can tell "Kiki said no" from "Kiki could not be reached".
private enum ExitCode: Int32 {
    case success = 0
    case failed = 1
    case cannotRunCommand = 2
    case interruptedByControlC = 130
}

private let usageText = """
用法：kiki command [--speak] '<需求>'
      kiki click       -x <横坐标> -y <纵坐标>
      kiki click       -t <文字> [-n <第几个>] [-s <第几块屏>]
      kiki doubleclick -x <横坐标> -y <纵坐标>
      kiki doubleclick -t <文字> [-n <第几个>] [-s <第几块屏>]
      kiki tripleclick -x <横坐标> -y <纵坐标>
      kiki tripleclick -t <文字> [-n <第几个>] [-s <第几块屏>]
      kiki rightclick  -x <横坐标> -y <纵坐标>
      kiki rightclick  -t <文字> [-n <第几个>] [-s <第几块屏>]
      kiki scrollup / scrolldown / scrollleft / scrollright -x <横坐标> -y <纵坐标> [-b <几屏>]
      kiki scrollup / scrolldown / scrollleft / scrollright -t <文字> [-n <第几个>] [-s <第几块屏>] [-b <几屏>]
      kiki drag        -x <横坐标> -y <纵坐标> --to-x <横坐标> --to-y <纵坐标>
      kiki drag        -t <文字> [-n <第几个>] [-s <第几块屏>] --to-x <横坐标> --to-y <纵坐标>
      kiki type        '<要打的字>' -x <横坐标> -y <纵坐标>
      kiki type        '<要打的字>' -t <文字> [-n <第几个>] [-s <第几块屏>]
      kiki key         '<组合键>' -x <横坐标> -y <纵坐标>
      kiki key         '<组合键>' -t <文字> [-n <第几个>] [-s <第几块屏>]
      kiki screenshot  [-s <第几块屏>]
      kiki locate      '<文字>' [-s <第几块屏>]

command 把一条需求交给 Kiki，和按住 Control+Option 说话一样：它看屏幕、开口回答，回复里提到
的地方光标会飞过去指，该点的也会点。回复同时流回这个终端。

    kiki command '看看哪些是新闻类的网站，帮我点开'

默认不出声，光标逐个走完回复里提到的元素，每个停一下。加 --speak 就照常念出来：

    kiki command --speak '看看哪些是新闻类的网站，帮我点开'

Kiki 没在运行时会被自动启动。缺少 DeepSeek API Key 或屏幕录制权限时，命令不会被发送，
这里会说明缺什么并以状态码 2 退出。

stdout 只有回复正文，进度走 stderr，所以可以直接重定向：

    kiki command '总结一下这个页面' > summary.txt

回复还在跑的时候按 Control+C 会停掉这一轮（收起光标、停下朗读）。

click、doubleclick、tripleclick 和 rightclick 是另一类：给一个位置，Kiki 就在那儿按鼠标，
不问也不答，给脚本和快捷键用。doubleclick 连点两下，tripleclick 连点三下，rightclick
按右键。

    kiki click -x 720 -y 450        点主屏中心往右下的那个点
    kiki click -t 确定              点画面上第一个「确定」
    kiki click -t 确定 -n 2         点画面上第 2 个「确定」
    kiki click -t 确定 -n 2 -s 1    只在第 1 块屏幕上数

位置有两种给法，只能给一组。-x -y 是全局屏幕坐标，主屏左上角为原点、y 向下，单位是点，
两者必须成对出现。-t 是那段文字，Kiki 在屏幕上找到它；-n 是找第几个（从 1 起，默认 1），
多块屏幕时指针所在的那块是第 1 块、其余按系统顺序，-s 只数其中一块。

doubleclick 用来打开文件、选中一段字这类地方：

    kiki doubleclick -t 报告.pdf

tripleclick 连点三下，在 macOS 上基本只有一件事：在正文里选中一整段。按钮、菜单项、链接
那些地方三下只是多按了一下，会做出你没要的动作，别在那儿用。

    kiki tripleclick -t 正文

rightclick 按右键，用来打开那个元素的右键菜单。菜单弹出来之后指针就停在上面，接着自己选
那一项就行。

    kiki rightclick -t 报告.pdf

scrollup、scrolldown、scrollleft 和 scrollright 把看不见的那部分内容挪到眼前，
位置给法和上面一样，多一个 -b 说滚多远：

    kiki scrolldown -t 消息列表          把消息列表往下滚一屏
    kiki scrolldown -t 消息列表 -b 0.5   往下滚半屏
    kiki scrolldown -t 消息列表 -b 3     往下滚三屏
    kiki scrollright -x 720 -y 450       在坐标 (720, 450) 往右滚一屏

-b 是滚多远，单位是「几屏」，0.5 到 20，默认 1，可以带小数。一屏按那块屏幕的八成算，
滚完还看得见刚才那一段，不会一下跳到完全陌生的地方。一边滚一边找的时候用半屏——要找的东西
常常正好落在滚过去的那一半里——真要翻过去才用整屏。

drag 是唯一一个动作发生在两点之间的：在起点按下，把东西搬到终点再松开。搬文件、搬图标、
拉滑块、挪窗口都是它。

    kiki drag -t 报告.pdf --to-x 1160 --to-y 640     把「报告.pdf」拖到 (1160, 640)
    kiki drag -x 420 -y 330 --to-x 1160 --to-y 640   从 (420, 330) 拖到 (1160, 640)

--to-x 和 --to-y 是终点，必须成对出现，而且只有 drag 认这两个参数。终点只收坐标——那里没有
文字可找。起点和终点要在同一块屏幕上，不在同一块时这次拖拽会被拒绝并说明，鼠标一动不动。

type 和 key 是仅有的两条敲键盘的。第一个参数就是要敲的东西，用引号括起来；位置参数的意思
和上面完全一样，说的是敲在哪儿：

    kiki type '季度报告' -t 搜索框     在「搜索框」里打上「季度报告」
    kiki type '摘要.txt' -t 文件名      给文件改名
    kiki key  'cmd+s' -t 编辑器        在「编辑器」上按 ⌘S
    kiki key  'cmd+shift+t' -t 浏览器   按 ⌘⇧T（把刚关掉的标签页找回来）

type 会先点一下那个位置再打字——不点一下，字不知道往哪儿打。中文直接进，不用切输入法，
剪贴板里原来复制着的东西还在。key 只按键，不点：点一下会把插入点挪走，⌘S 之前不该有这一下。

组合键写法两种都认：`cmd+s`、`cmd+shift+t`，或者 `⌘S`、`⌘⇧T`，大小写无所谓。能按的是普通
按键加修饰键，比如 return、esc、tab、delete、方向键，或者一个字母。macOS 上那些会锁屏、
注销、清空废纸篓、强制退出的组合 Kiki 不按——它会说明是哪个组合并拒绝，退出码 2。一次打进去
的字也有个上限，太长同样会被拒绝并说明。

这一族都只在面板显示「等待中」时才会动手。它在听你说话、在处理、在回复，或者光标正停在
菜单栏图标里，这次操作都会被拒绝，鼠标一动不动。关掉的「允许 Kiki 用鼠标操作」（type 和
key 看的是旁边那个「允许 Kiki 用键盘操作」）和没给的辅助功能权限，同样拒绝。

破坏性的字眼（删除、卸载、格式化……）只拦点击：那类事按下去就收不回来。滚动和拖拽都不拦——
滚回去、拖回去就是了。

screenshot 和 locate 什么都不动，只读一遍屏幕，给脚本和别的程序用。

    kiki screenshot > screen.jpg           把指针所在那块屏截下来
    kiki screenshot -s 2 > second.jpg      截第 2 块屏

screenshot 的 stdout 就是 JPEG 图片本身，重定向成文件、管道给别的程序都行。没给 -s 就截
指针所在的那块——多块屏幕时它是第 1 块，和下面 -s 数的是同一个顺序。

    kiki locate '确定'                     屏幕上每一处「确定」在哪儿
    kiki locate '确定' -s 2                只在第 2 块屏幕上找
    kiki locate '下一步' | head -1         只取最上面那一处

locate 找出这段文字在屏幕上的每一处：stdout 一行一处，写成「横坐标 纵坐标 第几块屏」，
按阅读顺序（从上到下、从左到右）。屏幕上有三处就是三行。坐标和 click 的 -x -y 是同一套，
一行里的前两个数正好是 -x 和 -y 要的那两个，脚本可以直接拿去点。一处都没找到时退出码是 2，
说的是「屏幕上没有「确定」。」，和 kiki click -t 找不到时是同一句话。

这两条不打断 Kiki，它在忙别的时照样能用，也只有屏幕录制权限是必须的，没有就以 2 退出并说明。

十一个动作子命令的 stdout 上是 Kiki 对这一下的说法：「Kiki 正在看屏幕…」（只有 -t 那种要读
屏幕的才有这一行）和结果那句「已点击「确定」（第 1 个）。」。工具自己的毛病——参数写错、
找不到 app、连接断了、等超时——都走 stderr，所以管道里收到的只有 Kiki 的话。command、
screenshot 和 locate 的 stdout 另有东西（回复、图片、坐标），连 Kiki 的话也走 stderr。

退出码：0 做成了，1 没能做成，2 Kiki 说不行。成没成看这个数字，别去解析文字：被拒绝时
stdout 上是 Kiki 拒绝的那句话（「「删除」这种字眼的东西 Kiki 不点，你自己来吧。」），退出码
是 2，脚本照旧分得清。（screenshot 和 locate 的 stdout 上不是句子，被拒绝时那句话在 stderr
上，退出码照旧是 2。）

滚动、三击、拖拽、打字和组合键还各多一条：正在运行的那个 Kiki 得认识这个手势，不认识时会
直接说明并以 2 退出，而不是把这次动作做成别的——刚重新构建完但没重启 Kiki 时会碰上。
-b 带小数（比如 0.5）也一样，screenshot 和 locate 同理。
"""

/// How long to wait for the app's first answer: a cold launch through LaunchServices, plus its eager TLS warmup.
private let applicationStartupTimeoutSeconds: Double = 15

/// How long to wait between messages once running; the first arrives after every screen has been captured and recognised.
private let replyEventTimeoutSeconds: Double = 120

// MARK: - Output

/// The reply so far, as last printed — the text itself, not a length, so a snapshot whose tail moved is caught.
private var alreadyPrintedReplyText = ""

/// A sentence this tool is saying on its own behalf — never anything Kiki said, which goes to stdout.
private func reportProgress(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

/// A sentence the app sent, printed where a pipe can read it — only `event.message` may be passed here.
private func printWhatKikiSaid(_ message: String) {
    print(message)
    fflush(stdout)
}

private func printNewText(inReplyText replyTextSoFar: String) {
    if replyTextSoFar.hasPrefix(alreadyPrintedReplyText) {
        let newText = replyTextSoFar.dropFirst(alreadyPrintedReplyText.count)
        if !newText.isEmpty {
            print(String(newText), terminator: "")
            fflush(stdout)
        }
    } else {
        // The tidy pass moved the tail rather than extending it, so no suffix of the new snapshot is the unseen part.
        print()
        print(replyTextSoFar, terminator: "")
        fflush(stdout)
    }
    alreadyPrintedReplyText = replyTextSoFar
}

// MARK: - Finding and starting the app

private func locateKikiApplication() -> URL? {
    // Resolve symlinks first: the normal install is a symlink into `/usr/local/bin`.
    let executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()

    // A copy embedded in the app belongs to its bundle, found by walking every ancestor; an installed tool never starts another Kiki.
    var ancestorDirectoryURL = executableURL.deletingLastPathComponent()
    while ancestorDirectoryURL.pathComponents.count > 1 {
        if ancestorDirectoryURL.pathExtension == "app",
           Bundle(url: ancestorDirectoryURL)?.bundleIdentifier == "com.smarty.kiki" {
            return ancestorDirectoryURL
        }
        ancestorDirectoryURL = ancestorDirectoryURL.deletingLastPathComponent()
    }

    // Sibling of this executable: both products land in the same `Build/Products/<config>/`.
    let siblingApplicationURL = executableURL
        .deletingLastPathComponent()
        .appendingPathComponent("Kiki.app")
    if FileManager.default.fileExists(atPath: siblingApplicationURL.path) {
        return siblingApplicationURL
    }

    // For a Kiki.app that was copied somewhere else after being built, wherever LaunchServices knows it.
    return NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.smarty.kiki")
}

/// Through `open`, never by running the executable — a process started from a terminal is judged for
/// permissions against the terminal — and without `-n`, so an already-running app is activated, not duplicated.
@discardableResult
private func startKikiApplication(at applicationURL: URL) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = [applicationURL.path]
    do {
        try process.run()
    } catch {
        return false
    }
    process.waitUntilExit()
    return process.terminationStatus == 0
}

/// Connects, starting the app first if nothing is listening.
private func connectToKiki(applicationURL: URL?) -> KikiCommandSocketClient? {
    if let client = KikiCommandSocketClient(socketPath: KikiCommandProtocol.socketPath) {
        return client
    }

    guard let applicationURL else {
        reportProgress("找不到 Kiki.app。先构建一次，或者把它放到 /Applications。")
        return nil
    }

    reportProgress("Kiki 没在运行，正在启动…")
    guard startKikiApplication(at: applicationURL) else {
        reportProgress("启动 Kiki 失败：\(applicationURL.path)")
        return nil
    }

    let deadline = Date().addingTimeInterval(applicationStartupTimeoutSeconds)
    while Date() < deadline {
        if let client = KikiCommandSocketClient(socketPath: KikiCommandProtocol.socketPath) {
            return client
        }
        Thread.sleep(forTimeInterval: 0.25)
    }

    reportProgress("""
        等 Kiki 就绪超时（\(Int(applicationStartupTimeoutSeconds)) 秒）。
        最可能的原因是正在运行的那个 Kiki 是旧构建，还不认识这条命令通道——\
        退出它再试一次；实在不行重新构建一遍。
        """)
    return nil
}

// MARK: - Entry point

private func usageAndExit() -> Never {
    print(usageText)
    exit(ExitCode.success.rawValue)
}

/// Reports a problem found before anything was asked of Kiki, and ends the process: nothing is in flight.
private func fail(_ message: String, code: ExitCode) -> Never {
    reportProgress(message)
    exit(code.rawValue)
}

/// A command that could not be understood; the usage goes to the same stream.
private func failWithUsage(_ message: String) -> Never {
    reportProgress(message)
    reportProgress(usageText)
    exit(ExitCode.cannotRunCommand.rawValue)
}

// MARK: - kiki command

/// Hands a request to the app and streams the reply back, returning its exit code.
private func runCommandSubcommand(_ arguments: ArraySlice<String>) -> ExitCode {
    // Only the arguments *before* the request are read as flags; a request containing `--speak` is sent as written.
    var remainingArguments = arguments
    var shouldSpeakReply = false
    while let leadingArgument = remainingArguments.first, leadingArgument.hasPrefix("-") {
        guard leadingArgument == "--speak" else {
            failWithUsage("不认识的参数：\(leadingArgument)（只认 --speak）")
        }
        shouldSpeakReply = true
        remainingArguments = remainingArguments.dropFirst()
    }

    let commandText = remainingArguments.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !commandText.isEmpty else { usageAndExit() }

    guard let client = connectToKiki(applicationURL: locateKikiApplication()) else {
        return .cannotRunCommand
    }

    // Ctrl-C stops the turn too, on its own queue: the main thread is blocked on the socket.
    let controlCSignalSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    controlCSignalSource.setEventHandler {
        client.send(.cancel)
        reportProgress("\n已取消。")
        exit(ExitCode.interruptedByControlC.rawValue)
    }
    controlCSignalSource.resume()
    signal(SIGINT, SIG_IGN)

    // The app announces itself before anything is asked of it, so "cannot do this" is answered here.
    guard case .event(let readinessEvent) = client.readNextEvent(timeoutSeconds: applicationStartupTimeoutSeconds),
          readinessEvent.type == KikiCommandProtocol.MessageType.ready else {
        fail("Kiki 没有应答。它可能正在关闭，或者是不认识这条命令通道的旧构建。", code: .cannotRunCommand)
    }

    guard readinessEvent.canRunCommands == true else {
        let problems = readinessEvent.problems ?? []
        reportProgress("Kiki 现在跑不了这条命令：")
        for problem in problems {
            reportProgress("  · \(problem)")
        }
        return .cannotRunCommand
    }

    client.send(.command(commandText, speakReply: shouldSpeakReply))

    while true {
        let readOutcome = client.readNextEvent(timeoutSeconds: replyEventTimeoutSeconds)
        guard case .event(let event) = readOutcome else {
            if case .disconnected = readOutcome {
                // Not "Kiki 退出了": a disconnect without a `superseded` before it is usually the app
                // going away — though a terminal that stopped reading is hung up on the same way.
                reportProgress("和 Kiki 的连接断了，这一轮没能跑完。")
                return .failed
            }
            reportProgress("等了 \(Int(replyEventTimeoutSeconds)) 秒也没等到 Kiki 的回复。")
            return .failed
        }

        switch event.type {
        case KikiCommandProtocol.MessageType.accepted:
            // Kiki's own sentence, but here even that goes to stderr: stdout is the reply.
            if let message = event.message {
                reportProgress(message)
            }

        case KikiCommandProtocol.MessageType.text:
            if let replyTextSoFar = event.spokenTextSoFar {
                printNewText(inReplyText: replyTextSoFar)
            }

        case KikiCommandProtocol.MessageType.done:
            if let finalReplyText = event.spokenText {
                printNewText(inReplyText: finalReplyText)
            }
            print()
            return .success

        case KikiCommandProtocol.MessageType.failed:
            reportProgress(event.message ?? "Kiki 这一轮出错了。")
            return .failed

        case KikiCommandProtocol.MessageType.superseded:
            // Sent just before the app closes this connection to hand the turn to a newer one; the hang-up is the point.
            reportProgress("另一个终端发了新需求，这一轮被它接过去了。")
            return .failed

        default:
            // `ready` can arrive twice, and a newer app may send types this build has never heard of; neither stops the read.
            continue
        }
    }
}

// MARK: - kiki click

/// Turns the flags into what the app is asked for; every way of getting them wrong is answered here.
///
/// Which flags are recognized follows from the gesture: `-b` on a press is a mistake, not a flag quietly dropped.
private func clickRequestFromArguments(
    _ arguments: ArraySlice<String>,
    gesture: String?
) -> KikiClickRequest {
    let isAScrollingGesture = gesture == KikiCommandProtocol.Gesture.scrollUp
        || gesture == KikiCommandProtocol.Gesture.scrollDown
        || gesture == KikiCommandProtocol.Gesture.scrollLeft
        || gesture == KikiCommandProtocol.Gesture.scrollRight
    let isADraggingGesture = gesture == KikiCommandProtocol.Gesture.drag
    let isAKeyboardGesture = gesture == KikiCommandProtocol.Gesture.typeText
        || gesture == KikiCommandProtocol.Gesture.pressKey

    var recognizedFlags = ["-x", "-y", "-t", "-n", "-s"]
    if isAScrollingGesture {
        recognizedFlags.append("-b")
    }
    if isADraggingGesture {
        recognizedFlags.append(contentsOf: ["--to-x", "--to-y"])
    }

    var valueByFlag: [String: String] = [:]
    // The words to type or the combination to press — the one argument that is neither a flag nor a flag's value.
    var payloadArgument: String?
    var remainingArguments = arguments
    while let flag = remainingArguments.first {
        remainingArguments = remainingArguments.dropFirst()

        if isAKeyboardGesture, !flag.hasPrefix("-") {
            guard payloadArgument == nil else {
                failWithUsage("只要一段文字或者一个组合键：\(payloadArgument ?? "") 后面又多了一个 \(flag)。")
            }
            payloadArgument = flag
            continue
        }

        guard recognizedFlags.contains(flag) else {
            let allowedFlags = recognizedFlags.joined(separator: " ")
            failWithUsage("不认识的参数：\(flag)（这个子命令只认 \(allowedFlags)）")
        }
        guard let value = remainingArguments.first else {
            failWithUsage("\(flag) 后面要跟一个值。")
        }
        remainingArguments = remainingArguments.dropFirst()
        valueByFlag[flag] = value
    }

    // Required: a keyboard gesture with no payload is answered by the app as a gesture it does not know,
    // which reads as a version problem.
    //
    // Whether the words are longer than Kiki will type, or the combination one it will not press, is not
    // asked here: both live in `ElementKeyboard`, and a copy would be a second answer. Refused with exit 2.
    var typedText: String?
    var keyCombination: String?
    if isAKeyboardGesture {
        guard let payloadArgument,
              !payloadArgument.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            failWithUsage(
                gesture == KikiCommandProtocol.Gesture.typeText
                    ? "要说打什么字：kiki type '季度报告' -t 搜索框"
                    : "要说按哪个组合键：kiki key 'cmd+s' -t 编辑器"
            )
        }
        if gesture == KikiCommandProtocol.Gesture.typeText {
            typedText = payloadArgument
        } else {
            keyCombination = payloadArgument
        }
    }

    let hasCoordinate = valueByFlag["-x"] != nil || valueByFlag["-y"] != nil
    let hasText = valueByFlag["-t"] != nil
    guard !(hasCoordinate && hasText) else {
        failWithUsage("-x/-y 和 -t 只能给一组：一边说点哪儿，一边说要点的字。")
    }
    guard hasCoordinate || hasText else {
        failWithUsage("要说点哪儿：给坐标 -x -y，或者给要点的文字 -t。")
    }

    var screenfuls: Double?
    if let rawScreenfuls = valueByFlag["-b"] {
        guard let parsedScreenfuls = Double(rawScreenfuls), (0.5...20).contains(parsedScreenfuls) else {
            failWithUsage("-b 要是 0.5 到 20 之间的数：滚几屏，半屏写 0.5。")
        }
        screenfuls = parsedScreenfuls
    }

    // A drag is refused without one, so a request naming no destination is a mistake this end describes.
    var dragDestinationGlobalScreenX: Double?
    var dragDestinationGlobalScreenY: Double?
    if isADraggingGesture {
        guard let rawDestinationX = valueByFlag["--to-x"],
              let rawDestinationY = valueByFlag["--to-y"],
              let parsedDestinationX = Double(rawDestinationX),
              let parsedDestinationY = Double(rawDestinationY) else {
            failWithUsage("拖拽要说拖到哪儿：--to-x 和 --to-y 要成对出现，而且都得是数。")
        }
        dragDestinationGlobalScreenX = parsedDestinationX
        dragDestinationGlobalScreenY = parsedDestinationY
    }

    if hasCoordinate {
        guard let rawX = valueByFlag["-x"], let rawY = valueByFlag["-y"],
              let globalScreenX = Double(rawX), let globalScreenY = Double(rawY) else {
            failWithUsage("-x 和 -y 要成对出现，而且都得是数。")
        }
        guard valueByFlag["-n"] == nil, valueByFlag["-s"] == nil else {
            failWithUsage("-n 和 -s 是给 -t 用的：坐标不用数，也不用挑屏幕。")
        }
        return KikiClickRequest(
            globalScreenX: globalScreenX,
            globalScreenY: globalScreenY,
            screenfuls: screenfuls,
            dragToGlobalScreenX: dragDestinationGlobalScreenX,
            dragToGlobalScreenY: dragDestinationGlobalScreenY,
            typedText: typedText,
            keyCombination: keyCombination
        )
    }

    guard let elementText = valueByFlag["-t"], !elementText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        failWithUsage("-t 后面要跟要点的文字。")
    }

    var occurrenceNumber: Int?
    if let rawOccurrenceNumber = valueByFlag["-n"] {
        guard let parsedOccurrenceNumber = Int(rawOccurrenceNumber), parsedOccurrenceNumber >= 1 else {
            failWithUsage("-n 要是 1 以上的整数：第几个。")
        }
        occurrenceNumber = parsedOccurrenceNumber
    }

    var screenNumber: Int?
    if let rawScreenNumber = valueByFlag["-s"] {
        guard let parsedScreenNumber = Int(rawScreenNumber), parsedScreenNumber >= 1 else {
            failWithUsage("-s 要是 1 以上的整数：第几块屏幕。")
        }
        screenNumber = parsedScreenNumber
    }

    return KikiClickRequest(
        elementText: elementText,
        occurrenceNumber: occurrenceNumber,
        screenNumber: screenNumber,
        screenfuls: screenfuls,
        dragToGlobalScreenX: dragDestinationGlobalScreenX,
        dragToGlobalScreenY: dragDestinationGlobalScreenY,
        typedText: typedText,
        keyCombination: keyCombination
    )
}

/// The name of the gesture the running app does not know, or nil when it knows the one this terminal is
/// about to ask for.
///
/// An app that does not know a gesture does not necessarily refuse it — the three clicks are answered by
/// any app that has the `gesture` field — so each gesture added afterwards is announced in `ready` and
/// asked about here; an absent field answers "no".
private func gestureTheRunningKikiDoesNotKnow(
    _ gesture: String?,
    in readinessEvent: KikiCommandEvent
) -> String? {
    switch gesture {
    case nil,
         KikiCommandProtocol.Gesture.singleClick,
         KikiCommandProtocol.Gesture.doubleClick,
         KikiCommandProtocol.Gesture.rightClick:
        return nil
    case KikiCommandProtocol.Gesture.tripleClick:
        return readinessEvent.understandsTripleClick == true ? nil : "三击"
    case KikiCommandProtocol.Gesture.scrollUp,
         KikiCommandProtocol.Gesture.scrollDown,
         KikiCommandProtocol.Gesture.scrollLeft,
         KikiCommandProtocol.Gesture.scrollRight:
        return readinessEvent.understandsScrolling == true ? nil : "滚动"
    case KikiCommandProtocol.Gesture.drag:
        // The one whose being unknown is not merely a different action: a pre-drag app ignores the destination fields and presses at the start.
        return readinessEvent.understandsDragging == true ? nil : "拖拽"
    case KikiCommandProtocol.Gesture.typeText:
        // Unknown here is a press too: the payload is ignored, so the insertion point moves and nothing is typed.
        return readinessEvent.understandsTyping == true ? nil : "输入文字"
    case KikiCommandProtocol.Gesture.pressKey:
        // And here unknown is a click: the insertion point moves, so a ⌘S lands on whatever that press selected.
        return readinessEvent.understandsPressingKeys == true ? nil : "按组合键"
    default:
        // A gesture this build of the tool does not know either; refusing is the only safe reading of one nobody knows.
        return "这个手势"
    }
}

/// The distance the running app would be unable to read, or nil when it can read this one.
///
/// A separate question from `gestureTheRunningKikiDoesNotKnow`: an app that scrolls at all reads the
/// distance as a whole number, so a fractional one makes the *whole request* undecodable — silence, not a
/// short scroll. Only a non-whole distance is asked about; `-b 3` such an app reads correctly.
private func screenfulsTheRunningKikiCannotRead(
    _ clickRequest: KikiClickRequest,
    in readinessEvent: KikiCommandEvent
) -> Double? {
    guard let screenfuls = clickRequest.screenfuls, screenfuls != screenfuls.rounded() else {
        return nil
    }
    return readinessEvent.understandsFractionalScreenfuls == true ? nil : screenfuls
}

/// Asks the app to act where this terminal says, with the gesture the subcommand named.
private func runActionSubcommand(
    _ arguments: ArraySlice<String>,
    gesture: String?
) -> ExitCode {
    var clickRequest = clickRequestFromArguments(arguments, gesture: gesture)
    // The subcommand is the gesture rather than a flag: one parser, the same refusals, only the point differs.
    clickRequest.gesture = gesture

    guard let client = connectToKiki(applicationURL: locateKikiApplication()) else {
        return .cannotRunCommand
    }

    // Control+C is deliberately not intercepted: `.cancel` stops whichever turn is running, and a gesture displaces nothing.

    guard case .event(let readinessEvent) = client.readNextEvent(timeoutSeconds: applicationStartupTimeoutSeconds),
          readinessEvent.type == KikiCommandProtocol.MessageType.ready else {
        fail("Kiki 没有应答。它可能正在关闭，或者是不认识这条命令通道的旧构建。", code: .cannotRunCommand)
    }

    // Asked before anything is sent: rebuilding without restarting leaves an older Kiki listening.
    if let unknownGesture = gestureTheRunningKikiDoesNotKnow(
        clickRequest.gesture,
        in: readinessEvent
    ) {
        failBecauseTheRunningKikiDoesNotKnow(unknownGesture)
    }

    if let screenfulsTheRunningKikiCannotRead = screenfulsTheRunningKikiCannotRead(
        clickRequest,
        in: readinessEvent
    ) {
        fail(
            "正在运行的这个 Kiki 是旧版本，只认整屏的滚动，\(screenfulsTheRunningKikiCannotRead) 屏它读不了。"
                + "把菜单栏里的 Kiki 退出再重新启动一次就能用。",
            code: .cannotRunCommand
        )
    }

    // `canRunCommands` is deliberately not consulted: it answers whether a *request* can be run, which no
    // gesture needs. Whether one can be made right now is Kiki's to say in its reply.

    client.send(.click(clickRequest))
    return readTheOneAnswer(from: client, waitingFor: .theActionTheTerminalAskedFor)
}

// MARK: - kiki screenshot and kiki locate

/// Which request is being waited on; the whole of what differs between the thirteen subcommands.
private enum TheAnswerBeingWaitedFor {
    /// One of the eleven gestures; the app's sentence about the action is the whole product.
    case theActionTheTerminalAskedFor
    /// `kiki screenshot`. The picture is the product and goes to stdout as bytes.
    case aPictureOfTheScreen
    /// `kiki locate`. The points are the product, one per line on stdout.
    case thePointsWhereTheTextIs
}

private extension TheAnswerBeingWaitedFor {
    /// What a dropped connection means: the gesture did not happen, or the picture did not arrive.
    var connectionDroppedSentence: String {
        switch self {
        case .theActionTheTerminalAskedFor:
            return "和 Kiki 的连接断了，这次操作没做成。"
        case .aPictureOfTheScreen, .thePointsWhereTheTextIs:
            return "和 Kiki 的连接断了，这次没做成。"
        }
    }

    var supersededSentence: String {
        switch self {
        case .theActionTheTerminalAskedFor:
            return "另一个终端连上来了，这次操作没做成。"
        case .aPictureOfTheScreen, .thePointsWhereTheTextIs:
            return "另一个终端连上来了，这次没做成。"
        }
    }
}

/// stdout for a gesture; stderr for the two readers, whose stdout carries bytes.
private func printKikisSentence(_ message: String, waitingFor answer: TheAnswerBeingWaitedFor) {
    switch answer {
    case .theActionTheTerminalAskedFor:
        printWhatKikiSaid(message)
    case .aPictureOfTheScreen, .thePointsWhereTheTextIs:
        reportProgress(message)
    }
}

/// Reads until the app answers the one thing that was asked of it, prints what it says, and reports how it went.
private func readTheOneAnswer(
    from client: KikiCommandSocketClient,
    waitingFor answer: TheAnswerBeingWaitedFor
) -> ExitCode {
    while true {
        let readOutcome = client.readNextEvent(timeoutSeconds: replyEventTimeoutSeconds)
        guard case .event(let event) = readOutcome else {
            if case .disconnected = readOutcome {
                reportProgress(answer.connectionDroppedSentence)
                return .failed
            }
            reportProgress("等了 \(Int(replyEventTimeoutSeconds)) 秒也没等到 Kiki 回话。")
            return .failed
        }

        switch event.type {
        case KikiCommandProtocol.MessageType.accepted:
            // Said by the app once the request is going ahead and the screen is about to be read. Never
            // promised from here, or a refusal decidable without looking would be preceded by a false claim.
            if let message = event.message {
                printKikisSentence(message, waitingFor: answer)
            }

        case KikiCommandProtocol.MessageType.clicked:
            // A landed action with nothing to say is a success with an empty stdout, which the exit code carries.
            if let message = event.message {
                printKikisSentence(message, waitingFor: answer)
            }
            return .success

        case KikiCommandProtocol.MessageType.captured:
            if let message = event.message {
                printKikisSentence(message, waitingFor: answer)
            }
            guard let base64JPEG = event.screenshotJPEGBase64,
                  let jpegData = Data(base64Encoded: base64JPEG) else {
                reportProgress("Kiki 说图截到了，可是图片没能解开。")
                return .failed
            }
            // Raw, because it is the product: prose here would be a byte in the middle of a JPEG.
            FileHandle.standardOutput.write(jpegData)
            return .success

        case KikiCommandProtocol.MessageType.located:
            if let message = event.message {
                printKikisSentence(message, waitingFor: answer)
            }
            for locatedPoint in event.locatedPoints ?? [] {
                // Rounded, not truncated: a coordinate between two points is wanted at the nearer one.
                print("\(Int(locatedPoint.globalScreenX.rounded())) "
                    + "\(Int(locatedPoint.globalScreenY.rounded())) \(locatedPoint.screenNumber)")
            }
            fflush(stdout)
            return .success

        case KikiCommandProtocol.MessageType.failed:
            if let message = event.message {
                printKikisSentence(message, waitingFor: answer)
            } else {
                // A failure is never silent, and this one is the tool's to report: the app said nothing of Kiki's.
                reportProgress("Kiki 这一轮出错了。")
            }
            // A refusal attempted nothing; a failure meant an event and it did not go out — a script acts on the difference: two codes.
            return event.isRefusal == true ? .cannotRunCommand : .failed

        case KikiCommandProtocol.MessageType.superseded:
            reportProgress(answer.supersededSentence)
            return .failed

        default:
            continue
        }
    }
}

/// Refuses a request the running app is too old to answer, and ends the process: an app that does not know
/// a request *type* ignores it in silence, so the wait runs out — which is what Kiki gone looks like.
private func failBecauseTheRunningKikiDoesNotKnow(_ whatItDoesNotKnow: String) -> Never {
    fail(
        "正在运行的这个 Kiki 是旧版本，还不认识\(whatItDoesNotKnow)。把菜单栏里的 Kiki 退出再重新启动一次就能用。",
        code: .cannotRunCommand
    )
}

/// Asks the app for a picture of one screen and writes the JPEG itself to stdout.
private func runScreenshotSubcommand(_ arguments: ArraySlice<String>) -> ExitCode {
    var screenNumber: Int?
    var remainingArguments = arguments
    while let flag = remainingArguments.first {
        remainingArguments = remainingArguments.dropFirst()
        guard flag == "-s" else {
            failWithUsage("不认识的参数：\(flag)（这个子命令只认 -s）")
        }
        guard let rawScreenNumber = remainingArguments.first else {
            failWithUsage("-s 后面要跟一个值。")
        }
        remainingArguments = remainingArguments.dropFirst()
        guard let parsedScreenNumber = Int(rawScreenNumber), parsedScreenNumber >= 1 else {
            failWithUsage("-s 要是 1 以上的整数：第几块屏幕。")
        }
        screenNumber = parsedScreenNumber
    }

    guard let client = connectToKiki(applicationURL: locateKikiApplication()) else {
        return .cannotRunCommand
    }

    guard case .event(let readinessEvent) = client.readNextEvent(timeoutSeconds: applicationStartupTimeoutSeconds),
          readinessEvent.type == KikiCommandProtocol.MessageType.ready else {
        fail("Kiki 没有应答。它可能正在关闭，或者是不认识这条命令通道的旧构建。", code: .cannotRunCommand)
    }

    guard readinessEvent.understandsScreenshots == true else {
        failBecauseTheRunningKikiDoesNotKnow("截屏")
    }

    // `canRunCommands` is deliberately not consulted here either: a picture needs no API key and no idle Kiki.

    client.send(.screenshot(KikiScreenshotRequest(screenNumber: screenNumber)))
    return readTheOneAnswer(from: client, waitingFor: .aPictureOfTheScreen)
}

/// Asks the app where a piece of text is on screen and prints one point per line.
private func runLocateSubcommand(_ arguments: ArraySlice<String>) -> ExitCode {
    var textToFind: String?
    var screenNumber: Int?
    var remainingArguments = arguments
    while let argument = remainingArguments.first {
        remainingArguments = remainingArguments.dropFirst()

        // A bare argument rather than a flag's value, as `type` and `key` take theirs: it is arbitrary text.
        if !argument.hasPrefix("-") {
            guard textToFind == nil else {
                failWithUsage("只要一段文字：\(textToFind ?? "") 后面又多了一个 \(argument)。")
            }
            textToFind = argument
            continue
        }

        guard argument == "-s" else {
            failWithUsage("不认识的参数：\(argument)（这个子命令只认 -s）")
        }
        guard let rawScreenNumber = remainingArguments.first else {
            failWithUsage("-s 后面要跟一个值。")
        }
        remainingArguments = remainingArguments.dropFirst()
        guard let parsedScreenNumber = Int(rawScreenNumber), parsedScreenNumber >= 1 else {
            failWithUsage("-s 要是 1 以上的整数：第几块屏幕。")
        }
        screenNumber = parsedScreenNumber
    }

    guard let textToFind, !textToFind.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        failWithUsage("要说找什么：kiki locate '确定'")
    }

    guard let client = connectToKiki(applicationURL: locateKikiApplication()) else {
        return .cannotRunCommand
    }

    guard case .event(let readinessEvent) = client.readNextEvent(timeoutSeconds: applicationStartupTimeoutSeconds),
          readinessEvent.type == KikiCommandProtocol.MessageType.ready else {
        fail("Kiki 没有应答。它可能正在关闭，或者是不认识这条命令通道的旧构建。", code: .cannotRunCommand)
    }

    guard readinessEvent.understandsLocatingText == true else {
        failBecauseTheRunningKikiDoesNotKnow("找文字")
    }

    // Which occurrences are wanted is not a flag: every one of them is the answer.

    client.send(.locate(KikiLocateRequest(text: textToFind, screenNumber: screenNumber)))
    return readTheOneAnswer(from: client, waitingFor: .thePointsWhereTheTextIs)
}

// MARK: - Entry point

let arguments = Array(CommandLine.arguments.dropFirst())

guard let subcommand = arguments.first else { usageAndExit() }

// The only place a subcommand's code becomes a process exit; Ctrl-C has a call of its own.
switch subcommand {
case "command":
    exit(runCommandSubcommand(arguments.dropFirst()).rawValue)
case "click":
    exit(runActionSubcommand(arguments.dropFirst(), gesture: nil).rawValue)
case "doubleclick":
    exit(runActionSubcommand(
        arguments.dropFirst(),
        gesture: KikiCommandProtocol.Gesture.doubleClick
    ).rawValue)
case "tripleclick":
    exit(runActionSubcommand(
        arguments.dropFirst(),
        gesture: KikiCommandProtocol.Gesture.tripleClick
    ).rawValue)
case "rightclick":
    exit(runActionSubcommand(
        arguments.dropFirst(),
        gesture: KikiCommandProtocol.Gesture.rightClick
    ).rawValue)
case "scrollup":
    exit(runActionSubcommand(
        arguments.dropFirst(),
        gesture: KikiCommandProtocol.Gesture.scrollUp
    ).rawValue)
case "scrolldown":
    exit(runActionSubcommand(
        arguments.dropFirst(),
        gesture: KikiCommandProtocol.Gesture.scrollDown
    ).rawValue)
case "scrollleft":
    exit(runActionSubcommand(
        arguments.dropFirst(),
        gesture: KikiCommandProtocol.Gesture.scrollLeft
    ).rawValue)
case "scrollright":
    exit(runActionSubcommand(
        arguments.dropFirst(),
        gesture: KikiCommandProtocol.Gesture.scrollRight
    ).rawValue)
case "drag":
    exit(runActionSubcommand(
        arguments.dropFirst(),
        gesture: KikiCommandProtocol.Gesture.drag
    ).rawValue)
case "type":
    exit(runActionSubcommand(
        arguments.dropFirst(),
        gesture: KikiCommandProtocol.Gesture.typeText
    ).rawValue)
case "key":
    exit(runActionSubcommand(
        arguments.dropFirst(),
        gesture: KikiCommandProtocol.Gesture.pressKey
    ).rawValue)
case "screenshot":
    exit(runScreenshotSubcommand(arguments.dropFirst()).rawValue)
case "locate":
    exit(runLocateSubcommand(arguments.dropFirst()).rawValue)
default:
    // Covers a subcommand that does not exist and, more usefully, one this tool is a version behind on.
    usageAndExit()
}
