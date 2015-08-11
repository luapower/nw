
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
local box2d = require'box2d' --for win:display()
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
	xlib.synchronize(true) --shave off one source of unpredictability
	xlib.set_xsettings_change_notify() --setup to receive XSETTINGS changes
	self:_resolve_evprop_names()
	return self
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

local function pull_event(timeout)
	local e = xlib.poll(timeout)
	if not e then return end
	--print(evstr(e))
	local f = ev[tonumber(e.type)]
	if f then f(e) end
	--NOTE: right here e is invalid because f() can cause re-entering!
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

local evprop = {} --{property_name -> PropertyNotify_handler}

function app:_resolve_evprop_names()
	for name, handler in pairs(evprop) do
		local atom = xlib.atom(name)
		if atom then
			evprop[atom] = handler
		end
	end
end

ev[C.PropertyNotify] = function(e)
	local e = e.xproperty
	local handler = evprop[tonumber(e.atom)]
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

local xsettings

function evprop._XSETTINGS_SETTINGS(e)
	xsettings = nil
end

function app:_xsettings(key)
	if xsettings == nil then
		xsettings = xlib.get_xsettings() or false
	end
	if not xsettings then return end
	return xsettings[key] and xsettings[key].value
end

--windows --------------------------------------------------------------------

local window = {}
app.window = window

local winmap = {} --{Window (always a number) -> window object}

local function win(win) --window_id -> window_object
	return winmap[xid(win)]
end

--constrain the client size (cw, ch) based on current size constraints.
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

	--declare what events we want to receive.
	attrs.event_mask = bit.bor(
		C.KeyPressMask,
		C.KeyReleaseMask,
		C.ButtonPressMask,
		C.ButtonReleaseMask,
		C.EnterWindowMask,
		C.LeaveWindowMask,
		C.PointerMotionMask,
		--C.PointerMotionHintMask, --disables MotionNotify!
		C.Button1MotionMask,
		C.Button2MotionMask,
		C.Button3MotionMask,
		C.Button4MotionMask,
		C.Button5MotionMask,
		C.ButtonMotionMask,
		--C.KeymapStateMask, --KeymapNotify
		C.ExposureMask,
		C.VisibilityChangeMask,
		C.StructureNotifyMask,
		--C.ResizeRedirectMask, --not working
		C.SubstructureNotifyMask,
		--C.SubstructureRedirectMask,
		C.FocusChangeMask,
		C.PropertyChangeMask,
		C.ColormapChangeMask,
		C.OwnerGrabButtonMask,
	0)

	if t.transparent then
		--find a 32bit BGRA8 visual so we can create a window with alpha.
		attrs.visual = find_bgra8_visual(xlib.screen)
		if attrs.visual then
			attrs.depth = 32
			--creating a 32bit-depth window requires creating a colormap!
			attrs.colormap = xlib.create_colormap(xlib.screen.root, attrs.visual)
			--setting a colormap requires setting border_pixel!
			attrs.border_pixel = 0
		end
	end

	--store window's depth for put_image()
	self._depth = attrs.depth or xlib.screen.root_depth

	--get client size from frame size
	local _, _, cw, ch = app:frame_to_client(t.frame, t.menu, 0, 0, t.w, t.h)

	--store and apply constraints to client size
	self._min_cw = t.min_cw
	self._min_ch = t.min_ch
	self._max_cw = t.max_cw
	self._max_ch = t.max_ch
	cw, ch = self:__constrain(cw, ch)
	attrs.width = cw
	attrs.height = ch

	--set position (optional: t.x and/or t.y can be missing)
	attrs.x = t.x
	attrs.y = t.y

	self.win = xlib.create_window(attrs)
	xlib.flush() --lame: XSynchronize() didn't do it's job here

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
		_NET_WM_PING = true, --respond to ping events
	})

	--set info for _NET_WM_PING to allow the user to kill a non-responsive process.
	xlib.set_net_wm_ping_info(self.win)

	if t.title then
		xlib.set_title(self.win, t.title)
	end

	if t.parent then
		xlib.set_transient_for(self.win, t.parent.backend.win)
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

	--activable state for setting later via set_wm_hints().
	--TODO: this doesn't actually work!
	self._activable = t.activable

	--flag to mask off window's reported state while the window is unmapped.
	self._hidden = true

	--state flags to be reported while the window is unmapped.
	self._minimized = t.minimized or false
	self._maximized = t.maximized or false
	self._fullscreen = t.fullscreen or false
	self._topmost = t.topmost or false

	winmap[self.win] = self

	return self
