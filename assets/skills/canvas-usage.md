---
name: canvas-usage
priority: 12
---

[技能：HTML 画布使用]

你有一个全屏透明 HTML 画布可以用。它位于消息层下方作为背景。
每次视觉修改都通过 render_html 工具——不要只在第一次用！

## 画布用途

- 动态背景（渐变、粒子、星空、天气效果）
- 数据可视化（图表、统计卡片）
- 信息卡片（用户资料、任务进度、时间线）
- 装饰元素（边框、光晕、浮动图标）
- CSS 动画（呼吸、脉冲、滚动、闪烁）

## 关键规则

1. 每次想改背景/加视觉效果→调 render_html，不要写在聊天文字里
2. 短代码（<1500字符）→ html 参数直接传：render_html({html:"你的代码"})
3. 长代码（>1500字符）→ 先 write_file 再 render_html({file:"canvas/xxx.html"})
4. 画布背景是透明的，所以黑色/深色文字在暗色主题下看不见——用浅色文字或加半透明背景
5. 画布在消息层下方，不要画全屏不透明背景盖住消息
6. 画布内容重启后自动恢复（仅限 replace 模式的最后一次内容）

## 短代码示例

render_html({html:"<style>body{margin:0;overflow:hidden;background:linear-gradient(180deg,#1a1a2e,#16213e)}.rain{position:fixed;width:2px;height:20px;background:rgba(174,194,224,0.4);animation:fall linear infinite}@keyframes fall{0%{transform:translateY(-100px)}100%{transform:translateY(100vh)}}</style><div class='rain' style='left:10%;animation-duration:1.2s'></div>"})

标题卡片：
render_html({html:"<div style='position:fixed;top:20px;left:50%;transform:translateX(-50%);background:rgba(30,30,60,0.85);color:#e0e0ff;padding:12px 24px;border-radius:16px;font-size:18px;border:1px solid rgba(120,120,255,0.3)'>📊 今日数据概览</div>"})

## 长代码示例

先写文件：write_file({path:"canvas/galaxy.html", content:"<!DOCTYPE html>...很长的CSS动画代码..."})
然后渲染：render_html({file:"canvas/galaxy.html"})
