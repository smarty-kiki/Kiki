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

command 把一条需求交给 Kiki，处理方式和按住 Control+Option 说话完全一样：它看一遍每块屏幕，
光标照常飞过去指——该点的地方也会点。回复同时流回这个终端。

    kiki command '看看哪些是新闻类的网站，帮我点开'

默认不出声：不合成也不播放语音，光标逐个走完回复里提到的元素，每个停一下。
加 --speak 就照常念出来：

    kiki command --speak '看看哪些是新闻类的网站，帮我点开'

Kiki 没在运行时会被自动启动。缺少 DeepSeek API Key 或屏幕录制权限时，命令不会被发送，
这里会打印缺什么并以状态码 2 退出。

stdout 只有回复正文，进度走 stderr，所以可以直接重定向：

    kiki command '总结一下这个页面' > summary.txt

下面那九个手势子命令不一样：它们没有回复，stdout 上就是 Kiki 对这一下的说法
（「正在看屏幕」和「已点击「确定」（第 1 个）。」），工具自己的毛病才走 stderr。

回复还在跑的时候按 Control+C 会停掉这一轮（收起光标、停下朗读）。

click、doubleclick、tripleclick 和 rightclick 是另一回事：不写需求、不问大模型、不出声，
只把鼠标移过去按（doubleclick 连点两下，tripleclick 连点三下，rightclick 按右键），给脚本
或者快捷键用。

    kiki click -x 720 -y 450        点主屏中心往右下的那个点
    kiki click -t 确定              点画面上第一个「确定」
    kiki click -t 确定 -n 2         点画面上第 2 个「确定」
    kiki click -t 确定 -n 2 -s 1    只在第 1 块屏幕上数

-x -y 是全局屏幕坐标，主屏左上角为原点、y 向下，单位是点。两者必须成对出现，
和 -t 只能给一组。

-t 会先在本机读一遍屏幕，找这段文字。-n 是它在画面上的第几个（从 1 起，默认 1）。
多块屏幕时，指针所在的那块是第 1 块，其余按系统顺序；-n 按这个顺序跨着屏数，
-s 只数其中一块。

doubleclick 和 click 一模一样，只有一处不同：在那个点连点两下。两次之间的间隔和 Kiki
自己回复里双击一个元素时用的是同一个，要打开文件、选中一段字这类地方用它。

    kiki doubleclick -t 报告.pdf

tripleclick 同理，连点三下。它在 macOS 上基本只有一件事：在正文里点三下选中一整段。
按钮、菜单项、链接那些地方三下只是多按了一下，会做出你没要的动作，别在那儿用。

    kiki tripleclick -t 正文

rightclick 和前几条也一样，只是按的是右键，用来打开那个元素的右键菜单。菜单弹出来之后
指针就停在上面，接着自己选那一项就行。

    kiki rightclick -t 报告.pdf

scrollup、scrolldown、scrollleft 和 scrollright 也是同一族，只是动作换成往那个方向滚动，
用来把看不见的那部分内容挪到眼前：

    kiki scrolldown -t 消息列表          把消息列表往下滚一屏
    kiki scrolldown -t 消息列表 -b 0.5   往下滚半屏
    kiki scrolldown -t 消息列表 -b 3     往下滚三屏
    kiki scrollright -x 720 -y 450       在坐标 (720, 450) 往右滚一屏

-b 是滚多远，单位是「几屏」，0.5 到 20，默认 1，可以带 .5。一屏按那块屏幕的八成算，滚完还
看得见刚才那一段，不会一下跳到完全陌生的地方；左右按屏幕的宽算。-b 0.5 是半屏：一屏滚下去，
刚才在看的那几行就出了画面，而要找的东西常常正好落在滚过去的那一半里，所以一边滚一边找的时候
用半屏，真要翻过去才用整屏。

drag 是这一族里唯一一个动作发生在两点之间的：它在起点按下鼠标，把东西一路搬到终点，到了
再松开。搬文件、搬图标、拉滑块、把窗口挪开都是它。

    kiki drag -t 报告.pdf --to-x 1160 --to-y 640     把「报告.pdf」拖到 (1160, 640)
    kiki drag -x 420 -y 330 --to-x 1160 --to-y 640   从 (420, 330) 拖到 (1160, 640)