end

--closing --------------------------------------------------------------------

ev[C.ClientMessage] = function(e)
	local e = e.xclient
	local self = win(e.window)
	if not self then return end --not for us

	local v = e.data.l[0]
	if e.message_type == xlib.atom'WM_PROTOCOLS' then
		if v == xlib.atom'WM_DELETE_WINDOW' then
			self.frontend:close()
		elseif v == xlib.atom'_NET_WM_PING' then
			xlib.pong(e)
		end
	end
end

function window:forceclose()

	--force-close child windows first, consistent with Windows.
	for i,win in ipairs(self.frontend:children()) do
		win:close(true)
	end

	--trigger closed event after children are closed but before destroying the window.
	self.frontend:_backend_was_closed()

	xlib.destroy_window(self.win)
	winmap[self.win] = nil
	self.win = nil
end

--activation -----------------------------------------------------------------

--how much to wait for another window to become active after a window
--is deactivated, before triggering an 'app deactivated' event.
local focus_out_timeout = 0.1
local last_focus_out
local focus_timer_started
local last_active_window

function app:_check_activated()
	if self._active then return end
	self._active = true
	self.frontend:_backend_changed()
end

ev[C.FocusIn] = function(e)
	local e = e.xfocus
	local self = win(e.window)
	if not self then return end

	if last_active_window then return end --ignore duplicate events
	last_active_window = self

	last_focus_out = nil
	self.app:_check_activated() --window activation implies app activation.
	self.frontend:_backend_changed()
end

--NOTE: set after UnmapNotify when hiding.
ev[C.FocusOut] = function(e)
	local e = e.xfocus
	local self = win(e.window)
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

				self.app._active = false
				self.app.frontend:_backend_changed()
			end
			focus_timer_started = false
		end)
		focus_timer_started = true
	end

	self.frontend:_backend_changed()
end

function app:activate()
	if self._active then return end
	--unlike OSX, in X you don't activate an app, you can only activate a window.
	--activating this app means activating the last window that was active.
	local win = last_active_window
	if win and not win.frontend:dead() then
		win:activate()
	end
end

function app:active_window()
	--return the active window only if the app is active, consistent with OSX.
	return self._active and win(xlib.get_input_focus()) or nil
end

function app:active()
	return self._active
end

function window:activate()
	xlib.change_net_active_window(self.win)
end

function window:active()
	return app:active_window() == self
end

--state/visibility -----------------------------------------------------------

function window:visible()
	local st = xlib.get_wm_state(self.win)
	return st and st ~= C.WithdrawnState
end

function window:show()
	if not self._hidden then return end

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
	if self._minimized or not self._activable then
		xlib.set_wm_hints(self.win, {
			initial_state = self._minimized and C.IconicState or nil,
			input = not self._activable and 0 or nil, --TODO: doesn't actually work!
		})
	end

	xlib.map(self.win)

	if not self._minimized then
		--activate the window but not when minimized, consistent with Windows.
		self:activate()
	else
		--if minimized, MapNotify is not sent, but PropertyNotify/WM_STATE is.
		self._wm_state_cmd = 'map'
	end
end

function window:hide()
	if self._hidden then return end

	--remember window state while hidden.
	self._minimized = self:minimized()
	self._maximized = self:maximized()
	self._fullscreen = self:fullscreen()
	self._hidden = true --switch to stored state

	xlib.withdraw(self.win)

	if self._minimized then
		--if minimized, UnmapNotify is not sent, but PropertyNotify/WM_STATE is.
		self._wm_state_cmd = 'unmap'
	end
end

function window:_mapped()
	if not self._hidden then return end --unminimized, ignore
	self._hidden = false --switch to real state
	self.frontend:_backend_changed()
end

function window:_unmapped()
	if not self._hidden then return end --minimized, ignore
	self.frontend:_backend_changed()
end

--NOTE: unminimizing triggers this too.
ev[C.MapNotify] = function(e)
	local e = e.xmap
	local self = win(e.window)
	if not self then return end
	self:_mapped()
end

--NOTE: minimizing triggers this too.
ev[C.UnmapNotify] = function(e)
	local e = e.xunmap
	local self = win(e.window)
	if not self then return end
	self:_unmapped()
