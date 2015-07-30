
--native widgets - Xlib backend.
--Written by Cosmin Apreutesei. Public domain.

if not ... then require'nw_test'; return end

local ffi = require'ffi'
local bit = require'bit'
local glue = require'glue'
local box2d = require'box2d'
local xlib = require'xlib'
require'xlib_keysym_h'
require'xlib_xshm_h'
local time = require'time' --for timers
local heap = require'heap' --for timers
local pp = require'pp'
local cast = ffi.cast
local free = glue.free
local xid = xlib.xid
local C = xlib.C

local nw = {name = 'xlib'}

--os version -----------------------------------------------------------------

function nw:os(ver)
	return 'Linux 11.0' --11.0 is the X version
end

nw.min_os = 'Linux 11.0'

--app object -----------------------------------------------------------------

local app = {}
nw.app = app

function app:new(frontend)
	self   = glue.inherit({frontend = frontend}, self)
	xlib   = xlib.connect()
	self:_resolve_evprop_names()
	return self
end

function app:virtual_roots()
	return get_window_list_prop(xlib.screen.root, '_NET_VIRTUAL_ROOTS')
end

--event debugging ------------------------------------------------------------

local etypes = glue.index{
	KeyPress             = 2,
	KeyRelease           = 3,
	ButtonPress          = 4,
	ButtonRelease        = 5,
	MotionNotify         = 6,
	EnterNotify          = 7,
	LeaveNotify          = 8,
	FocusIn              = 9,
	FocusOut             = 10,
	KeymapNotify         = 11,
	Expose               = 12,
	GraphicsExpose       = 13,
	NoExpose             = 14,
	VisibilityNotify     = 15,
	CreateNotify         = 16,
	DestroyNotify        = 17,
	UnmapNotify          = 18,
	MapNotify            = 19,
	MapRequest           = 20,
	ReparentNotify       = 21,
	ConfigureNotify      = 22,
	ConfigureRequest     = 23,
	GravityNotify        = 24,
	ResizeRequest        = 25,
	CirculateNotify      = 26,
	CirculateRequest     = 27,
	PropertyNotify       = 28,
	SelectionClear       = 29,
	SelectionRequest     = 30,
	SelectionNotify      = 31,
	ColormapNotify       = 32,
	ClientMessage        = 33,
	MappingNotify        = 34,
	GenericEvent         = 35,
}
local t0
local function evstr(e)
	t0 = t0 or time.clock()
	local t1 = time.clock()
	local s = '   '..('.'):rep((t1 - t0) * 20)..' EVENT'
	t0 = t1
	s = s..' '..(etypes[e.type] or e.type)
	if e.type == C.PropertyNotify then
		s = s..': '..xlib.atom_name(e.xproperty.atom)
	end
	return s
end

--message loop ---------------------------------------------------------------

local ev = {}     --{event_code = event_handler}
local evprop = {} --{property_name = PropertyNotify_handler}

function app:_resolve_evprop_names()
	for name, handler in pairs(evprop) do
		local atom = xlib.atom(name)
		if atom then
			evprop[atom] = handler
		end
	end
end

local function pull_event(timeout)
	local e = xlib.poll(timeout)
	if not e then return end
	--print(evstr(e))
	local f = ev[tonumber(e.type)]
	if f then f(e) end --after this, e is invalid because f() can cause re-entering.
	return true
end

function app:run()
	while not self._stop do
		local timeout = self:_pull_timers()
		if self._stop then --stop() called from timer
			while pull_event() do end --empty the queue
			break
		end
		pull_event(timeout)
	end
	self._stop = false
end

function app:stop()
	self._stop = true
end

--PropertyNotify dispatcher --------------------------------------------------

ev[C.PropertyNotify] = function(e)
	e = e.xproperty
	local handler = evprop[e.atom]
	if handler then handler(e) end
end

--timers ---------------------------------------------------------------------

local function cmp(t1, t2)
	return t1.time < t2.time
end
local timers = heap.valueheap{cmp = cmp}

local select_accuracy = 0.01 --assume 10ms accuracy of select()

--pull and execute all expired timers and return the timeout until the next one.
function app:_pull_timers()
	while timers:length() > 0 do
		local t = timers:peek()
		local now = time.clock()
		if now + select_accuracy / 2 > t.time then
			if t.func() == false then --func wants timer to stop
				timers:pop()
			else --func wants timer to keep going
				t.time = now + t.interval
				timers:replace(1, t)
				--break to avoid recurrent timers to starve the event loop.
				return 0
			end
		else
			return t.time - now --wait till next scheduled timer
		end
	end
	return true --block indefinitely
