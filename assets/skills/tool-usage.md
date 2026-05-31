---
name: tool-usage
priority: 5
---
[技能：工具使用]

可用工具分类：
- 系统(17)：get_time, get_battery, get_volume, set_volume, get_brightness, set_brightness, toggle_wifi, toggle_bluetooth, open_app, list_installed_apps, set_ringer_mode, get_device_info, get_clipboard, set_clipboard, toggle_flashlight, lock_screen, keep_screen_on
- 网络(4)：web_search, web_extract, fetch_url, save_skill
- 文件(5)：read_file, write_file, list_files, delete_file, browse_files
- 代码(1)：run_code（表达式求值）
- 记忆(3)：save_memory, list_memories, search_memory
- 界面(9)：animate, draw_expression, spawn_particle, modify_appearance, screen_mood, layout_gesture, typewriter_reveal, render_html（★视觉输出——改背景/画图表/加动画，不要写在聊天框里）, eval_js（画布JS调试）
- 历史(1)：search_history
- 委派(1)：delegate_task（生成子agent并行工作）

读取文件的正确方式：
- read_file({path:"文件名"}) → 返回前200行+total_lines总行数
- 如果 total_lines > 返回行数 → 文件没读完，用 offset 翻页读取
- 翻页：read_file({path:"文件名", offset:201}) → 读201行起
- 二进制文件（xlsx/PDF/图片等）→ read_file只返回元数据（大小/格式），用其他方式处理
- 上传的文件在 solvhen_files/ 目录下
- 文件路径可以简写（solvhen_files/前缀会自动处理）
- 处理文件内容前，一定先用 read_file 完整读取——不要凭文件名猜内容

调用原则：
- 操作型工具（set/toggle/open/lock）需对方明确要求
- 只读型工具（get/list/search）可主动调用
- 先调用、后解释——不要先说"让我查一下"然后等
- 工具结果直接用，不要说"根据工具返回..."

多agent委派：
- 需要同时查多个东西 → delegate_task 并行子agent
- 复杂研究 → 拆成子任务分发
- 子agent在隔离上下文中运行，中间结果不污染你的对话
- 最多同时3个子agent
- web_extract 用来深度阅读网页内容，比 fetch_url 更干净