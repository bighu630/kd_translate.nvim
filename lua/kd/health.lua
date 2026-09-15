local M = {}

function M.check()
	local health = vim.health or require("vim.health")
	health.start("kd")

	-- 插件依赖 vim.system（Neovim 0.10+）
	if vim.fn.has("nvim-0.10") == 1 then
		health.ok("Neovim >= 0.10（vim.system 可用）")
	else
		health.error("需要 Neovim >= 0.10（插件依赖 vim.system）")
	end

	-- 当前配置
	local ok, kd = pcall(require, "kd")
	if ok then
		local timeout = kd.config and kd.config.timeout
		health.info(string.format("翻译超时: %s", (timeout and timeout > 0) and (timeout .. " ms") or "不限制"))
	else
		health.warn("无法加载 kd 模块: " .. tostring(kd))
	end

	-- kd 可执行文件（强依赖）
	local exe = vim.fn.exepath("kd")
	if exe == "" then
		health.error("未在 PATH 中找到 kd 可执行文件", {
			"安装 kd: https://github.com/Karmenzind/kd",
			"安装后确认 `kd --version` 可正常运行",
		})
		return
	end
	health.ok("kd 可执行文件: " .. exe)

	local ok_ver, result = pcall(function()
		return vim.system({ "kd", "--version" }, { text = true, timeout = 5000 }):wait()
	end)
	if not ok_ver then
		health.warn("无法执行 `kd --version`: " .. tostring(result))
		return
	end
	if result.code == 0 then
		local version = vim.trim(result.stdout or "")
		if version ~= "" then
			health.ok("kd 版本: " .. version)
		end
	else
		health.warn(string.format("`kd --version` 退出码 %d: %s", result.code, vim.trim(result.stderr or "")))
	end
end

return M
