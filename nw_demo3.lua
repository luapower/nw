local ffi = require'ffi'
local nw = require'nw'

local app = nw:app()

print('impl.double_click_time', app.impl:double_click_time())
print('impl.double_click_target_area', app.impl:double_click_target_area())

for display in app:displays() do
	print('screen_rect',  app:screen_rect(display))
	print('desktop_rect', app:desktop_rect(display))
end

local t = app:time()
print('app:time', t)
print('app:timediff', app:timediff(t))

local win = app:window{
						x = 100, y = 100, w = 800, h = 400,
						title = 'win',
						frame = 'normal',
						closeable = true,
						resizeable = true,
						minimizable = true,
						visible = true,
						maximized = false,
						minimized = false,
					}

local win2 = app:window{x = 200, y = 200, w = 600, h = 200, title = 'win2'}

assert(win:display() == win2:display())
assert(win:display() == app:main_display())

function win:closing()
	self:hide()
	win2:show()
	win2:activate()
	return false
end

function win:event(event, ...)
	print(event, ...)
	return app.window_class.event(self, event, ...)
end

function win2:closing()
	self:hide()
	win:show()
	self:activate()
	return false
end

app:run()
