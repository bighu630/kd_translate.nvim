-- Luacheck 配置（`luacheck .` 会自动读取仓库根目录下的本文件）
--
-- Neovim 内置 LuaJIT，按 Lua 5.1 语义检查；`vim` 由 Neovim 注入到全局环境，
-- 必须显式声明，否则每个文件都会报 undefined global。
--
-- 这里不关闭任何 warning、不设置 ignore、不放宽 max_line_length：
-- 本批次只补齐工程化配置、不修改任何 Lua 源码，因此当前代码若被报出
-- warning，都属于真实问题，应当另行修复而不是在此处屏蔽。
std = "lua51" -- Neovim 使用 LuaJIT，语法/标准库等价于 Lua 5.1
globals = { "vim" } -- Neovim 运行时全局入口
