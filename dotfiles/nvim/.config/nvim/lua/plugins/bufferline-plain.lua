-- The buffer tabs drawn with glyphs one cell wide in every terminal. Nerd Font
-- icons and the ▎▏▕ block marks are private-use or ambiguous width: a terminal
-- (or font) that draws them two cells wide pushes the full-width tab bar past
-- the screen edge, and it wraps onto the lines below.
return {
	"akinsho/bufferline.nvim",
	opts = {
		options = {
			show_buffer_icons = false,
			show_buffer_close_icons = false,
			show_close_icon = false,
			modified_icon = "+",
			left_trunc_marker = "<",
			right_trunc_marker = ">",
			indicator = { style = "underline" },
			separator_style = { "|", "|" },
			diagnostics_indicator = function(_, _, diag)
				return vim.trim((diag.error and "E" .. diag.error .. " " or "") .. (diag.warning and "W" .. diag.warning or ""))
			end,
		},
	},
}