end

function app:runevery(seconds, func)
	timers:push({time = time.clock() + seconds, interval = seconds, func = func})
end

--xsettings ------------------------------------------------------------------

function evprop._XSETTINGS_SETTINGS(e)
	if e.window ~= xlib.get_xsettings_window() then return end
	--TODO:
end

--windows --------------------------------------------------------------------

local window = {}
app.window = window

local winmap = {} --{Window (always a number) -> window object}

local function clamp_opt(x, min, max)
	if min then x = math.max(x, min) end
	if max then x = math.min(x, max) end
	return x
end
function window:__constrain(cw, ch)
	cw = clamp_opt(cw, self._min_cw, self._max_cw)
	ch = clamp_opt(ch, self._min_ch, self._max_ch)
	return cw, ch
end

--check if a given screen has a bgra8 visual (for creating windows with alpha).
local function find_bgra8_visual(screen)
	for i=0,screen.ndepths-1 do
		local d = screen.depths[i]
		if d.depth == 32 then
			for i=0,d.nvisuals-1 do
				local v = d.visuals[i]
				if v.bits_per_rgb == 8 and v.blue_mask == 0xff then --BGRA8
					return v
				end
			end
		end
	end
end

function window:new(app, frontend, t)
	self = glue.inherit({app = app, frontend = frontend}, self)

	local attrs = {}

	--say that we don't want the server to keep a pixmap for the window.
	attrs.background_pixmap = 0

	--paint the background black
	attrs.background_pixel = 0

	--needed if we want to set a value for colormap too!
	attrs.border_pixel = 0

	--declare what events we want to receive.
	attrs.event_mask = bit.bor(
		C.KeyPressMask,
		C.KeyReleaseMask,
		C.ButtonPressMask,
		C.ButtonReleaseMask,
		C.EnterWindowMask,
		C.LeaveWindowMask,
		C.PointerMotionMask,
		C.PointerMotionHintMask,
		C.Button1MotionMask,
		C.Button2MotionMask,
		C.Button3MotionMask,
		C.Button4MotionMask,
		C.Button5MotionMask,
		C.ButtonMotionMask,
		C.KeymapStateMask,
		C.ExposureMask,
		C.VisibilityChangeMask,
		C.StructureNotifyMask,
		--C.ResizeRedirectMask,
		C.SubstructureNotifyMask,
		--C.SubstructureRedirectMask,
		C.FocusChangeMask,
		C.PropertyChangeMask,
		C.ColormapChangeMask,
		C.OwnerGrabButtonMask,
	0)

	attrs.visual = find_bgra8_visual(xlib.screen)
	if attrs.visual then
		attrs.depth = 32
		--creating a 32bit-depth window with alpha requires creating a colormap!
		attrs.colormap = xlib.create_colormap(xlib.screen.root, attrs.visual)
	end

	--get client size from frame size
	local _, _, cw, ch = app:frame_to_client(t.frame, t.menu, 0, 0, t.w, t.h)

	--store and apply constraints to client size
	self._min_cw = t.min_cw
	self._min_ch = t.min_ch
	self._max_cw = t.max_cw
	self._max_ch = t.max_ch
	cw, ch = self:__constrain(cw, ch)

	attrs.x = t.x
	attrs.y = t.y
	attrs.width = cw
	attrs.height = ch
	self.win = xlib.create_window(attrs)

	--NOTE: WMs ignore the initial position unless we set WM_NORMAL_HINTS too
	--(values don't matter, but we're using the same t.x and t.y just in case).
	local hints = {x = t.x, y = t.y}

	if not t.resizeable then
		--this is how X knows that a window is non-resizeable (there's no flag).
		hints.min_width  = cw
		hints.min_height = ch
		hints.max_width  = cw
		hints.max_height = ch
	else
		--tell X about any (already-applied) constraints.
		hints.min_width  = t.min_cw
		hints.min_height = t.min_ch
		--NOTE: we can't set a constraint on one axis alone, hence the 2^24.
		if t.max_cw or t.max_ch then
			hints.max_width  = t.max_cw or 2^24
			hints.max_height = t.max_ch or 2^24
		end
	end
	xlib.set_wm_size_hints(self.win, hints)

	--declare the X protocols that the window supports.
	xlib.set_atom_map_prop(self.win, 'WM_PROTOCOLS', {
		WM_DELETE_WINDOW = true, --don't close the connection when a window is closed
		WM_TAKE_FOCUS = true,    --allow focusing the window programatically
		_NET_WM_PING = true,     --respond to ping events
	})

	--set info for _NET_WM_PING to allow the user to kill a non-responsive process.
	xlib.set_net_wm_ping_info(self.win)

	if t.title then
		xlib.set_title(self.win, t.title)
	end

	if t.parent then
		xlib.set_transient_for(t.parent.backend.win)
	end

	--set motif hints before mapping the window.
	local hints = ffi.new'PropMotifWmHints'
	hints.flags = bit.bor(
		C.MWM_HINTS_FUNCTIONS,
		C.MWM_HINTS_DECORATIONS)
	hints.functions = bit.bor(
		t.resizeable and C.MWM_FUNC_RESIZE or 0,
		C.MWM_FUNC_MOVE,
		t.minimizable and C.MWM_FUNC_MINIMIZE or 0,
		t.maximizable and C.MWM_FUNC_MAXIMIZE or 0,
		t.closeable and C.MWM_FUNC_CLOSE or 0)
	hints.decorations = t.frame == 'none' and 0 or bit.bor(
		C.MWM_DECOR_BORDER,
		C.MWM_DECOR_TITLE,
		C.MWM_DECOR_MENU,
		t.resizeable  and C.MWM_DECOR_RESIZEH or 0,
		t.minimizable and C.MWM_DECOR_MINIMIZE or 0,
		t.maximizable and C.MWM_DECOR_MAXIMIZE or 0)
	xlib.set_motif_wm_hints(self.win, hints)

	--remembered window state while hidden
	self._minimized = t.minimized or false
	self._maximized = t.maximized or false
	self._fullscreen = t.fullscreen or false
	self._topmost = t.topmost or false
	self._visible = false

	winmap[self.win] = self

	return self
end

--closing --------------------------------------------------------------------

ev[C.ClientMessage] = function(e)
	e = e.xclient
	local self = winmap[xid(e.window)]
	if not self then return end --not for us
	local v = e.data.l[0]
	if e.message_type == xlib.atom'WM_PROTOCOLS' then
		if v == xlib.atom'WM_DELETE_WINDOW' then
			if self.frontend:_backend_closing() then
				self:forceclose()
			end
		elseif v == xlib.atom'WM_TAKE_FOCUS' then
			--ha?
		elseif v == xlib.atom'_NET_WM_PING' then
			xlib.pong(e)
		end
	end
end

ev[C.ConfigureNotify] = function(e)
	e = e.xconfigure
	local self = winmap[xid(e.window)]
	if not self then return end
	--local x = e.x
	--local y = e.y
	--local w = e.width
	--local h = e.height
end

function window:forceclose()
	if self._closing then return end
	self._closing = true --forceclose() barrier
	--force-close child windows first to emulate Windows behavior.
	for i,win in ipairs(self.frontend:children()) do
		win.backend:forceclose()
	end
	--hide first to trigger changed() and to allow minimized(), maximized(),
	--fullscreen() to continue to work in closed() event.
	self:hide()
	xlib.destroy_window(self.win) --doesn't trigger WM_DELETE_WINDOW
	self.frontend:_backend_closed()
	winmap[self.win] = nil
	self.win = nil
end

--activation -----------------------------------------------------------------

--how much to wait for another window to become active after a window
--is deactivated, before triggering a 'app deactivated' event.
local focus_out_timeout = 0.1
local last_focus_out
local focus_timer_started
local app_active
local last_active_window

function app:_check_activated()
	if app_active then return end
	app_active = true
	self.frontend:_backend_activated()
end

ev[C.FocusIn] = function(e)
	local e = e.xfocus
	local self = winmap[xid(e.window)]
	if not self then return end

	if last_active_window then return end --ignore duplicate events
	last_active_window = self

	last_focus_out = nil
	self.app:_check_activated() --window activation implies app activation.
	self.frontend:_backend_activated()
end

ev[C.FocusOut] = function(e)
	local e = e.xfocus
	local self = winmap[xid(e.window)]
	if not self then return end

	if not last_active_window then return end --ignore duplicate events
	last_active_window = nil

	--start a delayed check for when the app is deactivated.
	--if a timer is already started, just advance the delay.
	last_focus_out = time.clock()
	if not focus_timer_started then
		self.app.frontend:runafter(focus_out_timeout, function()
			if last_focus_out and time.clock() - last_focus_out > focus_out_timeout then
				last_focus_out = nil
				app_active = false
				self.app.frontend:_backend_deactivated()
			end
			focus_timer_started = false
		end)
		focus_timer_started = true
	end

	self.frontend:_backend_deactivated()
end

--if the app was active but the
function app:_check_app_deactivate()
	if not app_active then return end
	self.frontend:_backend_deactivated()
end

function app:activate()
	if app_active then return end
	--unlike OSX, in X you don't activate an app, you have to activate a specific window.
	--activating this app means activating the last window that was active.
	local win = last_active_window
	if win and not win.frontend:dead() then
		win:activate()
	end
end

function app:active_window()
	return app_active and winmap[xlib.get_input_focus()] or nil
end

function app:active()
	return app_active
end

function window:activate()
	xlib.change_net_active_window(self.win)
end

function window:active()
	return app:active_window() == self
end

--state/visibility -----------------------------------------------------------

function window:visible()
	return self._visible
end

function window:show()
	if self._visible then return end

	--set the _NET_WM_STATE property before mapping the window.
	--later on we have to use change_net_wm_state() to change these values.
	xlib.set_net_wm_state(self.win, {
		_NET_WM_STATE_MAXIMIZED_HORZ = self._maximized or nil,
		_NET_WM_STATE_MAXIMIZED_VERT = self._maximized or nil,
		_NET_WM_STATE_ABOVE = self._topmost or nil,
		_NET_WM_STATE_FULLSCREEN = self._fullscreen or nil,
	})

	--set WM_HINTS property before mapping the window.
	--later on we have to use change_wm_state() to minimize the window.
	if self._minimized then
		xlib.set_wm_hints(self.win, {initial_state = C.IconicState})
	end
	xlib.map(self.win)
	self._visible = true

	if not self._minimized then
		--activate window to emulate Windows behavior.
		self:activate()
	end
end

function window:hide()
	if not self._visible then return end
	--remember window state while hidden.
	self._minimized = self:minimized()
	self._maximized = self:maximized()
	self._fullscreen = self:fullscreen()
	xlib.withdraw(self.win)

	self._visible = false
end

function window:_mapped()
	if self._visible then return end
	self.frontend:_backend_was_shown()
	self._visible = true
end

function window:_unmapped()
	if self._visible then return end --minimized, ignore
	self.frontend:_backend_was_hidden()
	self._visible = false
end

--NOTE: unminimizating means mapping
ev[C.MapNotify] = function(e)
	local e = e.xmap
	local win = winmap[xid(e.window)]
	if not win then return end
	win:_mapped()
end

--NOTE: minimizating means unmapping
ev[C.UnmapNotify] = function(e)
	local e = e.xunmap
	local win = winmap[xid(e.window)]
	if not win then return end
	win:_unmapped()
end

--state/minimizing -----------------------------------------------------------

function window:_get_minimized_state()
	return xlib.get_wm_state(self.win) == C.IconicState
end

function window:minimized()
	if not self._visible then
		return self._minimized
	end
	return self:_get_minimized_state()
end

function window:minimize()
	if not self._visible then
		self._minimized = true
		self:show()
		assert(self:minimized())
	else
		xlib.change_wm_state(self.win, C.IconicState)
	end
end

function window:_wm_state_changed()
	local min = self:_get_minimized_state()
	if min ~= self._minimized then
		if min then
			self.frontend:_backend_was_minimized()
		else
			self.frontend:_backend_was_unminimized()
		end
		self._minimized = min
	end
end

function evprop.WM_STATE(e)
	local win = winmap[xid(e.window)]
	if not win then return end
	win:_wm_state_changed()
end

--state/maximized+fullscreen -------------------------------------------------

function window:_get_net_wm_state(flag)
	local st = xlib.get_net_wm_state(self.win)
	return st and st[flag] or false
end

--state/maximizing -----------------------------------------------------------

function window:_get_maximized_state()
	return self:_get_net_wm_state'_NET_WM_STATE_MAXIMIZED_HORZ'
end

function window:maximized()
	if not self._visible then
		return self._maximized
	end
	return self:_get_maximized_state()
end

function window:_set_maximized(onoff)
	xlib.change_net_wm_state(self.win, onoff,
		'_NET_WM_STATE_MAXIMIZED_HORZ',
		'_NET_WM_STATE_MAXIMIZED_VERT')
end

function window:maximize()
	if not self._visible then
		self._maximized = true
		self._minimized = false
		self:show()
		self:_set_maximized(true)
	elseif self:minimized() then
		self:_set_maximized(true)
		self:restore()
		assert(self:maximized())
	else
		self:_set_maximized(true)
	end
end

function window:_net_wm_state_changed()

	local fs = self:_get_fullscreen_state()
	if fs ~= self._fullscreen then
		if fs then
			self.frontend:_backend_entered_fullscreen()
		else
			self.frontend:_backend_exited_fullscreen()
		end
		self._fullscreen = fs
	end

	local max = self:_get_maximized_state()
	if max ~= self._maximized then
		if max then
			self.frontend:_backend_was_maximized()
		else
			self.frontend:_backend_was_unmaximized()
		end
		self._maximized = max
	end

end

function evprop._NET_WM_STATE(e)
	local win = winmap[xid(e.window)]
	if not win then return end
	win:_net_wm_state_changed()
end

--state/restoring ------------------------------------------------------------

function window:restore()
	if self._visible then
		if self:minimized() then
			xlib.map(self.win)
		elseif self:maximized() then
			self:_set_maximized(false)
		end
	else
		self:show()
	end
end

function window:shownormal()
	if not self._visible then
		self._minimized = false
		if self:maximized() then
			self:_set_maximized(false)
		end
		self:show()
	elseif self:minimized() then
		if self:maximized() then
			self:_set_maximized(false)
		end
		xlib.map(self.win)
		--activate window to emulate Windows behavior.
		self:activate()
	elseif self:maximized() then
		self:_set_maximized(false)
	end
end

--state/fullscreen -----------------------------------------------------------

function window:_get_fullscreen_state()
	return self:_get_net_wm_state'_NET_WM_STATE_FULLSCREEN'
end

function window:fullscreen()
	if not self._visible then
		return self._fullscreen
	end
	return self:_get_fullscreen_state()
end

function window:enter_fullscreen()
	if self._visible then
		xlib.change_net_wm_state(self.win, true, '_NET_WM_STATE_FULLSCREEN')
	else
		self._fullscreen = true
		self._minimized = false
		self:show()
		self:enter_fullscreen()
	end
end

function window:exit_fullscreen()
	xlib.change_net_wm_state(self.win, false, '_NET_WM_STATE_FULLSCREEN')
end

--state/enabled --------------------------------------------------------------

function window:get_enabled()
	return not self._disabled
end

function window:set_enabled(enabled)
	self._disabled = not enabled
end

--positioning/conversions ----------------------------------------------------

function window:to_screen(x, y)
	return xlib.translate_coords(self.win, xlib.screen.root, x, y)
end

function window:to_client(x, y)
	return xlib.translate_coords(xlib.screen.root, self.win, x, y)
end

local function unmapped_frame_extents(win)
	local w1, h1, w2, h2
	if xlib.frame_extents_supported() then
		xlib.request_frame_extents(win)
		w1, h1, w2, h2 = xlib.get_frame_extents(win)
		--some WMs set the extents later or not at all so we have to poll.
		if not w1 then
			local timeout = time.clock() + 0.2
			local period = 0.01
			while true do
				w1, h1, w2, h2 = xlib.get_frame_extents(win)
				if w1 or time.clock() > timeout then break end
				time.sleep(period)
				period = period * 2
			end
		end
	end
	if not w1 then --bail out with wrong values.
		w1, h1, w2, h2 = 0, 0, 0, 0
	end
	return w1, h1, w2, h2
end

local frame_extents = glue.memoize(function(frame, has_menu)
	if frame == 'none' then
		return {0, 0, 0, 0}
	end
	--create a dummy window
	local win = xlib.create_window{width = 200, height = 200}
	--get its frame extents
	local w1, h1, w2, h2 = unmapped_frame_extents(win)
	--destroy the window
	xlib.destroy_window(win)
	--compute/return the frame rectangle
	return {w1, h1, w2, h2}
end)

local frame_extents = function(frame, has_menu)
	return unpack(frame_extents(frame, has_menu))
end

local function frame_rect(x, y, w, h, w1, h1, w2, h2)
	return x - w1, y - h1, w + w1 + w2, h + h1 + h2
end

local function unframe_rect(x, y, w, h, w1, h1, w2, h2)
	return frame_rect(x, y, w, h, -w1, -h1, -w2, -h2)
end

function app:client_to_frame(frame, has_menu, x, y, w, h)
	return frame_rect(x, y, w, h, frame_extents(frame, has_menu))
end

function app:frame_to_client(frame, has_menu, x, y, w, h)
	local fx, fy, fw, fh = self:client_to_frame(frame, has_menu, 0, 0, 200, 200)
	local cx = x - fx
	local cy = y - fy
	local cw = w - (fw - 200)
	local ch = h - (fh - 200)
	return cx, cy, cw, ch
end

--positioning/rectangles -----------------------------------------------------

function window:_frame_extents()
	if self.frame == 'none' then
		return 0, 0, 0, 0
	end
	return unmapped_frame_extents(self.win)
end

function window:get_normal_rect()
	return self:get_frame_rect()
end

function window:set_normal_rect(x, y, w, h)
	self:set_frame_rect(x, y, w, h)
end

function window:get_frame_rect()
	local x, y = self:to_screen(0, 0)
	local w, h = self:get_size()
	return frame_rect(x, y, w, h, self:_frame_extents())
end

function window:set_frame_rect(x, y, w, h)
	local cx, cy, cw, ch = unframe_rect(x, y, w, h, self:_frame_extents())
	xlib.config(self.win, {x = x, y = y, width = w, height = h, border_width = 0})
end

function window:get_size()
	local x, y, w, h = xlib.get_geometry(self.win)
	return w, h
end

--positioning/constraints ----------------------------------------------------

function window:_apply_constraints()

	--get current client size and new (constrained) client size
	local cw0, ch0 = self:get_size()
	local cw, ch = self:__constrain(cw0, ch0)

	--update constraints
	local hints = {}
	if not self.frontend:resizeable() then
		if cw ~= cw0 or ch ~= ch0 then
			hints.min_width  = cw
			hints.min_height = ch
			hints.max_width  = cw
			hints.max_height = ch
		end
	else
		hints.min_width  = self._min_cw
		hints.min_height = self._min_ch
		--NOTE: we can't set a constraint on one dimension alone hence 2^24.
		if t.max_cw or t.max_ch then
			hints.max_width  = self._max_cw or 2^24
			hints.max_height = self._max_ch or 2^24
		end
	end
	xlib.set_wm_size_hints(self.win, hints)

	--resize the window if dimensions changed
	if cw ~= cw0 or ch ~= ch0 then
		xlib.config(self.win, {width = cw, height = ch, border_width = 0})
	end
end

function window:get_minsize()
	return self._min_cw, self._min_ch
end

function window:get_maxsize()
	return self._max_cw, self._max_ch
end

function window:set_minsize(min_cw, min_ch)
	self._min_cw, self._min_ch = min_cw, min_ch
	self:_apply_constraints()
end

function window:set_maxsize(max_cw, max_ch)
	self._max_cw, self._max_ch = max_cw, max_ch
	self:_apply_constraints()
end

--positioning/resizing -------------------------------------------------------

--self.frontend:_backend_start_resize(how)
--self.frontend:_backend_end_resize(how)
--self.frontend:_backend_resizing(how, unpack_rect(rect)))
--self.frontend:_backend_resized()