end

--state/minimizing -----------------------------------------------------------

function window:minimized()
	if self._hidden then
		return self._minimized
	end
	return xlib.get_wm_state(self.win) == C.IconicState
end

function window:minimize()
	if self._hidden then
		self._minimized = true
		self:show()
	else
		xlib.change_wm_state(self.win, C.IconicState)
	end
end

function evprop.WM_STATE(e)
	local self = win(e.window)
	if not self then return end

	if self._hidden then
		local cmd = self._wm_state_cmd
		self._wm_state_cmd = nil --one-time thing
		if cmd == 'map' then
			self:_mapped()
		elseif cmd == 'unmap' then
			self:_unmapped()
		end
	else
		self.frontend:_backend_changed()
	end
end

--state/maximizing -----------------------------------------------------------

function window:_get_maximized_state()
	return xlib.get_net_wm_state(self.win, '_NET_WM_STATE_MAXIMIZED_HORZ') or false
end

function window:maximized()
	if self._hidden then
		return self._maximized
	end
	return self:_get_maximized_state()
end

function window:_set_maximized(maximized)
	xlib.change_net_wm_state(self.win, maximized,
		'_NET_WM_STATE_MAXIMIZED_HORZ',
		'_NET_WM_STATE_MAXIMIZED_VERT')
end

function window:maximize()
	if self._hidden then
		self._maximized = true
		self._minimized = false
		self:show()
		self:_set_maximized(true)
	elseif self:minimized() then
		self:_set_maximized(true)
		self:restore()
	else
		self:_set_maximized(true)
	end
end

function evprop._NET_WM_STATE(e)
	local self = win(e.window)
	if not self then return end
	self._fullscreen = self:_get_fullscreen_state()
	self._maximized = self:_get_maximized_state()
	self.frontend:_backend_changed()
end

--state/restoring ------------------------------------------------------------

function window:restore()
	if self._hidden then
		self:show()
	else
		if self:minimized() then
			xlib.map(self.win)
			--activate window to emulate Windows behavior.
			self:activate()
		elseif self:maximized() then
			self:_set_maximized(false)
		end
	end
end

function window:shownormal()
	if self._hidden then
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
	return xlib.get_net_wm_state(self.win, '_NET_WM_STATE_FULLSCREEN') or false
end

function window:fullscreen()
	if self._hidden then
		return self._fullscreen
	end
	return self:_get_fullscreen_state()
end

function window:enter_fullscreen()
	if self._hidden then
		--NOTE: currently the frontend doesn't allow this because of OSX.
		self._fullscreen = true
		self._minimized = false
		self:show()
		self:enter_fullscreen()
	else
		xlib.change_net_wm_state(self.win, true, '_NET_WM_STATE_FULLSCREEN')
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

function window:get_normal_frame_rect()
	return self:get_frame_rect()
end

function window:set_normal_frame_rect(x, y, w, h)
	self:set_frame_rect(x, y, w, h)
end

function window:get_frame_rect()
	local x, y = self:to_screen(0, 0)
	local w, h = self:get_size()
	return frame_rect(x, y, w, h, self:_frame_extents())
end

function window:set_frame_rect(x, y, w, h)
	local _, _, cw, ch = unframe_rect(x, y, w, h, self:_frame_extents())
	cw = math.max(cw, 1) --prevent error
	ch = math.max(ch, 1)
	xlib.config(self.win, {x = x, y = y, width = cw, height = ch, border_width = 0})
end

function window:get_size()
	local _, _, w, h = xlib.get_geometry(self.win)
	return w, h
end

--positioning/constraints ----------------------------------------------------

function window:_apply_constraints()

	--get the current client size and the new (constrained) client size
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
		cw = math.max(cw, 1) --prevent error
		ch = math.max(ch, 1)
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

ev[C.ConfigureNotify] = function(e)
	local e = e.xconfigure
	local self = win(e.window)
	if not self then return end
	self.frontend:_backend_changed()
end

--positioning/magnets --------------------------------------------------------

--not useful since we can't intervene in window resizing.
function window:magnets() end

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

