local nw = require'nw'

local app = nw:app()

local win = app:window{x = 100, y = 100, w = 800, h = 400, title = 'win',
								transparent = false, frame = false, allow_resize = true}

function win:event(event, ...)
	print(event, ...)
	return app.window_class.event(self, event, ...)
end

function win:render(cr)
	local w, h = select(3, self:frame_rect())
	cr:rectangle(0, 0, w, h)
	cr:set_source_rgba(1, 1, 1, 0.5)
	cr:set_line_width(10)
	cr:stroke()
	cr:rectangle(150, 150, 100, 100)
	cr:set_source_rgba(1, 0, 0, 0.5)
	cr:fill()
end

win:invalidate()

function win:keypress(key)
	--
end

function win:leave()

end

function win:click()

end

app:run()
