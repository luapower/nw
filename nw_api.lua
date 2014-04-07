--native widgets api class. needs an impl instance to function.
local glue = require'glue'

local nw = {}

function nw:app()
	local app = glue.inherit({}, self.app_class)
	app.impl = self.impl:app()
	app._windows = {}
	return app
end

--app

local app = {}
nw.app_class = app

--start the main loop
function app:run()
	if self._running then return end --ignore if already running
	self._running = true
	self.impl:run()
	self._running = nil
end

--close all windows and quit the main loop; abort on the first window that refuses to close
function app:quit()
	for win in self:windows() do
		win:free()
		if not win:dead() then
			break
		end
	end
	self.impl:quit()
end

--monitors

function app:screen_rect()
	return self.impl:screen_rect()
end

function app:client_rect()
	return self.impl:client_rect()
end

--config

function app:time()
	return self.impl:time()
end

function app:timediff(start_time, end_time)
	return self.impl:timediff(start_time, end_time)
end

--windows

function app:window(t)
	local win = glue.inherit({app = self}, self.window_class)
	win.observers = {}
	win.mouse = {}
	win.keys = {}
	win._down = {}
	win.impl = self.impl:window{
		title = t.title,
		state = t.state,
		topmost = t.topmost,
		frame = t.frame,
		allow_minimize = t.allow_minimize,
		allow_maximize = t.allow_maximize,
		allow_close = t.allow_close,
		allow_resize = t.allow_resize,
		x = t.x,
		y = t.y,
		w = t.w,
		h = t.h,
		delegate = win,
	}
	self._windows[win] = true
	--TODO: self._winimpl[win.impl] = win
	if t.visible then
		win:show()
	end
	return win
end

function app:windows()
	return pairs(self._windows)
end

function app:closed(window) end

function app:active_window()
	return self._active_window
end

function app:active()
	return self.impl:active()
end

--window

local window = {}
app.window_class = window

--delegate

local _event = {}

function window:event(event, ...)
	if _event[event] then
		return _event[event](self, ...)
	else
		return self:_dispatch(event, ...)
	end
end

function window:_dispatch(event, ...)
	if self.observers[event] then
		for obs in pairs(self.observers[event]) do
			obs(event, ...)
		end
	end
	if self[event] then
		return self[event](self, ...)
	end
end

--lifetime

function window:free()
	if self:dead() then return end
	self.impl:free()
end

function window:dead()
	return self.app._windows[self] == nil
end

function window:closing() end --return false to prevent closing
function window:closed() end --right before freeing the children

function _event:closed()
	self:_dispatch'closed'
	self.app:closed(self)
	self.app._windows[self] = nil
	if not next(self.app._windows) then
		self.app:quit()
	end
end

--activation

function window:activate() self.impl:activate() end
function window:active() return self.impl:active() end --true|false

function window:activated() end
function window:deactivated() end

function _event:activated()
	self.app._active_window = self
	self:_dispatch'activated'
end

function _event:deactivated()
	self.app._active_window = nil
	self:_dispatch'deactivated'
end

--state

function window:show(state) --'maximized'|'minimized'|'normal'|'fullscreen'
	self.impl:show(state)
end

function window:hide() self.impl:hide() end
function window:visible() return self.impl:visible() end --true|false

function window:state(state) --'maximized'|'minimized'|'normal'|'fullscreen'
	if state then
		return self.impl:state() == state
	else
		return self.impl:state()
	end
end

function window:state_changed() end

--positioning

function window:frame_rect(x, y, w, h) --x, y, w, h
	return self.impl:frame_rect(x, y, w, h)
end

function window:client_rect() --x, y, w, h
	return self.impl:client_rect()
end

function window:frame_changing(how, x, y, w, h) end --move|left|right|top|bottom|topleft|topright|bottomleft|bottomright
function window:moved() end --also called when changing state
function window:resized() end --also called when changing state

--frame

function window:title(newtitle)
	return self.impl:title(newtitle)
end

--keyboard

function window:key(key) --down[, toggled]
	return self.impl:key(key)
end

function window:key_down(key) end
function window:key_up(key) end
function window:key_press(key) end
function window:key_char(char) end --sent after key_press for displayable characters

--mouse

function window:click_count(button)
	return self._down[button] and self._down[button].count or 0
end

function _event:mouse_down(button)
	self._down[button] = self._down[button] or {}
	local t = self._down[button]

	if self.app:timediff(t.time or 0) < self.app.impl:double_click_time() then
		t.count = (t.count or 1) + 1
	else
		t.count = 1
		--t.x = self:mouse_
	end
	t.time = self.app:time()

	self:_dispatch('mouse_down', button)

	if self:event('mouse_click', button, self:click_count(button)) then
		t.count = 0
	end
end

function window:mouse_move(x, y) end
function window:mouse_enter() end
function window:mouse_leave() end
function window:mouse_up(button) end
function window:mouse_down(button) end
function window:mouse_click(button, count) end
function window:mouse_wheel(delta) end
function window:mouse_hwheel(delta) end

--trackpad

--

--rendering

function window:invalidate()
	self.impl:invalidate()
end

function window:render() end

if not ... then require'nw_demo' end

return nw