--positioning/magnets --------------------------------------------------------

function window:magnets()
end

--titlebar -------------------------------------------------------------------

function window:get_title()
	return xlib.get_title(self.win)
end

function window:set_title(title)
	xlib.set_title(self.win, title)
end

--z-order --------------------------------------------------------------------

function window:get_topmost()
	return self._topmost
end

function window:set_topmost(topmost)
	xlib.change_net_wm_state(self.win, topmost, '_NET_WM_STATE_ABOVE')
end

function window:raise(relto)
	assert(not relto, 'NYI')
	xlib.raise(self.win)
end

function window:lower(relto)
	assert(not relto, 'NYI')
	xlib.lower(self.win)
end

--displays -------------------------------------------------------------------

function app:_display(screen)
	return self.frontend:_display{
		x = 0, --TODO
		y = 0,
		w = xlib.screen.width_in_pixels,
		h = xlib.screen.height_in_pixels,
		client_x = 0, --TODO
		client_y = 0,
		client_w = 0,
		client_h = 0,
	}
end

function app:displays()
	local t = {}
	for screen in screens() do
		t[#t+1] = self:_display(screen)
	end
	return t
end

function app:active_display()
end

function app:display_count()
	return 1--C.xcb_setup_roots_length(C.xcb_get_setup(c))
end

function window:display()
	--
end

--self.app.frontend:_backend_displays_changed()

--cursors --------------------------------------------------------------------

function window:update_cursor()
	local visible, name = self.frontend:cursor()
	local cursor = visible and xlib.load_cursor(name) or xlib.blank_cursor()
	xlib.set_cursor(self.win, cursor)
end

--keyboard -------------------------------------------------------------------

ev[C.KeyPress] = function(e)
	local e = e.xkey
	local self = winmap[xid(e.window)]
	if not self then return end
	if self._disabled then return end
	if self._keypressed then
		self._keypressed = false
		return
	end
	local key = e.keycode
	--print('sequence: ', e.sequence)
	--print('state:    ', e.state)
	self.frontend:_backend_keydown(key)
	self.frontend:_backend_keypress(key)
end

ev[C.KeyRelease] = function(e)
	local e = e.xkey
	local self = winmap[xid(e.window)]
	if not self then return end
	if self._disabled then return end
	local key = e.keycode

	--peek next message to distinguish between key release and key repeat
 	local e1 = xlib.peek()
 	if e1 then
 		if e1.type == C.KeyPress then
			local e1 = e1.xkey
			if e1.time == e.time and e1.keycode == e.keycode then
				self.frontend:_backend_keypress(key)
				self._keypressed = true --key press barrier
 			end
 		end
 	end
	if not self._keypressed then
		self.frontend:_backend_keyup(key)
	end
end

--self.frontend:_backend_keychar(char)

function window:key(name) --name is in lowercase!
	if name:find'^%^' then --'^key' means get the toggle state for that key
		name = name:sub(2)
	else
	end
end

--mouse ----------------------------------------------------------------------

local btns = {'left', 'middle', 'right'}

ev[C.ButtonPress] = function(e)
	local e = e.xbutton
	local self = winmap[xid(e.window)]
	if not self then return end
	if self._disabled then return end

	local btn = btns[e.button]
	if not btn then return end
	local x, y = 0, 0
	self.frontend:_backend_mousedown(btn, x, y)
end

ev[C.ButtonRelease] = function(e)
	local e = e.xbutton
	local self = winmap[xid(e.window)]
	if not self then return end
	if self._disabled then return end

	local btn = btns[e.button]
	if not btn then return end
	local x, y = 0, 0
	self.frontend:_backend_mouseup(btn, x, y)
end

function app:double_click_time() --milliseconds
	return 500
end

function app:double_click_target_area()
	return 4, 4 --like in windows
end

--self.frontend:_backend_mousemove(x, y)
--self.frontend:_backend_mouseleave()
--self.frontend:_backend_mousedown('left', x, y)
--self.frontend:_backend_mousedown('middle', x, y)
--self.frontend:_backend_mousedown('right', x, y)
--self.frontend:_backend_mousedown('ex1', x, y)
--self.frontend:_backend_mousedown('ex2', x, y)
--self.frontend:_backend_mouseup('left', x, y)
--self.frontend:_backend_mouseup('middle', x, y)
--self.frontend:_backend_mouseup('right', x, y)
--self.frontend:_backend_mouseup('ex1', x, y)
--self.frontend:_backend_mouseup('ex2', x, y)
--self.frontend:_backend_mousewheel(delta, x, y)
--self.frontend:_backend_mousehwheel(delta, x, y)

--bitmaps --------------------------------------------------------------------

--[[
Things you need to know:
- in X11 bitmaps are called pixmaps and 1-bit bitmaps are called bitmaps.
- pixmaps are server-side bitmaps while images are client-side bitmaps.
- you can't create a Drawable, that's just an abstraction: instead,
  any Pixmap or Window can be used where a Drawable is expected.
- pixmaps have depth, but no channel layout. windows have color info.
- the default screen visual has 24 depth, but a screen can have many visuals.
  if it has a 32 depth visual, then we can make windows with alpha.
- a window with alpha needs CWColormap which needs CWBorderPixel.
]]

local function slow_resize_buffer(ctype, shrink_factor, reserve_factor)
	local buf, sz
	return function(size)
		if not buf or sz < size or sz > math.floor(size * shrink_factor) then
			if buf then glue.free(buf) end
			sz = math.floor(size * reserve_factor)
			buf = glue.malloc(ctype, sz)
		end
		return buf
	end
end

local function make_bitmap(w, h, win, ssbuf)

	local stride = w * 4
	local size = stride * h

	local bitmap = {
		w        = w,
		h        = h,
		stride   = stride,
		size     = size,
		format   = 'bgra8',
	}

	local paint, free

	if false and xcb_has_shm() then

		local shmid = shm.shmget(shm.IPC_PRIVATE, size, bit.bor(shm.IPC_CREAT, 0x1ff))
		local data  = shm.shmat(shmid, nil, 0)

		local shmseg  = xlib.gen_id()
		xcbshm.xcb_shm_attach(c, shmseg, shmid, 0)
		shm.shmctl(shmid, shm.IPC_RMID, nil)

		local pix = xlib.gen_id()

		xcbshm.xcb_shm_create_pixmap(c, pix, win, w, h, depth_id, shmseg, 0)

		bitmap.data = data

		local gc = xlib.gen_id()
		C.xcb_create_gc(c, gc, win, 0, nil)

		function paint()
			xlib.copy_area(gc, pix, win, 0, 0, 0, 0, w, h)
		end

		function free()
			xcbshm.xcb_shm_detach(c, shmseg)
			shm.shmdt(data)
			C.xcb_free_pixmap(c, pix)
		end

	else

		local data = ssbuf(size)
		bitmap.data = data

		local pix = xlib.create_pixmap(win, w, h, 32)
		local gc = xlib.create_gc(win)

		function paint()
			xlib.put_image(gc, data, size, w, h, 32, pix)
			xlib.copy_area(gc, pix, 0, 0, w, h, win)
		end

		function free()
			xlib.free_gc(gc)
			xlib.free_pixmap(pix)
			bitmap.data = nil
		end

	end

	return bitmap, free, paint
end

--a dynamic bitmap is an API that creates a new bitmap everytime its size
--changes. user supplies the :size() function, :get() gets the bitmap,
--and :freeing(bitmap) is triggered before the bitmap is freed.
local function dynbitmap(api, win)

	api = api or {}

	local w0, h0, bitmap, free, paint
	local ssbuf = slow_resize_buffer('char', 2, 1.2)

	function api:get()
		local w, h = api:size()
		if not bitmap or w ~= w0 or h ~= h0 then
			if bitmap then
				free()
			end
			bitmap, free, paint = make_bitmap(w, h, win, ssbuf)
		end
		return bitmap
	end

	function api:free()
		if not free then return end
		self:freeing(bitmap)
		free()
	end

	function api:paint()
		if not paint then return end
		paint()
	end

	return api
end

--rendering ------------------------------------------------------------------

ev[C.Expose] = function(e)
	local e = e.xexpose
	if e.count ~= 0 then return end --subregion rendering
	local self = winmap[xid(e.window)]
	if not self then return end
	self:invalidate()
end

function window:bitmap()
	if not self._dynbitmap then
		self._dynbitmap = dynbitmap({
			size = function()
				return self.frontend:size()
			end,
			freeing = function(_, bitmap)
				self.frontend:_backend_free_bitmap(bitmap)
			end,
		}, self.win)
	end
	return self._dynbitmap:get()
end

function window:invalidate()
	--let the user request the bitmap and draw on it.
	self.frontend:_backend_repaint()
	if not self._dynbitmap then return end
	self._dynbitmap:paint()
end

function window:_free_bitmap()
	 if not self._dynbitmap then return end
	 self._dynbitmap:free()
	 self._dynbitmap = nil
end

--views ----------------------------------------------------------------------

local view = {}
window.view = view

function view:new(window, frontend, t)
	local self = glue.inherit({
		window = window,
		app = window.app,
		frontend = frontend,
	}, self)

	self:_init(t)

	return self
end

glue.autoload(window, {
	glview    = 'nw_winapi_glview',
	cairoview = 'nw_winapi_cairoview',
	cairoview2 = 'nw_winapi_cairoview2',
})

function window:getcairoview()
	if self._layered then
		return cairoview
	else
		return cairoview2
	end
end

--menus ----------------------------------------------------------------------

local menu = {}

function app:menu()
end

function menu:add(index, args)
end

function menu:set(index, args)
end

function menu:get(index)
end

function menu:item_count()
end

function menu:remove(index)
end

function menu:get_checked(index)
end

function menu:set_checked(index, checked)
end

function menu:get_enabled(index)
end

function menu:set_enabled(index, enabled)
end

function window:menubar()
end

function window:popup(menu, x, y)
end

--notification icons ---------------------------------------------------------

local notifyicon = {}
app.notifyicon = notifyicon

function notifyicon:new(app, frontend, opt)
	self = glue.inherit({app = app, frontend = frontend}, notifyicon)
	return self
end

function notifyicon:free()
end
--self.backend:_notify_window()

function notifyicon:invalidate()
	self.frontend:_backend_repaint()
end

function notifyicon:get_tooltip()
end

function notifyicon:set_tooltip(tooltip)
end

function notifyicon:get_menu()
end

function notifyicon:set_menu(menu)
end

function notifyicon:rect()
end

--window icon ----------------------------------------------------------------

function window:icon_bitmap(which)
end

function window:invalidate_icon(which)
	self.frontend:_backend_repaint_icon(which)
end

--file chooser ---------------------------------------------------------------

function app:opendialog(opt)
end

function app:savedialog(opt)
end

--clipboard ------------------------------------------------------------------

function app:clipboard_empty(format)
end

function app:clipboard_formats()
end

function app:get_clipboard(format)
end

function app:set_clipboard(t)
end

--drag & drop ----------------------------------------------------------------

--??

function window:start_drag()
end

--buttons --------------------------------------------------------------------


return nw
