local M = {}
local api = vim.api

-- 默认配置
M.config = {
	-- kd 调用超时时间（毫秒），0 或 nil 表示不限制
	timeout = 10000,
	-- 翻译命令配置
	window = {
		width = 80, -- 最大宽度
		height = 10, -- 最大高度
		border = "rounded", -- 边框样式
		title = " 翻译结果 ", -- 标题
		title_pos = "center", -- 标题位置
		style = "minimal", -- 窗口样式
		relative = "cursor", -- 窗口位置相对于光标
		focusable = true, -- 是否可以获得焦点
		row = 1, -- 相对于光标的垂直偏移
		col = 0, -- 相对于光标的水平偏移
	},
	keymap = {
		scrollDown = "<C-f>",
		scrollUp = "<C-b>",
	},
	-- 添加高亮组配置
	highlights = {
		word = {
			fg = "#FF0000", -- 前景色
			-- bg = "#FFFFFF",    -- 背景色
			bold = false, -- 是否粗体
			italic = false, -- 是否斜体
			underline = true, -- 是否下划线
		},
		phonetic = { -- 音标高亮
			fg = "#00FF00",
			bg = "NONE",
			bold = false,
			italic = true,
			underline = false,
		},
		level = {
			fg = "#FF0000",
			bg = "NONE",
			bold = false,
			italic = true,
			underline = false,
		},
	},
}
-- setup() 以默认配置为基准合并，保存一份深拷贝保证重复调用幂等
local default_config = vim.deepcopy(M.config)
local translate_cmd = "kd"

-- 添加一个全局变量来跟踪当前的翻译窗口
local current_window = nil

-- 在途请求：保存 SystemObj 以便取消，并用 request_id 作废过期回调
local in_flight = nil
local request_id = 0

-- 获取选中的文本
local function get_visual_selection()
	pcall(function()
		vim.cmd('silent! normal! gv"vy')
	end)

	local text = vim.fn.getreg("v")
	vim.fn.setreg("v", {}) -- 清空，避免污染

	if text and #text > 0 then
		return text
	else
		vim.notify("没有选中内容", vim.log.levels.WARN)
		return ""
	end
end

-- 将 set_highlights 定义为 M 的方法
function M.set_highlights()
	local highlights = M.config.highlights

	-- 设置单词高亮
	if highlights.word then
		local word_hl = "highlight kdWord"
		if highlights.word.fg then
			word_hl = word_hl .. " guifg=" .. highlights.word.fg
		end
		if highlights.word.bg then
			word_hl = word_hl .. " guibg=" .. highlights.word.bg
		end

		local gui = {}
		if highlights.word.bold then
			table.insert(gui, "bold")
		end
		if highlights.word.italic then
			table.insert(gui, "italic")
		end
		if highlights.word.underline then
			table.insert(gui, "underline")
		end

		if #gui > 0 then
			word_hl = word_hl .. " gui=" .. table.concat(gui, ",")
		end

		vim.cmd(word_hl)
	end

	-- 设置音标高亮
	if highlights.phonetic then
		local phonetic_hl = "highlight kdPhonetic"
		if highlights.phonetic.fg then
			phonetic_hl = phonetic_hl .. " guifg=" .. highlights.phonetic.fg
		end
		if highlights.phonetic.bg then
			phonetic_hl = phonetic_hl .. " guibg=" .. highlights.phonetic.bg
		end

		local gui = {}
		if highlights.phonetic.bold then
			table.insert(gui, "bold")
		end
		if highlights.phonetic.italic then
			table.insert(gui, "italic")
		end
		if highlights.phonetic.underline then
			table.insert(gui, "underline")
		end

		if #gui > 0 then
			phonetic_hl = phonetic_hl .. " gui=" .. table.concat(gui, ",")
		end

		vim.cmd(phonetic_hl)
	end

	-- 设置等级高亮
	if highlights.level then
		local level_hl = "highlight kdLevel"
		if highlights.level.fg then
			level_hl = level_hl .. " guifg=" .. highlights.level.fg
		end
		if highlights.level.bg then
			level_hl = level_hl .. " guibg=" .. highlights.level.bg
		end

		local gui = {}
		if highlights.level.bold then
			table.insert(gui, "bold")
		end
		if highlights.level.italic then
			table.insert(gui, "italic")
		end
		if highlights.level.underline then
			table.insert(gui, "underline")
		end

		if #gui > 0 then
			level_hl = level_hl .. " gui=" .. table.concat(gui, ",")
		end

		vim.cmd(level_hl)
	end