function app:displays()
	local t = {}
	local screens, n = xlib.xinerama_screens() --the order is undefined
	if screens and n > 1 then --multi-monitor setup
		for i = 0, n-1 do
			local scr = screens[i]
			local x = scr.x_org
			local y = scr.y_org
			local w = scr.width
			local h = scr.height

			--TODO: find a way to get the workarea of each monitor in multi-monitor setups.
			--NOTE: _NET_WORKAREA spans all monitors so it's no good here!
			local cx, cy, cw, ch = x, y, w, h

			t[#t+1] = self.frontend:_display{
				x = x, y = y, w = w, h = h,
				cx = cx, cy = cy, cw = cw, ch = ch,
				scalingfactor = 1}
		end
	else
		--Xinerama not present or single monitor setup
		local x = 0
		local y = 0
		local w = xlib.screen.width
		local h = xlib.screen.height

		local cx, cy, cw, ch

		--get the workarea of the first virtual desktop
		local wa = xlib.get_net_workarea(nil, 1)
		if wa then
			cx, cy, cw, ch = unpack(wa)
		else
			--_NET_WORKAREA not set, fallback to using screen area
			cx, cy, cw, ch = x, y, w, h
		end

		t[1] = self.frontend:_display{
			x = x, y = y, w = w, h = h,
			cx = cx, cy = cy, cw = cw, ch = ch,
			scalingfactor = 1}
	end
	return t
end

function app:display_count()
	local _, n = xlib.xinerama_screens()
	return n or 1
end

