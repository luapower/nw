--[[
- function nw:app()
- function app:run(); ignored while running
function app:quit(); works from closed(), not from closing()
- function app:screen_rect()
- function app:client_rect()
- function app:window(t); x,y,w,h,title,visible,state=minimized,state=maximized
- function app:windows()
- function app:closed(window)
- function window:free()
- function window:dead()
- function window:closing()
- function window:closed()

- function window:activate()
- function window:active()
- function window:activated() end
- function window:deactivated() end
- function window:show(state)
- function window:hide()
- function window:visible()
- function window:state()
- function window:frame_changing(how, x, y, w, h) end --move|left|right|top|bottom|topleft|topright|bottomleft|bottomright
- function window:resized() end
- function window:moved() end
function window:state_changed() end
function window:frame_rect(x, y, w, h) return self.impl:frame_rect(x, y, w, h) end --x, y, w, h
function window:client_rect() return self.impl:client_rect() end --x, y, w, h

- function window:title(newtitle)

- function window:key_down(key) end
- function window:key_up(key) end
- function window:key_press(key) end
function window:key_char(char) end

function window:mouse_move(x, y) end
function window:mouse_over() end
function window:mouse_leave() end
function window:mouse_up(button) end
function window:mouse_down(button) end
function window:click(button) end
function window:double_click(button) end
function window:triple_click(button) end
function window:mouse_wheel(delta) end

function window:render() end
function window:invalidate() self.impl:invalidate() end
]]

local nw = require'nw'

local app = nw:app()

print('screen_rect', app:screen_rect())
print('client_rect', app:client_rect())

local win1 = app:window{x = 100, y = 100, w = 800, h = 400, title = 'win1', visible = false}
local win2 = app:window{x = 200, y = 200, w = 600, h = 200, title = 'win2', visible = false}

for win in app:windows() do
	win:title('[' .. win:title() .. ']')
	print('title', win:title())
end

function app:closed(win) print('closed', win:title()) end

function win1:closing() print'closing win1' end
function win2:closing() print'closing win2' end
function win1:closed() print'closed win1' end
function win2:closed() print'closed win2' end
function win1:activated() print'activated win1' end
function win2:activated() print'activated win2' end
function win2:frame_changing(how, x, y, w, h)
	if how == 'move' then
		x = math.min(math.max(x, 150), 250)
		y = math.min(math.max(y, 150), 250)
	end
	return x, y, w, h
end
function win1:moved() print'moved win1' end
function win2:moved() print'moved win2' end
function win1:resized() print'resized win1' end
function win2:resized() print'resized win2' end

local commands = {
	space = function()
		local state = win2:state()
		if win2:state'maximized' then
			win2:show'normal'
		elseif win2:state'normal' then
			win2:show'minimized'
		elseif win2:state'minimized' then
			win2:show'maximized'
		end
		print('state', state, '->', win2:state())
	end,
	esc = function()
		if win2:active() then
			win1:activate()
		elseif win1:active() then
			win2:activate()
		end
	end,
	H = function()
		if win2:visible() then
			win2:hide()
		else
			win2:show()
		end
	end,
	M = function()
		app:window{x = 200, y = 200, w = 200, h = 200, title = 'temp', visible = true, state = 'minimized'}
	end,
}

function win2:key_press(key)
	print('key_press', key)
end

function win2:key_down(key)
	print('key_down', key)
	if commands[key] then
		commands[key]()
	end
end

function win2:key_up(key)
	print('key_up', key)
end

win1.key_down = win2.key_down

win1:show()
win2:show()

app:run()

assert(win1:dead())
assert(win2:dead())

win1:free() --ignored
win2:free() --ignored