end

-- kd 的部分上游数据源会返回 HTML 实体（例如 &#x27;），统一解码后再显示
local HTML_ENTITIES = {
	amp = "&",
	lt = "<",
	gt = ">",
	quot = '"',
	apos = "'",
	nbsp = " ",
}

---解码字符串中的 HTML 实体（数字实体 + 常见命名实体）
---@param text string
---@return string
local function decode_entities(text)
	text = text:gsub("&#[xX](%x+);?", function(hex)
		local code = tonumber(hex, 16)
		return code and vim.fn.nr2char(code) or nil
	end)
	text = text:gsub("&#(%d+);?", function(dec)
		local code = tonumber(dec)
		return code and vim.fn.nr2char(code) or nil
	end)
	return (text:gsub("&(%a+);?", function(name)
		return HTML_ENTITIES[name]
	end))
end

---过滤掉 kd 输出中的无关提示行
---@param text string
---@return string[]
local function filter_lines(text)
	local lines = vim.split(text, "\n")
	local filtered = {}
	for _, line in ipairs(lines) do
		line = decode_entities(line)
		if not line:find("未找到守护进程") and not line:find("成功启动守护进程") then
			table.insert(filtered, line)
		end
	end
	return filtered
end

-- 内容极少时窗口也不低于此高度，避免浮窗过扁
local MIN_WINDOW_HEIGHT = 3

---估算文本在给定内容宽度下折行后占用的显示行数
---（考虑 CJK 等宽字符，与窗口的 wrap=true 配合）
---@param lines string[]
---@param width integer 窗口内容宽度（列）
---@return integer
local function wrapped_row_count(lines, width)
	local avail = math.max(1, width)
	local rows = 0
	for _, line in ipairs(lines) do
		rows = rows + math.max(1, math.ceil(vim.fn.strdisplaywidth(line) / avail))
	end
	return math.max(rows, 1)
end

---根据内容计算翻译浮窗尺寸（占位态与结果态共用）
---宽度：随内容收缩，不超过配置的上限，并以标题宽度兜底；
---高度：按折行后的显示行数自适应，夹在 [MIN_WINDOW_HEIGHT, 配置上限] 之间。
---@param lines string[] 待显示的文本行（已过滤）
---@return integer width
---@return integer height
local function compute_window_size(lines)
	local cfg = M.config.window
	local max_width = math.max(1, math.min(cfg.width, vim.o.columns - 4))
	local max_height = math.max(1, math.min(cfg.height, vim.o.lines - 4))

	local longest = 0
	for _, line in ipairs(lines) do
		longest = math.max(longest, vim.fn.strdisplaywidth(line))
	end
	-- 标题画在顶部边框上，宽度至少能容下标题
	local title_width = math.min(vim.fn.strdisplaywidth(cfg.title or ""), max_width)
	local width = math.max(1, math.min(max_width, math.max(longest, title_width)))

	local min_height = math.min(MIN_WINDOW_HEIGHT, max_height)
	local height = math.min(max_height, math.max(wrapped_row_count(lines, width), min_height))

	return width, height
end

---@class TranslateWindow
local TranslateWindow = {}
TranslateWindow.__index = TranslateWindow

