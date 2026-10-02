# 更新日志

格式遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号遵循[语义化版本](https://semver.org/lang/zh-CN/)。

## [Unreleased]

## [1.0.0] - 2026-10-02

首个公开版本。

### 新增

- 按住 **Control+Option** 说话：端上转写，DeepSeek 的回答一边写一边念出来，紫色光标飞到答案说到的那个东西上指给你看
- 光标真的动手：单击、双击、三击、右键、四个方向的滚动、拖拽——按下去之前先变红、把你的指针一起带过去
- 一轮回复可以自己接着走：做完一步重看一眼屏幕再决定下一步，最多二十步；上下文快满时自己把前面的步骤收成摘要
- **Shift+Option** 录下你自己的鼠标动作，再按一下开始循环重放，第三次停下并忘掉
- `kiki command`：同一条流水线的终端入口，回复流回终端，默认不出声
- `kiki click`、`doubleclick`、`tripleclick`、`rightclick`、`scrollup`、`scrolldown`、`scrollleft`、`scrollright`、`drag`、`type`、`key`：十一条不问模型、不出声的手势，给脚本和快捷键用
- `kiki screenshot`、`kiki locate`：两条只读屏幕的命令，什么也不动
- 该不动的时候不动：读起来像「删除」「卸载」「格式化」的东西不点，权限没给不动，⌘⇧⌫ 这类清空废纸篓的组合键从不按
