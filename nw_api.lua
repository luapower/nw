--native widgets api class. needs an impl instance to function.
local glue = require'glue'
local box2d = require'box2d'

local nw = {}

--return the singleton app object
function nw:app()
	self._app = self._app or self.app_class:new(self)
	return self._app
end

--app

local app = {}
nw.app_class = app

function app:new(nw)
	self = glue.inherit({}, self)
	self._windows = {} --{window1,...}
	self.impl = nw.impl:app()
	return self
end

--app main loop

--start the main loop. calling this while running is a no op.
function app:run()
	if self._running then return end --ignore if already running
	self._running = true
	self.impl:run()
	self._running = nil
end

--close all windows in reverse-creation order and quit the main loop; abort on the first window that refuses to close.
--spawning new windows on close is allowed and will result in the app not quitting.
function app:quit()
	for win in self:windows'reverse' do
		win:free()
		if not win:dead() then
			break
		end
	end
end

--monitors

function app:monitors()
	return self.impl:monitors()
end

function app:primary_monitor()
	return self.impl:primary_monitor()
end

function app:screen_rect(monitor)
	return self.impl:screen_rect(monitor)
end

function app:client_rect(monitor)
	return self.impl:client_rect(monitor)
end

function app:frames() --iter() -> x,y,w,h in z-order top-to-bottom
	return self.impl:frames()
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
	return self.window_class:new(self, t)
end

--iterate existing windows in creation order, or reverse-creation order.
--windows created while iterating won't be included in the iteration. windows freed won't be excluded.
function app:windows(reverse)
	local t = glue.extend({}, self._windows)
	local i, j = 0, 1
	if reverse then
		i, j = #self.windows + 1, -1
	end
	return function()
		i = i + j
		return t[i]
	end
end

function app:active_window()
	return self._active_window
end

function app:_add_window(win)
	table.insert(self._windows, win)
end

function app:_remove_window(target_win)
	for i, win in ipairs(self._windows) do
		if win == target_win then
			table.remove(self._windows, i)
			break
		end
	end
	if #self._windows == 0 then
		self.impl:quit()
	end
end

--window

local window = {}
app.window_class = window

window.defaults = {
	visible = true,
	title = '',
	state = 'normal',
	fullscreen = false,
	topmost = false,
	frame = true,
	transparent = false,
	minimizable = true,
	maximizable = true,
	closeable = true,
	resizeable = true,
}

function window:new(app, t)
	t = glue.update({}, self.defaults, t)
	local self = glue.inherit({app = app}, self)

	self.observers = {}
	self.mouse = {}
	self._down = {}
	self._frame = {
		frame = t.frame,
		transparent = t.transparent,
		minimizable = t.minimizable,
		maximizable = t.maximizable,
		closeable = t.closeable,
		resizeable = t.resizeable,
	}

	self.impl = app.impl:window{
		delegate = self,
		--state (read-write)
		x = t.x,
		y = t.y,
		w = t.w,
		h = t.h,
		title = t.title,
		state = t.state,
		fullscreen = t.fullscreen,
		topmost = t.topmost,
		--frame (read-only)
		frame = t.frame,
		transparent = t.transparent,
		minimizable = t.minimizable,
		maximizable = t.maximizable,
		closeable = t.closeable,
		resizeable = t.resizeable,
	}

	app:_add_window(self)

	if t.visible then
		self:show()
	end

	return self
end

--events

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
	if self.app[event] then --TODO: why in this order? why can't app respond to an event with a return value?
		self.app[event](self.app, self, ...)
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
	return self._dead
end

function window:check()
	assert(not self:dead(), 'dead window')
end

function _event:closed()
	self:_dispatch'closed'
	self._dead = true
	self.app:_remove_window(self)
end

--focus

function window:activate()
	self:check()
	self.impl:activate()
end

function window:active() --true|false
	self:check()
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
	self.impl:visible(true)
end

function window:hide()
	self.impl:visible(false)
end

function window:visible(visible) --true|false
	self:check()
	return self.impl:visible(visible)
end

function window:state(state) --'maximized'|'minimized'|'normal'
	self:check()
	return self.impl:state(state)
end

function window:topmost(topmost)
	self:check()
	return self.impl:topmost(topmost)
end

function window:fullscreen(fullscreen)
	self:check()
	return self.impl:fullscreen(fullscreen)
end

function window:frame_rect(x, y, w, h) --x, y, w, h
	self:check()
	return self.impl:frame_rect(x, y, w, h)
end

function window:client_rect() --x, y, w, h
	self:check()
	return self.impl:client_rect()
end

function window:title(newtitle)
	self:check()
	return self.impl:title(newtitle)
end

function window:monitor()
	self:check()
	return self.impl:monitor()
end

--get read-only frame properties
function window:frame(prop)
	self:check()
	return self._frame[prop]
end

--save a window's user-changeable state
function window:save()
	local x, y, w, h = self:frame_rect()
	local t = {x = x, y = y, w = w, h = h, state = self:state()}
	if t.state == self.defaults.state then
		t.state = nil
	end
	return t
end

--load a window's user-changeable state
function window:load(t)
	t = glue.update({}, self.defaults, t)
	if self:state() == 'normal' then --resize after state change to avoid flicker
		self:state(t.state)
		self:frame_rect(t.x, t.y, t.w, t.h)
	else --resize before state change to avoid flicker
		self:frame_rect(t.x, t.y, t.w, t.h)
		self:state(t.state)
	end
end

--keyboard

function window:key(key) --down[, toggled]
	self:check()
	return self.impl:key(key)
end

--mouse

function _event:mousedown(button)
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

	self:_dispatch('mousedown', button)

	if self:event('click', button, t.count) then
		t.count = 0
	end
end

--rendering

function window:invalidate()
	self:check()
	self.impl:invalidate()
end


if not ... then require'nw_demo' end

return nw