---创建新的翻译窗口
---@param text string 要显示的文本内容
---@param loading? boolean 是否为加载态占位窗口
---@return TranslateWindow
function TranslateWindow.new(text, loading)
	local self = setmetatable({}, TranslateWindow)
	self.loading = loading or false

	-- 创建缓冲区
	self.bufnr = api.nvim_create_buf(false, true)
	local lines = filter_lines(text)
	api.nvim_buf_set_lines(self.bufnr, 0, -1, false, lines)
	-- 设置缓冲区选项
	vim.bo[self.bufnr].modifiable = false
	vim.bo[self.bufnr].filetype = "kd" -- 这会自动加载我们的语法文件
	vim.bo[self.bufnr].bufhidden = "wipe" -- 关窗时销毁缓冲区，顺带清理 buffer-local 键位/autocmd

	-- 确保语法高亮开启并应用自定义高亮
	vim.api.nvim_buf_call(self.bufnr, function()
		vim.cmd("syntax enable")
		M.set_highlights() -- 使用 M.set_highlights
	end)

	-- 计算窗口尺寸（宽高随内容自适应，占位态与结果态共用同一逻辑）
	local width, height = compute_window_size(lines)

	-- 设置窗口配置
	self.win_opts = vim.tbl_extend("force", M.config.window, {
		width = width,
		height = height,
		zindex = 100, -- enable zindex max than that on most common scenes.
	})

	-- 创建窗口
	self:open()

	-- 设置 autocmds
	self:setup_autocmds()

	-- 设置按键映射
	self:setup_keymaps()

	return self
end

function TranslateWindow:open()
	self.winid = api.nvim_open_win(self.bufnr, false, self.win_opts)
	vim.wo[self.winid].wrap = true
	-- 确保窗口中启用语法高亮
	vim.api.nvim_win_call(self.winid, function()
		vim.cmd("syntax enable")
	end)
end

---按当前缓冲区内容重新计算并应用窗口尺寸
function TranslateWindow:resize()
	if not self:is_valid() then
		return
	end
	local width, height = compute_window_size(api.nvim_buf_get_lines(self.bufnr, 0, -1, false))
	self.win_opts.width = width
	self.win_opts.height = height
	api.nvim_win_set_config(self.winid, { width = width, height = height })
end

---原地替换窗口内容（用于加载态占位窗转为最终结果）
---@param text string
function TranslateWindow:set_text(text)
	if not self:is_valid() then
		return
	end
	vim.bo[self.bufnr].modifiable = true
	api.nvim_buf_set_lines(self.bufnr, 0, -1, false, filter_lines(text))
	vim.bo[self.bufnr].modifiable = false
	self.loading = false
	-- 结果态尺寸可能与占位态不同，重新自适应
	self:resize()
end

---设置按键映射（仅作用于翻译结果窗口）
function TranslateWindow:setup_keymaps()
	local opts = { noremap = true, silent = true, buffer = self.bufnr }
	vim.keymap.set("n", "q", ":q<CR>", opts)
	vim.keymap.set("n", "<ESC>", ":q<CR>", opts)
	-- 滚动只在翻译结果窗口内生效，不再绑定到用户自己的 buffer
	-- 高度会随内容（占位态 → 结果态）变化，所以每次滚动时实时取窗口高度的一半
	local function scroll_by(direction)
		if api.nvim_win_is_valid(self.winid) then
			local scroll_lines = math.max(1, math.floor(api.nvim_win_get_height(self.winid) / 2))
			api.nvim_win_call(self.winid, function()
				vim.cmd("normal!" .. scroll_lines .. direction)
			end)
		end
	end
	vim.keymap.set("n", M.config.keymap.scrollDown, function()
		scroll_by("j")
	end, { noremap = true, silent = true, buffer = self.bufnr })
	vim.keymap.set("n", M.config.keymap.scrollUp, function()
		scroll_by("k")
	end, { noremap = true, silent = true, buffer = self.bufnr })
end

