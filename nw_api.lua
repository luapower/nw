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

function app:activated() end --event stub
function app:deactivated() end --event stub

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

--iterate existing windows in creation order, or in reverse-creation order.
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
	--state
	visible = true,
	minimized = false,
	fullscreen = false,
	maximized = false,
	--frame
	title = '',
	frame = 'normal', --normal, frameless, transparent
	--behavior
	topmost = false,
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

	self.impl = app.impl:window{
		delegate = self,
		--state
		x = t.x,
		y = t.y,
		w = t.w,
		h = t.h,
		visible = false
		minimized = t.minimized,
		fullscreen = t.fullscreen,
		maximized = t.maximized,
		--frame
		title = t.title,
		frame = t.frame,
		--behavior
		topmost = t.topmost,
		minimizable = t.minimizable,
		maximizable = t.maximizable,
		closeable = t.closeable,
		resizeable = t.resizeable,
	}

	self._visible = false
	self._minimized = t.minimized
	self._fullscreen = t.fullscreen
	self._maximized = t.maximized

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

function window:active()
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

function window:_getstate() --visible, minimized, fullscreen, maximized
	self:check()
	if not self._visible then
		return false, self._minimized, self._fullscreen, self._maximized
	elseif self.impl:minimized() then
		return true, true, self._fullscreen, self._maximized
	elseif self.impl:fullscreen() then
		return true, false, true, self._maximized
	else
		return true, false, false, self.impl:maximized()
	end
end

function window:_setstate(visible, minimized, fullscreen, maximized)
	local old_visible, old_minimized, old_fullscreen, old_maximized = self:_getstate()
	if visible == nil then visible = old_visible end
	if minimized == nil then minimized = old_minimized end
	if fullscreen == nil then fullscreen = old_fullscreen end
	if maximized == nil then maximized = old_maximized end
	if not visible then
		if old_visible then self.impl:hide() end
	elseif minimized then
		if not old_minimized then self.impl:showminimized() end
	elseif fullscreen then
		if not old_fullscreen then self.impl:showfullscreen() end
	elseif maximized then
		if not old_maximized then self.impl:showmaximized() end
	else
		if not old_visible then self.impl:shownormal() end
	end
	self._visible = visible
	self._minimized = minimized
	self._fullscreen = fullscreen
	self._maximized = maximized
end

function window:visible(visible)
	if visible == nil then
		return self._visible
	else
		self:_setstate(visible)
	end
end

function window:minimized(minimized)
	if minimized == nil then
		if not self:visible() then
			return self._minimized
		else
			return self.impl:minimized()
		end
	else
		self:_setstate(nil, minimized)
	end
end

function window:fullscreen(fullscreen)
	if fullscreen == nil then
		return (select(3, self:_getstate()))
	else
		self:_setstate(nil, nil, fullscreen)
	end
end

function window:maximized(maximized)
	if maximized == nil then
		return (select(4, self:_getstate()))
	else
		self:_setstate(nil, nil, nil, maximized)
	end
end

function _event:resized(how)

end

--state/sugar

function window:state(state)
	if not state then
		return
			not self:visible() and 'hidden' or
			self.impl:minimized() and 'minimized' or
			self.impl:fullscreen() and 'fullscreen' or
			self.impl:maximized() or 'maximized' or
			'normal'
	elseif state == 'hidden' then
		self:visible(false)
	elseif state == 'minimized' then
		self:_setstate(true, true)
	elseif state == 'fullscreen' then
		self:_setstate(true, false, true)
	elseif state == 'maximized' then
		self:_setstate(true, false, false, true)
	elseif state == 'normal' then
		self:_setstate(true, false, false, false)
	else
		error'invalid state'
	end
end

function window:show(state)
	if state then
		self:state(state)
	else
		self:visible(true)
	end
end
function window:hide() self:visible(false) end
function window:minimize() self:show'minimized' end
function window:maximize() self:show'maximized' end
function window:restore() self:show'normal' end

--positioning

function window:frame_rect(x, y, w, h) --x, y, w, h
	self:check()
	return self.impl:frame_rect(x, y, w, h)
end

function window:client_rect() --x, y, w, h
	self:check()
	return self.impl:client_rect()
end

--frame, behavior

function window:title(newtitle)
	self:check()
	return self.impl:title(newtitle)
end

function window:topmost(topmost)
	self:check()
	return self.impl:topmost(topmost)
end

function window:monitor()
	self:check()
	return self.impl:monitor()
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