--to-x 和 --to-y 是终点，必须成对出现，而且只有 drag 认这两个参数。终点只收坐标：那里没有
文字可以认，所以 Kiki 不做识别，按给的数落点。起点和终点要在同一块屏幕上，不在同一块时
这次拖拽会被拒绝并说明，鼠标一动不动。

这一族都只在面板显示「等待中」时才会动手。它在听你说话、在处理、在回复，或者光标正停在
菜单栏图标里，这次操作都会被拒绝，鼠标一动不动。关掉的「允许 Kiki 用鼠标操作」和没给的
辅助功能权限，同样拒绝。

破坏性的字眼（删除、卸载、格式化……）只拦点击：那类事按下去就收不回来。滚动和拖拽都不拦——
滚回去、拖回去就是了。

这一族的 stdout 上是 Kiki 对这一下的说法：「Kiki 正在看屏幕…」（只有 -t 那种要读屏幕的才有
这一行）和结果那句「已点击「确定」（第 1 个）。」。工具自己的毛病——参数写错、找不到 app、
连接断了、等超时——都走 stderr，所以管道里收到的只有 Kiki 的话。kiki command 不同：它的
stdout 是回复，连这句话也走 stderr。

退出码：0 做成了，1 没能做成，2 Kiki 说不行。成没成看这个数字，别去解析文字：
被拒绝时 stdout 上是 Kiki 拒绝的那句话（「「删除」这种字眼的东西 Kiki 不点，你自己来吧。」），
退出码是 2，脚本照旧分得清。