-- 设置 autocmds（用具名 augroup，反复翻译时不会累积）
function TranslateWindow:setup_autocmds()
	self.augroup = api.nvim_create_augroup("kd_translate_window", { clear = true })

	-- 退出 visual 选区等操作会在浮窗打开后补发一次 CursorMoved；
	-- 若此时直接关窗，会丢掉还没返回的结果（dismissed）。记录打开时的光标位置，
	-- 只有光标真的移动了才关窗。
	local origin = api.nvim_win_get_cursor(0)
	api.nvim_create_autocmd({ "CursorMoved" }, {
		group = self.augroup,
		buffer = api.nvim_get_current_buf(),
		callback = function()
			local cur = api.nvim_win_get_cursor(0)
			if cur[1] == origin[1] and cur[2] == origin[2] then
				return
			end
			self:close()
		end,
	})

	api.nvim_create_autocmd({ "WinLeave" }, {
		group = self.augroup,
		buffer = self.bufnr,
		callback = function()
			self:close()
		end,
	})
end

---检查窗口是否有效
---@return boolean
function TranslateWindow:is_valid()
	return self.winid ~= nil and api.nvim_win_is_valid(self.winid)
end

---关闭窗口
function TranslateWindow:close()
	if self:is_valid() then
		api.nvim_win_close(self.winid, true)
	end
	if self.augroup then
		-- 清理本窗口注册的 autocmd，避免关窗后残留
		pcall(api.nvim_clear_autocmds, { group = self.augroup })
		self.augroup = nil
	end
	if current_window == self then
		current_window = nil
	end
end

local function clean_links(text)
	-- Step 1: 移除 Markdown 反引号代码块
	text = text:gsub("`([^`]+)`", "%1") -- 移除行内反引代码（如 `Command` → Command）
	text = text:gsub("```.-```", "") -- 移除多行代码块（如 ```rust...```）

	-- Step 2: 原有的链接和 Markdown 链接清理
	text = text:gsub("%[([^%[%]]+)%]%(%S+%)", "%1")
	text = text:gsub("!%[([^%[%]]+)%]%(%S+%)", "%1")
	text = text:gsub("%[.-%]:%s*%S+", "")
	text = text:gsub("%f[%w](%a+://%S+)", "")
	text = text:gsub("%f[%w](www%.[%w-]+%.%S+)", "")
	text = text:gsub("%*%*([^%*]+)%*%*", "%1") -- **粗体** → 粗体
	text = text:gsub("%*([^%*]+)%*", "%1") -- *斜体* → 斜体

	text = text:gsub("%s+", " ")
	-- 🔥 新增：移除末尾部分标点符号
	text = text:gsub("[:.,%s]+$", "")
	-- kd 的输入校验只接受字母/数字/CJK 作为首字符；把开头的其它字符
	-- （Markdown 列表符、Lua 注释 "--"、前导标点等）都截掉，从第一个
	-- kd 能接受的字符开始，否则整句会被 kd 直接拒掉。
	local first = text:find("[%w\xE4-\xE9]")
	if first and first > 1 then
		text = text:sub(first)
	end
	return text
end

---取消当前在途的翻译请求（若有）
local function cancel_in_flight()
	if in_flight then
		pcall(function()
			in_flight:kill(15)
		end)
		in_flight = nil
	end
end

---检测 kd 可执行文件是否可用
---@return boolean
local function has_backend()
	if vim.fn.executable(translate_cmd) == 1 then
		return true
	end
	vim.notify(
		string.format(
			"未找到 %s 可执行文件，请先安装并配置 kd：https://github.com/Karmenzind/kd",
			translate_cmd
		),
		vim.log.levels.ERROR
	)
	return false
end

