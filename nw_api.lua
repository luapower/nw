--native widgets api class. needs an impl instance to function.
local glue = require'glue'
local box2d = require'box2d'

local nw = {}

function nw:app()
	if not self._app then
		self._app = glue.inherit({}, self.app_class)
		self._app.impl = self.impl:app()
		self._app._windows = {}
	end
	return self._app
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
--spawning new windows on close results in undefined behavior
function app:quit()
	for win in self:windows() do
		win:free()
		if not win:dead() then
			break
		end
	end
end

--monitors

function app:screen_rect()
	return self.impl:screen_rect()
end

function app:client_rect()
	return self.impl:client_rect()
end

--time

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
		x = t.x,
		y = t.y,
		w = t.w,
		h = t.h,
		title = t.title,
		state = t.state,
		topmost = t.topmost,
		frame = t.frame,
		allow_minimize = t.allow_minimize,
		allow_maximize = t.allow_maximize,
		allow_close = t.allow_close,
		allow_resize = t.allow_resize,
		delegate = win,
	}
	self._windows[win] = true
	if t.visible ~= false then
		win:show()
	end
	return win
end

function app:windows()
	return pairs(self._windows)
end

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
	if self.app[event] then
		return self.app[event](self.app, self, ...)
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

function _event:closed()
	self:_dispatch'closed'
	self.app._windows[self] = nil
	if not next(self.app._windows) then
		self.app.impl:quit()
	end
end

--focus

function window:activate()
	self.impl:activate()
end

function window:active() --true|false
	return self.impl:active()
end

function _event:activated()
	self.app._active_window = self
	self:_dispatch'activated'
end

function _event:deactivated()
	self.app._active_window = nil
	self:_dispatch'deactivated'
end

--state

function window:show(state)
	if state then
		self.impl:state(state)
	end
	self.impl:show()
end

function window:hide()
	self.impl:hide()
end

function window:visible() --true|false
	return self.impl:visible()
end

function window:state(state) --'maximized'|'minimized'|'normal'
	return self.impl:state(state)
end

function window:fullscreen(on)
	return self.impl:fullscreen(on)
end

function window:save()
	return self.impl:save()
end

function window:load(t)
	if not t.visible then
		self:hide()
		self:state(t.state)
	end
	self:frame_rect(t.x, t.y, t.w, t.h)
	self:title(t.title)
	self:frame('frame', t.frame)
	self:frame('topmost', t.topmost)
	self:frame('allow_minimize', t.allow_minimize)
	self:frame('allow_maximize', t.allow_maximize)
	self:frame('allow_close', t.allow_close)
	if t.visible then
		self:show(t.state)
	end
end

function window:normal_frame_rect(x, y, w, h) --x, y, w, h
	return self.impl:normal_frame_rect(x, y, w, h)
end

function window:frame_rect(x, y, w, h) --x, y, w, h
	return self.impl:frame_rect(x, y, w, h)
end

function window:client_rect() --x, y, w, h
	return self.impl:client_rect()
end

--frame

function window:title(newtitle)
	return self.impl:title(newtitle)
end

function window:frame(flag, value)
	return self.impl:frame(flag, value)
end

--keyboard

function window:key(key) --down[, toggled]
	return self.impl:key(key)
end

--mouse

function _event:mouse_down(button)
	local t = self._down[button]
	if not t then
		t = {count = 0}
		self._down[button] = t
	end

	if t.count > 0
		and self.app:timediff(t.time) < t.interval
		and box2d.hit(self.mouse.x, self.mouse.y, t.x, t.y, t.w, t.h)
	then
		t.count = t.count + 1
		t.time = self.app:time()
	else
		t.count = 1
		t.time = self.app:time()
		t.interval = self.app.impl:double_click_time()
		t.w, t.h = self.app.impl:double_click_target_area()
		t.x = self.mouse.x - t.w / 2
		t.y = self.mouse.y - t.h / 2
	end

	self:_dispatch('mouse_down', button)

	if self:event('mouse_click', button, t.count) then
		t.count = 0
	end
end

--trackpad

--

--rendering

function window:invalidate()
	self.impl:invalidate()
end


if not ... then require'nw_demo' end

return nw
