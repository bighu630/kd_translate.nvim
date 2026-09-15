# 介绍

一个轻量的 Neovim 查词 / 翻译插件。

![pic](./src/1734583312.png)

插件自身不提供翻译能力：它把光标下的单词或可视选区交给外部命令行工具 `kd` 执行，再把返回的文本渲染到浮窗中。使用的后端来自 [kd](https://github.com/Karmenzind/kd)。

## 系统要求

- Neovim >= 0.10（依赖 `vim.system`）
- [kd](https://github.com/Karmenzind/kd) CLI

> **注意**：`kd` 是强依赖。必须先安装并配置好 `kd`，否则插件完全不可用。

## 使用 lazy 配置：

```lua
return {
    "SilverofLight/kd_translate.nvim",
    config = function()
        require("kd").setup({
            window = {
                -- your window config here
            },
        })
    end,
    keys = {
        { "<leader>t", ":TranslateNormal<CR>", mode = "n", desc = "翻译光标下的单词" },
        { "<leader>t", ":TranslateVisual<CR>", mode = "v", desc = "翻译可视选区" },
    },
}
```

## 默认的配置项：

```lua
-- 默认配置
M.config = {
    window = {
        width = 80,          -- 最大宽度
        height = 10,         -- 最大高度
        border = "rounded",  -- 边框样式
        title = " 翻译结果 ", -- 标题
        title_pos = "center", -- 标题位置
        style = "minimal",   -- 窗口样式
        relative = "cursor", -- 窗口位置相对于光标
        focusable = true,    -- 是否可以获得焦点
        row = 1,             -- 相对于光标的垂直偏移
        col = 0,             -- 相对于光标的水平偏移
    },
    keymap = {
        -- 仅在翻译结果窗口内生效
        scrollDown = "<C-f>",
        scrollUp = "<C-b>",
    },
    -- 添加了高亮组
    highlights = {
        word = {              -- 单词高亮
            fg = "#FF0000",   -- 前景色
            -- bg = "#FFFFFF", -- 背景色
            bold = false,     -- 是否粗体
            italic = false,   -- 是否斜体
            underline = true, -- 是否下划线
        },
        phonetic = {          -- 音标高亮
            fg = "#00FF00",
            bg = "NONE",
            bold = false,
            italic = true,
            underline = false,
        },
        level = {             -- 等级高亮
            fg = "#FF0000",
            bg = "NONE",
            bold = false,
            italic = true,
            underline = false,
        },
    },
}
```

`setup()` 可以重复调用：每次都以默认配置为基准合并传入的 `opts`。