-- 修改翻译函数
function M.translate(mode)
	-- 如果存在旧窗口，先关闭它
	if current_window and current_window:is_valid() then
		current_window:close()
	end

	local text

	if mode ~= "v" and mode ~= "V" and mode ~= "\x16" then
		text = vim.fn.expand("<cword>") -- 如果不在可视模式，返回光标下的词
	else
		text = get_visual_selection()
	end

	-- 去除首尾空格后检查是否包含内部空格（多个单词）
	local trimmed_text = text:match("^%s*(.-)%s*$") -- 去除首尾空格
	trimmed_text = clean_links(trimmed_text)
	-- vim.inspect(print(trimmed_text))
	-- 取消旧的在途请求并作废其结果，避免竞态（即使本次后端缺失也要作废旧请求）
	cancel_in_flight()
	request_id = request_id + 1
	local this_id = request_id

	-- 后端缺失检测：缺失时给出可操作提示，而不是底层 spawn 错误
	if not has_backend() then
		return
	end

	local cmd = { translate_cmd }
	-- 检查是否包含中文字符或内部空格
	if trimmed_text and trimmed_text:find("[\xE4-\xE9][\x80-\xBF][\x80-\xBF]") or trimmed_text:find("%s+") then
		-- print("here")
		table.insert(cmd, "-t")
	end
	-- 用 `--` 终止 flag 解析：查询文本可能以 `-` 开头（如 Markdown 列表项 "- foo"、"-x"、"--help"），
	-- 否则 kd 的 Go flag 解析器会把它当作未知 flag（flag provided but not defined）
	table.insert(cmd, "--")
	table.insert(cmd, trimmed_text)

	-- vim.notify(vim.inspect(cmd))

	-- 超时配置：0 或 nil 表示不限制
	local effective_timeout = M.config.timeout
	local system_opts = { text = true }
	if effective_timeout and effective_timeout > 0 then
		system_opts.timeout = effective_timeout
	else
		effective_timeout = nil
	end

	-- 立即显示加载态占位窗口，结果返回后原地替换
	current_window = TranslateWindow.new("翻译中…", true)

	local ok, proc = pcall(vim.system, cmd, system_opts, function(obj)
		vim.schedule(function()
			-- 过期回调（已被更新的请求取消/作废）直接丢弃
			if this_id ~= request_id then
				return
			end
			in_flight = nil

			local win = current_window
			-- 占位窗口已被用户关闭（移动光标/离开）= 放弃本次查询
			local dismissed = not (win and win:is_valid())

			if obj.code == 0 then
				-- kd 可能以退出码 0 把提示/错误写在 stderr（例如查询被它的输入校验拒绝），
				-- 此时 stdout 为空，只渲染 stdout 会得到一个空白浮窗；回退到 stderr。
				local output = obj.stdout
				if not output or output:match("^%s*$") then
					output = obj.stderr
				end
				if not dismissed then
					if output and output:match("%S") then
						win:set_text(output)
					else
						win:close()
						vim.notify("kd 没有返回任何内容", vim.log.levels.WARN)
					end
				end
			elseif effective_timeout and obj.code == 124 then
				-- 超时：vim.system 超时后以 TERM 终止进程并返回退出码 124
				if not dismissed then
					win:close()
				end
				vim.notify(
					string.format("kd 翻译超时（%d ms），请检查网络或后端", effective_timeout),
					vim.log.levels.WARN
				)
			else
				if not dismissed then
					win:close()
				end
				vim.notify("翻译失败: " .. (obj.stderr or "未知错误"), vim.log.levels.ERROR)
			end
		end)
	end)

	if not ok then
		-- vim.system 自身报错（如可执行文件在检测后被移除），兜底提示
		request_id = request_id + 1
		in_flight = nil
		if current_window and current_window:is_valid() then
			current_window:close()
		end
		vim.notify("翻译失败: " .. tostring(proc), vim.log.levels.ERROR)
		return
	end

	in_flight = proc
end

function M._translate(mode)
	-- 加载中的占位窗口不接管焦点；再次触发则表示发起新的翻译
	if current_window and current_window:is_valid() and not current_window.loading then
		-- when twice pressed the key, enter the window
		-- enter the window
		api.nvim_set_current_win(current_window.winid)
	else
		M.translate(mode)
	end
end
-- 修改 setup 函数
function M.setup(opts)
	M.config = vim.tbl_deep_extend("force", vim.deepcopy(default_config), opts or {})
	-- 初始设置高亮
	M.set_highlights()
end

return M
