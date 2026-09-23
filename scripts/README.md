# Scripts

Three standalone probes. None is part of the app target; all are compiled directly with
`swiftc` and are run by hand when a question needs measuring rather than arguing about.

| 脚本 | 量什么 |
|---|---|
| `pointing-calibration.swift` | 模型从图里读坐标的误差有多大 |
| `click-injection-check.swift` | 各种点击注入方式对用户指针做了什么 |
| `scroll-injection-check.swift` | 合成的滚轮事件落到哪个窗口、哪个符号是往下 |

## `pointing-calibration.swift` — Measure how accurately the model reads coordinates

The cursor lands wherever DeepSeek said the element was, so any error in the model's
reading is felt as "the cursor is pointing at the wrong spot". This measures that error:
it renders a 1280×800 screenshot with nine lettered tiles at known pixel positions, sends
it with the same image label, coordinate convention and pointing instructions the app
uses, and matches each `[POINT:…]` tag back to its tile.

```bash
swiftc -O scripts/pointing-calibration.swift -o /tmp/pointing-calibration
/tmp/pointing-calibration              # --render-only to just write the test image
/tmp/pointing-calibration --realistic  # ask about real widgets instead of lettered tiles
```

It prints a per-tile table of true vs. reported coordinates, then fits
`reported = scale × true + offset` per axis. That fit is the point: a scale near 1 means
the error is unbiased estimation noise, which no formula can correct — the fix would be
snapping to the real element; a scale consistently off means DeepSeek is downscaling the
image internally, which one multiplication corrects.

### The two modes answer different questions

The default mode asks the model to read back a coordinate it was *told* — "九个方块…x,y
是方块中心" — so it measures the noise floor of the reading and nothing else. Measured on
`deepseek-flash`: **scale 0.9983 / 1.0000, RMS 1.3 px, worst 2.0 px.** The reading is
essentially exact, and there is no internal downscaling to compensate for.

That is not the same question as "does the model point at the right place when it has to
decide where the element is". `--realistic` closes the gap by rendering a mock macOS
window with four widgets at known rectangles — a search field, a button, a settings row,
a sidebar — and asking about each one in the plain language a user would use, with no
coordinate hint.

What that mode showed, and why it matters: the model lands inside every widget. On
widgets that *are* one compact visual object it points at the centre (搜索框 +1.1 pt,
分享按钮 +2.2 pt). On large containers it points at the recognizable part inside them —
for the settings row it reported `(191,249)` against a row centre of `(250,248)`, the
centre of the 设置 *text* rather than the row. That is correct pointing rather than error,
but it means "the model points at the element's centre" is not a safe assumption for a
container.

The API key is read from `DEEPSEEK_API_KEY` or from the same Keychain item the app uses,
so macOS will ask for permission the first time — "Always Allow" keeps it to one prompt.

The pointing instructions are copied verbatim from `CompanionManager.swift` and have to
be re-copied if that prompt changes, or the numbers describe a prompt the app no longer
sends.

## `click-injection-check.swift` — Measure what each way of injecting a click does to the pointer

`ElementClicker` posts its events at `.cghidEventTap`, and the claim that this leaves the
pointer alone — "the click lands where the event says, not where the mouse is standing" —
is what is under test. `CGEventCreateMouseEvent`'s `mouseCursorPosition` argument *is* the
cursor position, the same field the system reads to say where the mouse is, so an event
injected at the HID layer plausibly relocates the pointer, and the only way to know is to
watch it.

```bash
swiftc -O scripts/click-injection-check.swift -o /tmp/click-injection-check
/tmp/click-injection-check
/tmp/click-injection-check --repetitions 8
/tmp/click-injection-check --only cghidEventTap
```

It puts a target window of its own at a known rectangle, parks the cursor far away from
it, and then, for each injection method, posts a click at the target's centre while a
background timer samples the cursor position every millisecond. Two questions are
answered separately, because they can disagree and the disagreement is the whole finding:

- **did the pointer move, and for how long** — from the cursor samples
- **did the target receive the click, and at what point** — from the view's `mouseDown`
  and `mouseUp`

Five methods are compared, all posting the same click at the same point:
`cghidEventTap`, `cgSessionEventTap`, `cgAnnotatedSessionEventTap`, `CGEventPostToPid`,
and `cghidEventTap+warpBack` — the last being the HID post with the cursor warped back
afterwards, which is the shape `PointerCarrier` uses.

**What it measures is a candidate, not an answer.** It cannot test whether a third-party
app that hit-tests against the physical pointer rather than against the event would accept
a delivery method that leaves the pointer alone; that has to be checked by hand in the
app, against a real `[CLICK:…]`.

Nothing here is Kiki's own code — the file does not import or depend on the app, so there
is no copy to keep in sync. Accessibility permission is required to post events at all,
and it is judged against the process responsible for this one: running from a terminal
means the **terminal** needs the grant, not this binary.

## `scroll-injection-check.swift` — Measure where a synthesized scroll lands, and which sign means which direction

A click carries its own point, and this project relies on that. A wheel event is not
documented to, and the answer decides whether Kiki's cursor can scroll an element on its
own or has to drag the user's pointer there first — one boolean in the shipping code,
`ElementActionOnArrival.carriesTheUsersPointer`, and not one to guess at.

```bash
swiftc -O scripts/scroll-injection-check.swift -o /tmp/scroll-injection-check
/tmp/scroll-injection-check
```

Three windows of its own, each with one job. Two plain ones record every `scrollWheel:`
they are handed while the pointer is parked over one and the event's point names the
other, so "where did it land" is answered by the receiving side. The third holds a real
`NSScrollView` over a flipped oversized document, which is the ground truth for direction:
down is defined by the document moving the way a person expects, not by a sign guessed at
from a header. Every direction is measured from the middle of the document, so neither
answer can be a clamp.

**Measured:** the point on the event decides which window receives the scroll, so a scroll
is aimed at the element the same way a click is. But posting one also *drags the pointer to
that point*, on `.cghidEventTap` and `.cgSessionEventTap` alike — and `.cgAnnotatedSessionEventTap`
delivers nothing at all. A scroll therefore cannot land somewhere with the pointer staying
where it was, which is why the carry is kept for a scroll as well: the pointer moves either
way, and the choice is between carrying it legibly and letting it teleport. For direction,
`.pixel` units move the document by exactly the points sent with no scaling in between, and
a negative `wheel1` moves it down — the sign convention `wheelDeltas` carries in its comment.

Nothing here is Kiki's own code; the file does not import or depend on the app. The deltas
it posts are shaped the way `ElementScroller.wheelDeltas` shapes them, so the numbers
transfer directly — but they are copies, and a copy goes stale. Accessibility permission is
required to post events at all, and it is judged against the process responsible for this
one: running from a terminal means the **terminal** needs the grant, not this binary.

## Removed

`streaming-segmenter-check.swift` and `thinking-cost-measurement.swift` were deleted along
with the app's two diagnostic scaffolds. The first was the prefix-stability harness — it
ran the app's own tidy passes, tag parser and sentence scan over every recorded reply at
five chunk sizes and required cut-as-arrives to equal cut-once-in-full; the property it
checked is still load-bearing and is now **unguarded**, which `AGENTS.md` says under "The
streaming reply". The second measured what `deepseek-flash`'s chain of thought costs, and
what turning it off costs in pointing accuracy; neither is measured any more.