滚动、三击和拖拽还各多一条：正在运行的那个 Kiki 得认识这个手势。它不认识时会直接说明并以 2
退出，而不是把这次动作做成别的。刚重新构建完但没重启 app 时会碰上。-b 带小数（比如 0.5）也是
一样：只认整屏的旧 Kiki 读不懂这个数，与其让它一声不吭地等下去，不如这里直接说明并以 2 退出。
"""

/// How long to wait for the app to answer the first time, which on a cold launch includes
/// LaunchServices starting it, its own startup, and the TLS warmup handshake it does eagerly.
private let applicationStartupTimeoutSeconds: Double = 15

/// How long to wait between messages once a command is running. Generous, because the first
/// message arrives only after every screen has been captured and recognised.
private let replyEventTimeoutSeconds: Double = 120

// MARK: - Output

/// The reply so far, as last printed. Kept as the text itself rather than a length so that a
/// snapshot whose tail moved can be detected instead of printed as a suffix of the wrong string.
private var alreadyPrintedReplyText = ""

/// Something this tool is saying on its own behalf — a flag misspelled, no app found, a connection
/// that dropped, a wait that ran out. Never anything Kiki said; that goes to stdout.
private func reportProgress(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

/// A sentence the app sent, printed where a pipe can read it.
///
/// The eight gestures produce no reply, so their stdout is free to carry what Kiki says about the
/// action — 「已点击「确定」（第 1 个）。」 is the whole product of the command, and a script that
/// wants to know where the press landed has nowhere else to read it. The two kinds of sentence are
/// told apart by where they come from rather than by what they are: **only `event.message` may be
/// passed here**, which is why every call site is an `if let` and none of them has a fallback
/// string. A sentence written here would be this tool's, and every one of those goes to stderr.
///
/// `kiki command` is the exception, and only because its stdout is already spoken for: the reply
/// streams there, so a sentence arriving mid-reply would splice itself into the middle of it.
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
        // The tidy pass moved the tail rather than extending it, so a suffix of the new snapshot
        // is not the part that has not been seen. Start it on its own line instead of splicing.
        print()
        print(replyTextSoFar, terminator: "")
        fflush(stdout)
    }
    alreadyPrintedReplyText = replyTextSoFar
}

// MARK: - Finding and starting the app

/// The `Kiki.app` this tool belongs to.
private func locateKikiApplication() -> URL? {
    // Sibling of this executable: both products are built into the same `Build/Products/<config>/`.
    // Resolving symlinks first is required — being symlinked into `/usr/local/bin` is the normal
    // way this binary is put on `PATH`, and `argv[0]` is then the symlink's own directory.
    let executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let siblingApplicationURL = executableURL
        .deletingLastPathComponent()
        .appendingPathComponent("Kiki.app")
    if FileManager.default.fileExists(atPath: siblingApplicationURL.path) {
        return siblingApplicationURL
    }

    // Falls back to wherever LaunchServices knows the bundle from, for a Kiki.app that was copied
    // somewhere else after being built.
    return NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.smarty.kiki")
}

/// Starts the app through LaunchServices.
///
/// Through `open`, and never by running the executable: a process started from a terminal is
/// judged for permissions against the terminal, so TCC would report every grant as missing.
/// Without `-n`, an app that is already running is activated rather than started a second time —
/// which matters, because a second copy would be a second menu bar icon.
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

/// Reports a problem found before anything was asked of Kiki, and ends the process.
///
/// Fatal rather than returned, because every call site is a diagnosis made before the request goes
/// out: there is no answer in flight to collect and nothing to unwind. The outcomes decided *by*
/// the conversation are returned instead, so what a subcommand can exit with is in its signature.
private func fail(_ message: String, code: ExitCode) -> Never {
    reportProgress(message)
    exit(code.rawValue)
}

/// A command that could not be understood. The usage goes to the same stream as the complaint,
/// because a mistake in the arguments is exactly when the arguments are worth reading again.
private func failWithUsage(_ message: String) -> Never {
    reportProgress(message)
    reportProgress(usageText)
    exit(ExitCode.cannotRunCommand.rawValue)
}

// MARK: - kiki command

/// Hands a request to the app and streams the reply back.
///
/// Returns its exit code rather than ending the process with it: the entry point is the one place
/// the process ends, so what this command can exit with is the set of values it returns.
private func runCommandSubcommand(_ arguments: ArraySlice<String>) -> ExitCode {
    // Only the arguments *before* the request are read as flags, so a request that happens to
    // contain `--speak` is sent to Kiki as written rather than swallowed here.
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

    // Ctrl-C stops the turn rather than only stopping the watching: leaving Kiki reading a reply out
    // loud after the terminal has walked away is worse than not being able to interrupt at all.
    // On its own queue because the main thread is blocked reading the socket.
    let controlCSignalSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    controlCSignalSource.setEventHandler {
        client.send(.cancel)
        reportProgress("\n已取消。")
        exit(ExitCode.interruptedByControlC.rawValue)
    }
    controlCSignalSource.resume()
    signal(SIGINT, SIG_IGN)

    // The app announces itself before anything is asked of it, so this is where "Kiki is reachable
    // but cannot do this" is answered — before the command is sent, not after it fails.
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
                // Not "Kiki 退出了": a disconnect with no `superseded` before it is usually the app
                // going away, but it is also what the app does to a terminal that has stopped
                // reading — it hangs up on a short write. That the connection ended is the whole of
                // what this end can see.
                reportProgress("和 Kiki 的连接断了，这一轮没能跑完。")
                return .failed
            }
            reportProgress("等了 \(Int(replyEventTimeoutSeconds)) 秒也没等到 Kiki 的回复。")
            return .failed
        }

        switch event.type {
        case KikiCommandProtocol.MessageType.accepted:
            // Kiki's own sentence, but on this path even that goes to stderr: stdout here is the
            // reply, and the reply is still arriving.
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
            // Sent just before the app closes this connection to hand the turn to a newer one. The
            // hang-up that follows is not an error to report — it is the whole point of the message.
            reportProgress("另一个终端发了新需求，这一轮被它接过去了。")
            return .failed

        default:
            // `ready` can arrive twice when two connections overlap, and a newer app may send types
            // this build has never heard of. Neither is a reason to stop reading the reply.
            continue
        }
    }
}

// MARK: - kiki click

/// Turns the flags into what the app is asked for. Every way of getting them wrong is answered
/// here, so the app is only ever asked something that could be done.
///
/// Which flags are recognized follows from the gesture rather than from a parameter beside it: the
/// gesture already names the subcommand, and a second answer to that would be able to disagree with
/// the first. It is a whitelist rather than a set of flags to ignore because `-b` on a press, or
/// `--to-x` on a scroll, is a mistake in the arguments — a `kiki click -b 3` that quietly pressed
/// once would be answering a question nobody asked.
private func clickRequestFromArguments(
    _ arguments: ArraySlice<String>,
    gesture: String?
) -> KikiClickRequest {
    let isAScrollingGesture = gesture == KikiCommandProtocol.Gesture.scrollUp
        || gesture == KikiCommandProtocol.Gesture.scrollDown
        || gesture == KikiCommandProtocol.Gesture.scrollLeft
        || gesture == KikiCommandProtocol.Gesture.scrollRight
    let isADraggingGesture = gesture == KikiCommandProtocol.Gesture.drag

    var recognizedFlags = ["-x", "-y", "-t", "-n", "-s"]
    if isAScrollingGesture {
        recognizedFlags.append("-b")
    }
    if isADraggingGesture {
        recognizedFlags.append(contentsOf: ["--to-x", "--to-y"])
    }

    var valueByFlag: [String: String] = [:]
    var remainingArguments = arguments
    while let flag = remainingArguments.first {
        remainingArguments = remainingArguments.dropFirst()
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

    // A drag is refused without one, so this is asked of the arguments here rather than left to the
    // app: a request that names no destination is a mistake this end can describe better.
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
            dragToGlobalScreenY: dragDestinationGlobalScreenY
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
        dragToGlobalScreenY: dragDestinationGlobalScreenY
    )
}

/// The name of the gesture the running app does not know, or nil when it knows the one this
/// terminal is about to ask for.
///
/// An app that does not know a gesture does not necessarily refuse it. The three clicks the
/// `gesture` field was born with are answered correctly by every app that has the field at all,
/// however old; a gesture added afterwards is answered by an app that predates it as whatever its
/// own fallback says, and those fallbacks have not always been refusals. So each gesture added
/// after the field is announced in `ready` and asked about here, and the answer for a build that
/// does not announce it is "no" — which is what an absent field is saying.
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
        // The one gesture whose being unknown is not merely a different action: an app that predates
        // it decodes the destination fields and ignores them, so the drag would arrive as a press at
        // the starting point — and a press on a file selects it, on a folder opens it.
        return readinessEvent.understandsDragging == true ? nil : "拖拽"
    default:
        // A gesture this build of the tool does not know either, which the switch at the bottom of
        // this file cannot produce. Refusing is the only safe reading of a gesture nobody knows.
        return "这个手势"
    }
}

/// The distance the running app would be unable to read, or nil when it can read this one.
///
/// A separate question from `gestureTheRunningKikiDoesNotKnow`, because the fault is not the gesture
/// and the sentence is not the same: an app that scrolls at all reads the distance as a whole number,
/// and a fractional one makes the *whole request* undecodable — the app says nothing whatever, and
/// this end sits out its timeout, which is indistinguishable from Kiki having gone away. Only a
/// distance that is not whole is asked about, since such an app still reads `-b 3` correctly.
private func screenfulsTheRunningKikiCannotRead(
    _ clickRequest: KikiClickRequest,
    in readinessEvent: KikiCommandEvent
) -> Double? {
    guard let screenfuls = clickRequest.screenfuls, screenfuls != screenfuls.rounded() else {
        return nil
    }
    return readinessEvent.understandsFractionalScreenfuls == true ? nil : screenfuls
}

/// Asks the app to act where this terminal says, with the gesture the subcommand that got here
/// named, and reports what came of it. Everything else about the nine is the same.
private func runActionSubcommand(
    _ arguments: ArraySlice<String>,
    gesture: String?
) -> ExitCode {
    var clickRequest = clickRequestFromArguments(arguments, gesture: gesture)
    // The subcommand is the gesture rather than a flag: they go through one parser and meet the same
    // refusals, and the one thing that differs is what goes out at the point. Left nil for a plain
    // `click`, which keeps its request byte for byte what it was before the others existed.
    clickRequest.gesture = gesture

    guard let client = connectToKiki(applicationURL: locateKikiApplication()) else {
        return .cannotRunCommand
    }

    // Control+C is deliberately not intercepted. One of these takes a moment and there is nothing
    // to stop, while the thing `.cancel` stops is whichever turn is running — which, if the user is
    // mid-sentence at the keyboard, is not this terminal's turn to end.

    guard case .event(let readinessEvent) = client.readNextEvent(timeoutSeconds: applicationStartupTimeoutSeconds),
          readinessEvent.type == KikiCommandProtocol.MessageType.ready else {
        fail("Kiki 没有应答。它可能正在关闭，或者是不认识这条命令通道的旧构建。", code: .cannotRunCommand)
    }

    // Asked here, before anything is sent, because the app on the other end is not necessarily the
    // one this tool was built beside — rebuilding without restarting leaves an older Kiki listening,
    // and that is the ordinary case rather than the rare one.
    if let unknownGesture = gestureTheRunningKikiDoesNotKnow(
        clickRequest.gesture,
        in: readinessEvent
    ) {
        fail(
            "正在运行的这个 Kiki 是旧版本，还不认识\(unknownGesture)。把菜单栏里的 Kiki 退出再重新启动一次就能用。",
            code: .cannotRunCommand
        )
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

    // `canRunCommands` is deliberately not consulted. It answers whether a *request* can be run,
    // which needs an API key and screen recording; none of these actions needs either, and Kiki is
    // the one that knows whether it can make one right now — it says so in its reply.

    client.send(.click(clickRequest))

    while true {
        let readOutcome = client.readNextEvent(timeoutSeconds: replyEventTimeoutSeconds)
        guard case .event(let event) = readOutcome else {
            if case .disconnected = readOutcome {
                // See the command path: a disconnect is not proof that Kiki went away.
                reportProgress("和 Kiki 的连接断了，这次操作没做成。")
                return .failed
            }
            reportProgress("等了 \(Int(replyEventTimeoutSeconds)) 秒也没等到 Kiki 回话。")
            return .failed
        }

        switch event.type {
        case KikiCommandProtocol.MessageType.accepted:
            // Said by the app once the action is going ahead and the screens are about to be read —
            // the only slow part of this command. Never guessed at from here: every refusal that is
            // decidable without looking at the screen would otherwise be preceded by a promise that
            // Kiki is looking at one. Present only for a terminal that asked by text, because a
            // press by coordinate is answered in milliseconds and has no wait to be told about.
            if let message = event.message {
                printWhatKikiSaid(message)
            }

        case KikiCommandProtocol.MessageType.clicked:
            // A landed action with nothing to say about itself is a success with an empty stdout,
            // which the exit code already carries. No line is invented to fill the hole.
            if let message = event.message {
                printWhatKikiSaid(message)
            }
            return .success

        case KikiCommandProtocol.MessageType.failed:
            if let message = event.message {
                printWhatKikiSaid(message)
            } else {
                // A failure is never silent, and this one is the tool's to report: the app said
                // nothing, so there is nothing of Kiki's to print.
                reportProgress("Kiki 这一轮出错了。")
            }
            // A refusal means nothing was attempted and nothing on the machine has changed; a
            // failure means an event was meant to go out and did not. A script can act on those
            // differently, so they are different exit codes.
            return event.isRefusal == true ? .cannotRunCommand : .failed

        case KikiCommandProtocol.MessageType.superseded:
            reportProgress("另一个终端连上来了，这次操作没做成。")
            return .failed

        default:
            continue
        }
    }
}

// MARK: - Entry point

let arguments = Array(CommandLine.arguments.dropFirst())

guard let subcommand = arguments.first else { usageAndExit() }

// The only place a subcommand's code becomes a process exit. Ctrl-C has a call of its own, inside
// the signal handler, because that one does not run on this stack.
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
default:
    // Covers a subcommand that does not exist and, more usefully, one this tool is a version behind
    // on: the usage names every subcommand this build has.
    usageAndExit()
}