function app:_display_overlapping(x, y, w, h)

	--get all displays and the overlapping area between them and the window
	local t = {}
	for i,d in ipairs(self:displays()) do
		local _, _, w1, h1 = box2d.clip(d.x, d.y, d.w, d.h, x, y, w, h)
		t[#t+1] = {area = w1 * h1, display = d}
	end

	--sort displays by overlapping area in descending order.
	table.sort(t, function(t1, t2) return t1.area > t2.area end)

	--return nil if there's no overlapping area i.e. the window is off-screen
	if t[1].area == 0 then return end

	--return the display with the most overlapping
	return t[1].display
end

function app:main_display()
	for i,d in ipairs(self:displays()) do
		if d.x == 0 and d.y == 0 then --main display is at (0, 0) by definition
			return d
		end
	end
end

function app:active_display()
	local display
	local win = xlib.get_input_focus()
	if win then
		--get the client rect of the active window in screen space.
		local cx, cy = xlib.translate_coords(win, xlib.screen.root, 0, 0)
		local _, _, cw, ch = xlib.get_geometry(win)
		--get the display overlapping the active window, if any.
		display = self:_display_overlapping(cx, cy, cw, ch)
	end
	return display or self:main_display()
end

function window:display()
	local x, y, w, h = self:get_frame_rect()
	return self.app:_display_overlapping(x, y, w, h)
end

--TODO:
--self.app.frontend:_backend_displays_changed()

--cursors --------------------------------------------------------------------

function window:update_cursor()
	local visible, name = self.frontend:cursor()
	local cursor = visible and xlib.load_cursor(name) or xlib.blank_cursor()
	xlib.set_cursor(self.win, cursor)
end

--keyboard -------------------------------------------------------------------

local keynames = {
	[C.XK_semicolon]    = ';',  --on US keyboards
	[C.XK_equal]        = '=',
	[C.XK_comma]        = ',',
	[C.XK_minus]        = '-',
	[C.XK_period]       = '.',
	[C.XK_slash]        = '/',
	[C.XK_quoteleft]    = '`',
	[C.XK_bracketleft]  = '[',
	[C.XK_backslash]    = '\\',
	[C.XK_bracketright] = ']',
	[C.XK_apostrophe]   = '\'',

	[C.XK_BackSpace] = 'backspace',
	[C.XK_Tab]       = 'tab',
	[C.XK_space]     = 'space',
	[C.XK_Escape]    = 'esc',
	[C.XK_Return]    = 'enter!',

	[C.XK_F1]  = 'F1',
	[C.XK_F2]  = 'F2',
	[C.XK_F3]  = 'F3',
	[C.XK_F4]  = 'F4',
	[C.XK_F5]  = 'F5',
	[C.XK_F6]  = 'F6',
	[C.XK_F7]  = 'F7',
	[C.XK_F8]  = 'F8',
	[C.XK_F9]  = 'F9',
	[C.XK_F10] = 'F10',
	[C.XK_F11] = 'F11',
	[C.XK_F12] = 'F12',

	[C.XK_Caps_Lock]   = 'capslock',

	[C.XK_Print]       = 'printscreen', --taken (take screenshot); shift+printscreen works
	[C.XK_Scroll_Lock] = 'scrolllock',
	[C.XK_Pause]       = 'break',

	[C.XK_Left]        = 'left!',
	[C.XK_Up]          = 'up!',
	[C.XK_Right]       = 'right!',
	[C.XK_Down]        = 'down!',

	[C.XK_Prior]       = 'pageup!',
	[C.XK_Next]        = 'pagedown!',
	[C.XK_Home]        = 'home!',
	[C.XK_End]         = 'end!',
	[C.XK_Insert]      = 'insert!',
	[C.XK_Delete]      = 'delete!',

	[C.XK_Num_Lock]    = 'numlock',
	[C.XK_KP_Divide]   = 'num/',
	[C.XK_KP_Multiply] = 'num*',
	[C.XK_KP_Subtract] = 'num-',
	[C.XK_KP_Add]      = 'num+',
	[C.XK_KP_Enter]    = 'numenter',
	[C.XK_KP_Delete]   = 'numdelete',
	[C.XK_KP_End]      = 'numend',
	[C.XK_KP_Down]     = 'numdown',
	[C.XK_KP_Next]     = 'numpagedown',
	[C.XK_KP_Left]     = 'numleft',
	[C.XK_KP_Begin]    = 'numclear',
	[C.XK_KP_Right]    = 'numright',
	[C.XK_KP_Home]     = 'numhome',
	[C.XK_KP_Up]       = 'numup',
	[C.XK_KP_Prior]    = 'numpageup',
	[C.XK_KP_Insert]   = 'numinsert',

	[C.XK_Control_L]   = 'lctrl',
	[C.XK_Control_R]   = 'rctrl',
	[C.XK_Shift_L]     = 'lshift',
	[C.XK_Shift_R]     = 'rshift',
	[C.XK_Alt_L]       = 'lalt',
	[C.XK_Alt_R]       = 'ralt',

	[C.XK_Super_L]     = 'lwin',
	[C.XK_Super_R]     = 'rwin',
	[C.XK_Menu]        = 'menu',

	[C.XK_0] = '0',
	[C.XK_1] = '1',
	[C.XK_2] = '2',
	[C.XK_3] = '3',
	[C.XK_4] = '4',
	[C.XK_5] = '5',
	[C.XK_6] = '6',
	[C.XK_7] = '7',
	[C.XK_8] = '8',
	[C.XK_9] = '9',

	[C.XK_a] = 'A',
	[C.XK_b] = 'B',
	[C.XK_c] = 'C',
	[C.XK_d] = 'D',
	[C.XK_e] = 'E',
	[C.XK_f] = 'F',
	[C.XK_g] = 'G',
	[C.XK_h] = 'H',
	[C.XK_i] = 'I',
	[C.XK_j] = 'J',
	[C.XK_k] = 'K',
	[C.XK_l] = 'L',
	[C.XK_m] = 'M',
	[C.XK_n] = 'N',
	[C.XK_o] = 'O',
	[C.XK_p] = 'P',
	[C.XK_q] = 'Q',
	[C.XK_r] = 'R',
	[C.XK_s] = 'S',
	[C.XK_t] = 'T',
	[C.XK_u] = 'U',
	[C.XK_v] = 'V',
	[C.XK_w] = 'W',
	[C.XK_x] = 'X',
	[C.XK_y] = 'Y',
	[C.XK_z] = 'Z',
}

local keysyms = {}
for vk, name in pairs(keynames) do
	keysyms[name:lower()] = vk
end

local function keyname(keycode)
	local sym = xid(xlib.keysym(keycode, 0, 0))
	return keynames[sym]
end

ev[C.KeyPress] = function(e)
	local e = e.xkey
	local self = win(e.window)
	if not self then return end
	if self._disabled then return end

	if self._keypressed then
		self._keypressed = false
		return
	end

	local key = keyname(e.keycode)
	if not key then return end

	self.frontend:_backend_keydown(key)
	self.frontend:_backend_keypress(key)
end

ev[C.KeyRelease] = function(e)
	local e = e.xkey
	local self = win(e.window)
	if not self then return end
	if self._disabled then return end

	local key = keyname(e.keycode)
	if not key then return end

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

--NOTE: scolllock state is not present in XKeyboardState.led_mask by default.
local toggle_keys = {capslock = 1, numlock = 2, scrolllock = 4}

function app:key(name) --name is in lowercase!
	if name:find'^%^' then --'^key' means get the toggle state for that key
		name = name:sub(2)
		local mask = toggle_keys[name]
		if not mask then return false end
		return bit.band(xlib.get_keyboard_control().led_mask, mask) ~= 0
	else
		local sym = keysyms[name]
		if not sym then return false end
		local code = xlib.keycode(sym)
		local keymap = xlib.query_keymap(code)
		return xlib.getbit(code, keymap)
	end
end

--mouse ----------------------------------------------------------------------

local btns = {'left', 'middle', 'right'}

ev[C.ButtonPress] = function(e)
	local e = e.xbutton
	local self = win(e.window)
	if not self then return end
	if self._disabled then return end

	if e.button == C.Button4 then --wheel up
		self.frontend:_backend_mousewheel(3, e.x, e.y)
		return
	elseif e.button == C.Button5 then --wheel down
		self.frontend:_backend_mousewheel(-3, e.x, e.y)
		return
	end

	local btn = btns[e.button]
	if not btn then return end

	self.frontend:_backend_mousedown(btn, e.x, e.y)
end

ev[C.ButtonRelease] = function(e)
	local e = e.xbutton
	local self = win(e.window)
	if not self then return end
	if self._disabled then return end

	local btn = btns[e.button]
	if not btn then return end

	self.frontend:_backend_mouseup(btn, e.x, e.y)
end

ev[C.MotionNotify] = function(e)
	local e = e.xmotion
	local self = win(e.window)
	if not self then return end
	if self._disabled then return end

	self.frontend:_backend_mousemove(e.x, e.y)
end

ev[C.EnterNotify] = function(e)
	local e = e.xcrossing
	local self = win(e.window)
	if not self then return end
	if self._disabled then return end

	self.frontend:_backend_mouseenter()
end

ev[C.LeaveNotify] = function(e)
	local e = e.xcrossing
	local self = win(e.window)
	if not self then return end
	if self._disabled then return end

	self.frontend:_backend_mouseleave()
end

function app:double_click_time()
	return (self:_xsettings'Net/DoubleClickTime' or 400) / 1000 --seconds
end

function app:double_click_target_area()
	return 4, 4 --like in windows
end

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

local function make_bitmap(w, h, win, win_depth, ssbuf)

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

	--NOTE: can't create pix if the window is unmapped.
	local st = xlib.get_wm_state(win)
	if st and st ~= C.WithdrawnState then return end

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

		local pix = xlib.create_pixmap(win, w, h, win_depth)
		local gc = xlib.create_gc(win)

		function paint()
			xlib.put_image(gc, data, size, w, h, win_depth, pix)
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
local function dynbitmap(api, win, depth)

	api = api or {}

	local w, h, bitmap, free, paint
	local ssbuf = slow_resize_buffer('char', 2, 1.2)

	function api:get()
		local w1, h1 = api:size()
		if not bitmap or w1 ~= w or h1 ~= h then
			if bitmap then
				free()
			end
			bitmap, free, paint = make_bitmap(w1, h1, win, depth, ssbuf)
			w, h = w1, h1
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
	if e.count ~= 0 then return end --subregion rendering, skip
	local self = win(e.window)
	if not self then return end

	--skip subregion rendering unless explicitly requested.
	--TODO: if (e.count ~= 0) == (not self.frontend:subregion_rendering()) then return end

	--can't paint the bitmap while the window is unmapped.
	if self._hidden or self:minimized() then return end

	--let the user request the bitmap and draw on it.
	self.frontend:_backend_repaint(e.x, e.y, e.width, e.height)

	--if it did, paint the bitmap onto the window.
	if self._dynbitmap then
		--TODO: paint subregion
		self._dynbitmap:paint()
	end
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
		}, self.win, self._depth)
	end
	--can't paint the bitmap while the window is unmapped.
	if self._hidden or self:minimized() then return end
	return self._dynbitmap:get()
end

function window:invalidate(x, y, w, h)
	if x and y and w and h then
		xlib.clear_area(self.win, x, y, w, h)
	else
		xlib.clear_area(self.win, 0, 0, 2^24, 2^24)
	end
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
