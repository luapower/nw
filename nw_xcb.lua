
--native widgets - XCB backend.
--Written by Cosmin Apreutesei. Public domain.

local ffi = require'ffi'
local bit = require'bit'
local glue = require'glue'
local box2d = require'box2d'
local xcb = require'xcb'
require'xcb_icccm_h' --wm_hints (minimization)
local time = require'time'
local heap = require'heap'
local pp = require'pp'

local C = xcb.C
local cast = ffi.cast
local free = ffi.C.free

local nw = {name = 'xcb'}

--os version -----------------------------------------------------------------

function nw:os(ver)
	return 'Linux 11.0' --11.0 is the X version
end

nw.min_os = 'Linux 11.0'

--xcb state ------------------------------------------------------------------

local c, screen --xcb connection and default screen
local atom --atom resolver

local function check(cookie)
	local err = C.xcb_request_check(c, cookie)
	if err == nil then return cookie end
	local code = err.error_code
	free(err)
	error('XCB error: '..code)
end

local function atom_resolver()
	local resolve = glue.memoize(function(s)
		local cookie = C.xcb_intern_atom(c, 0, #s, s)
		local reply = C.xcb_intern_atom_reply(c, cookie, nil)
		return reply.atom
	end)
	return function(s)
		if type(s) ~= 'string' then return s end --pass through
		return resolve(s)
	end
end

local function atom_list(...)
	local n = select('#', ...)
	local atoms = ffi.new('xcb_atom_t[?]', n)
	for i = 1,n do
		local v = select(i,...)
		atoms[i-1] = atom(v)
	end
	return atoms, n
end

local function list_props(win)
	local cookie = C.xcb_list_properties(c, win)
	local reply = C.xcb_list_properties_reply(c, cookie, nil)
end

local function delete_prop(win, prop)
	C.xcb_delete_property(c, win, atom(prop))
end

local prop_formats = {
	[C.XCB_ATOM_STRING] = 8,
}
local function set_prop(win, prop, type, val, sz)
	local format = prop_formats[type] or 32
	C.xcb_change_property(c, C.XCB_PROP_MODE_REPLACE, win,
		atom(prop), type, format, sz, val)
end

local function get_prop(win, prop, type, decode, sz)
	local cookie = C.xcb_get_property(c, 0, win, atom(prop), type, 0, sz or 0)
	local reply = C.xcb_get_property_reply(c, cookie, nil)
	if not reply then return end
	if reply.format == 32 and reply.type == type then
		local len = C.xcb_get_property_value_length(reply)
		local val = C.xcb_get_property_value(reply)
		local ret = decode(val, len)
		free(reply)
		return ret
	else
		free(reply)
	end
end

local function set_string_prop(win, prop, val, sz)
	set_prop(win, prop, C.XCB_ATOM_STRING, val, sz or #val)
end

local function get_string_prop(win, prop)
	return get_prop(win, prop, C.XCB_ATOM_STRING, ffi.string)
end

local function set_atom_prop(win, prop, val)
	set_prop(win, prop, C.XCB_ATOM_ATOM, atom_list(val))
end

local function set_atom_map_prop(win, prop, t)
	local atoms, n = atom_list(unpack(glue.keys(t)))
	if n == 0 then
		delete_prop(win, prop)
	else
		set_prop(win, prop, C.XCB_ATOM_ATOM, atoms, n)
	end
end

local function decode_atom_map(val, len)
	local val = ffi.cast('xcb_atom_t*', val)
	local t = {}
	for i = 0, len-1 do
		t[val[i]] = true
	end
	return t
end
local function get_atom_map_prop(win, prop)
	return get_prop(win, prop, C.XCB_ATOM_ATOM, decode_atom_map, 1024)
end

local function set_cardinal_prop(win, prop, val)
	local buf = ffi.new('int32_t[1]', val)
	set_prop(win, prop, C.XCB_ATOM_CARDINAL, buf, 1)
end

local function decode_window(val, len)
	if len == 0 then return end
	return ffi.cast('xcb_window_t*', val)[0]
end
local function get_window_prop(win, prop)
	return get_prop(win, prop, C.XCB_ATOM_WINDOW, decode_window, 1)
end

local function client_message_event(win, type, format)
	local e = ffi.new'xcb_client_message_event_t'
	e.window = win
	e.response_type = C.XCB_CLIENT_MESSAGE
	e.type = atom(type)
	e.format = format
	return e
end

local function atom_list_event(win, type, ...)
	local e = client_message_event(win, type, 32)
	for i = 1,5 do
		local v = select(i, ...)
		if v then
			e.data.data32[i-1] = atom(v)
		end
	end
	return e
end

local function send_client_message(win, e, propagate, mask)
	C.xcb_send_event(c, propagate or false, win, mask or 0, cast('const char*', e))
end

local function send_client_message_to_root(e)
	local mask = bit.bor(
		C.XCB_EVENT_MASK_SUBSTRUCTURE_NOTIFY,
		C.XCB_EVENT_MASK_SUBSTRUCTURE_REDIRECT)
	send_client_message(screen.root, e, false, mask)
end

local function activate_window(win, focused_win)
	local e = client_message_event(win, '_NET_ACTIVE_WINDOW', 32)
	e.data.data32[0] = 1 --message comes from an app
	e.data.data32[1] = 0 --TODO: current time?
	e.data.data32[2] = focused_win or C.XCB_NONE
	send_client_message_to_root(e)
end

local function set_netwm_state(win, set, atom1, atom2)
	local e = atom_list_event(win, '_NET_WM_STATE', set and 1 or 0, atom1, atom2)
	send_client_message_to_root(e)
end

local function get_netwm_states(win)
	return get_atom_map_prop(win, '_NET_WM_STATE')
end

local function minimize(win)
	local e = client_message_event(win, 'WM_CHANGE_STATE', 32)
	e.data.data32[0] = C.XCB_ICCCM_WM_STATE_ICONIC
	send_client_message_to_root(e)
end

local function xcb_iterator(iter_func, next_func)
	local function next(state, last)
		if last then
			next_func(state)
		end
		if state.rem == 0 then return end
		return state.data
	end
	return function(...)
		local state = iter_func(...)
		return next, state
	end
end

local function decode_hints(val, len)
	return ffi.new('xcb_icccm_wm_hints_t', ffi.cast('xcb_icccm_wm_hints_t*', val)[0])
end
local function get_wm_hints(win)
	return get_prop(win, C.XCB_ATOM_WM_HINTS, C.XCB_ATOM_WM_HINTS,
		decode_hints, C.XCB_ICCCM_NUM_WM_HINTS_ELEMENTS)
end

local function set_wm_hints(win, hints)
	set_prop(win, C.XCB_ATOM_WM_HINTS, C.XCB_ATOM_WM_HINTS, hints,
		C.XCB_ICCCM_NUM_WM_HINTS_ELEMENTS)
end

--TODO: always returns one screen
local screen_iterator = xcb_iterator(
	C.xcb_setup_roots_iterator, C.xcb_screen_next)

local function screens()
	return screen_iterator(C.xcb_get_setup(c))
end

local function get_screen(n)
	local i = 0
	for screen in screens() do
		if i == n then
			return screen
		end
		i = i + 1
	end
end

local depths = xcb_iterator(
	C.xcb_screen_allowed_depths_iterator, C.xcb_depth_next)

local visuals = xcb_iterator(
	C.xcb_depth_visuals_iterator, C.xcb_visualtype_next)

local visual_map = glue.memoize(function(screen)
	local t = {}
	for depth in depths(screen) do
		for visual in visuals(depth) do
			t[visual.visual_id] = visual
		end
	end
	return t
end)

local function visual(visual_id, screen_)
	return visual_map(screen_ or screen)[visual_id]
end

local function xcb_has_shm()
	local cookie = C.xcb_shm_query_version(c)
	local reply = C.xcb_shm_query_version_reply(c, cookie, nil)
	return reply ~= nil and reply.shared_pixmaps ~= 0
end

local function xcb_connect(displayname)
	local n = ffi.new'int[1]'
	c = C.xcb_connect(displayname, n)
	assert(C.xcb_connection_has_error(c) == 0)
	return c, n[0]
end

local function xcb_init()
	local n
	c, n = xcb_connect()
	atom = atom_resolver(c)
	screen = get_screen(n)
end

--window handle to window object mapping -------------------------------------

--NOTE: xcb_window_t is an uint32_t so it comes from ffi as a Lua number
--so it can be used as table key directly.

local winmap = {} --{xcb_window_t -> window object}
local function setwin(win, x) winmap[win] = x end
local function getwin(win) return winmap[win] end
local function nextwin() return next(winmap) end

--app object -----------------------------------------------------------------

local app = {}
nw.app = app

function app:new(frontend)
	self = glue.inherit({frontend = frontend}, self)
	xcb_init()
	return self
end

--message loop ---------------------------------------------------------------

local ev = {} --{xcb_event_code = event_handler}

local function check_errors(e)
	if e.response_type ~= 0 then return end --not an error
	local code = e.error_code
	free(e)
	error('XCB error: '..code)
end

local peeked_event

local function peek_event()
	if not peeked_event then
		local e = C.xcb_poll_for_event(c)
		if e == nil then return end
		check_errors(e)
		peeked_event = e
	end
	return peeked_event
end

--how much to wait before polling again.
--checking more often increases CPU usage!
app._poll_interval = 0.02

local last_poll_time

function app:_sleep()
	local busy_interval = time.clock() - last_poll_time
	local sleep_interval = self._poll_interval - busy_interval
	if sleep_interval > 0 then
		time.sleep(sleep_interval)
	end
end

function app:run()
	local e
	while true do
		last_poll_time = time.clock()
		while true do
			if peeked_event then
				e, peeked_event = peeked_event, nil
			else
				e = C.xcb_poll_for_event(c)
				if e == nil then
					self:_check_timers()
					self:_sleep()
					break
				else
					check_errors(e)
				end
			end
			local v = bit.band(e.response_type, bit.bnot(0x80))
			local f = ev[v]
			if f then
				local ok, ret = xpcall(f, debug.traceback, e)
				if not ok then
					free(e)
					error(ret, 2)
				end
			end
			free(e)
			if self._stop then
				return --stop the loop
			end
		end
	end
end

--[[
function app:_send_custom_message(...)
	local win, winobj = nextwin() --any window will do
	local dummy_win
	if not win or winobj.frontend:dead() then
		--create a dummy window so we can send a message to it, which is
		--the only way to unblock the event loop.
		win = C.xcb_generate_id(c)
		check(C.xcb_create_window_checked(c, C.XCB_COPY_FROM_PARENT, win,
			screen.root, 0, 0, 1, 1, 0,
			C.XCB_WINDOW_CLASS_INPUT_ONLY,
			screen.root_visual, 0, nil))
		dummy_win = true
	end
	--send a custom "stop loop" event to any window
	send_client_message(win, atom_list_event(win, ...))
	if dummy_win then
		C.xcb_destroy_window(c, win)
	end
	C.xcb_flush(c)
end
]]

function app:stop()
	self._stop = true
end

--time -----------------------------------------------------------------------

function app:time()
	return time.clock()
end

function app:timediff(start_time, end_time)
	return end_time - start_time
end

--timers ---------------------------------------------------------------------

local function cmp(t1, t2)
	return t1.time < t2.time
end
local timers = heap.valueheap{cmp = cmp}

function app:_check_timers()
	while timers:length() > 0 do
		local t = timers:peek()
		local now = time.clock()
		if now + self._poll_interval / 2 > t.time then
			if t.func() == false then
				timers:pop()
			else
				t.time = now + t.interval
				timers:replace(1, t)
			end
		else
			break
		end
	end
end

function app:runevery(seconds, func)
	timers:push({time = time.clock() + seconds, interval = seconds, func = func})
end

--windows --------------------------------------------------------------------

--bind getpid() for setting _NET_WM_PID.
ffi.cdef'int32_t getpid()'
local getpid = ffi.C.getpid

local window = {}
app.window = window

function window:new(app, frontend, t)
	self = glue.inherit({app = app, frontend = frontend}, self)

	--helper to populate the values array for xcb_create_window().
	local mask = 0
	local i, n = 0, 4
	local values = ffi.new('uint32_t[?]', n)
	local function addvalue(maskbit, value)
		assert(i < n)          --increase n to add more values!
		assert(maskbit > mask) --values must be added in enum order!
		mask = bit.bor(mask, maskbit)
		values[i] = value
		i = i + 1
	end

	--say that we don't want the server to keep a pixmap for the window.
	addvalue(C.XCB_CW_BACK_PIXMAP, C.XCB_BACK_PIXMAP_NONE)

	--needed if we want to set a value for XCB_CW_COLORMAP too!
	addvalue(C.XCB_CW_BORDER_PIXEL, 0)

	--declare what events we want to receive.
	addvalue(C.XCB_CW_EVENT_MASK, bit.bor(
		C.XCB_EVENT_MASK_KEY_PRESS,
		C.XCB_EVENT_MASK_KEY_RELEASE,
		C.XCB_EVENT_MASK_BUTTON_PRESS,
		C.XCB_EVENT_MASK_BUTTON_RELEASE,
		C.XCB_EVENT_MASK_ENTER_WINDOW,
		C.XCB_EVENT_MASK_LEAVE_WINDOW,
		C.XCB_EVENT_MASK_POINTER_MOTION,
		C.XCB_EVENT_MASK_POINTER_MOTION_HINT,
		C.XCB_EVENT_MASK_BUTTON_1_MOTION,
		C.XCB_EVENT_MASK_BUTTON_2_MOTION,
		C.XCB_EVENT_MASK_BUTTON_3_MOTION,
		C.XCB_EVENT_MASK_BUTTON_4_MOTION,
		C.XCB_EVENT_MASK_BUTTON_5_MOTION,
		C.XCB_EVENT_MASK_BUTTON_MOTION,
		C.XCB_EVENT_MASK_KEYMAP_STATE,
		C.XCB_EVENT_MASK_EXPOSURE,
		C.XCB_EVENT_MASK_VISIBILITY_CHANGE,
		C.XCB_EVENT_MASK_STRUCTURE_NOTIFY,
		C.XCB_EVENT_MASK_RESIZE_REDIRECT,
		C.XCB_EVENT_MASK_SUBSTRUCTURE_NOTIFY,
		C.XCB_EVENT_MASK_SUBSTRUCTURE_REDIRECT,
		C.XCB_EVENT_MASK_FOCUS_CHANGE,
		C.XCB_EVENT_MASK_PROPERTY_CHANGE,
		C.XCB_EVENT_MASK_COLOR_MAP_CHANGE,
		C.XCB_EVENT_MASK_OWNER_GRAB_BUTTON
	))

	local parent = t.parent and t.parent.backend.win or screen.root

	--default depth and visual
	local depth = C.XCB_COPY_FROM_PARENT
	local visual = screen.root_visual

	--check if screen has a 32bit depth visual and if it does,
	--create a colormap for it and add it to the window values array.
	--this allows us to create a 32bit-depth window (i.e. with alpha).
	for d in depths(screen) do
		if d.depth == 32 then
			for v in visuals(d) do
				visual = v.visual_id
				depth = 32
				local colormap = C.xcb_generate_id(c)
				C.xcb_create_colormap(c, C.XCB_COLORMAP_ALLOC_NONE, colormap, parent, visual)
				addvalue(C.XCB_CW_COLORMAP, colormap)
				break
			end
			break
		end
	end

	self.win = C.xcb_generate_id(c)

	C.xcb_create_window(
		c, depth, self.win, parent,
		0, 0, --x, y (ignored, set later)
		t.w, t.h,
		0, --border width (ignored)
		C.XCB_WINDOW_CLASS_INPUT_OUTPUT, --class
		visual, mask, values)

	--declare the X protocols that the window supports.
	set_atom_map_prop(self.win, 'WM_PROTOCOLS', {
		WM_DELETE_WINDOW = true, --don't close the connection when a window is closed
		WM_TAKE_FOCUS = true,    --allow focusing the window programatically
		_NET_WM_PING = true,     --respond to ping events
	})

	--set pid for _NET_WM_PING protocol to allow the user to kill a non-responsive process.
	set_cardinal_prop(self.win, '_NET_WM_PID', getpid())

	if t.title then
		self:set_title(t.title)
	end

	if t.frame == 'toolbox' then
		set_atom_prop(self.win, '_NET_WM_WINDOW_TYPE', '_NET_WM_WINDOW_TYPE_TOOLBAR')
	end

	if t.visible then
		C.xcb_map_window(c, self.win)
	end

	--NOTE: setting the window's position only works after the window is mapped.
	if t.x or t.y then
		local xy = ffi.new('int32_t[2]', t.x, t.y)
		C.xcb_configure_window(c, self.win,
			bit.bor(C.XCB_CONFIG_WINDOW_X, C.XCB_CONFIG_WINDOW_Y), xy)
	end

	set_atom_map_prop(self.win, '_NET_WM_STATE', {
		_NET_WM_STATE_ABOVE          = t.topmost or nil,
		_NET_WM_STATE_MAXIMIZED_HORZ = t.maximized or nil,
		_NET_WM_STATE_MAXIMIZED_VERT = t.maximized or nil,
		_NET_WM_STATE_FULLSCREEN     = t.fullscreen or nil,
	})

	C.xcb_flush(c)

	setwin(self.win, self)

	--[[
	self._layered = t.frame == 'none-transparent'

	self.win = Window{
		min_cw = t.min_cw,
		min_ch = t.min_ch,
		max_cw = t.max_cw,
		max_ch = t.max_ch,
		enabled = t.enabled,
		--frame
		border = framed,
		frame = framed,
		window_edge = framed, --must be off for frameless windows!
		layered = self._layered,
		owner = t.parent and t.parent.backend.win,
		--behavior
		minimize_button = t.minimizable,
		maximize_button = t.maximizable,
		noclose = not t.closeable,
		sizeable = framed and t.resizeable, --must be off for frameless windows!
		activable = t.activable,
		receive_double_clicks = false, --we do our own double-clicking
		remember_maximized_pos = true, --to emulate OSX behavior for constrained maximized windows
	}
	]]

	return self
end

--closing --------------------------------------------------------------------

function window:_ping_event(e)
	local reply = ffi.new('xcb_client_message_event_t', e[0])
	reply.response_type = C.XCB_CLIENT_MESSAGE
	reply.window = screen.root
	send_client_message_to_root(reply) --pong!
end

ev[C.XCB_CLIENT_MESSAGE] = function(e)
	e = cast('xcb_client_message_event_t*', e)
	local self = getwin(e.window)
	if not self then return end --not for us
	local v = e.data.data32[0]
	if e.type == atom'WM_PROTOCOLS' then
		if v == atom'WM_DELETE_WINDOW' then
			if self.frontend:_backend_closing() then
				self:forceclose()
			end
		elseif v == atom'WM_TAKE_FOCUS' then
			--ha?
		elseif v == atom'_NET_WM_PING' then
			self:_ping_event(e)
		end
	end
end

function window:forceclose()
	C.xcb_destroy_window_checked(c, self.win)
	C.xcb_flush(c)
	self.frontend:_backend_closed()
	setwin(self.win, nil)
end

--activation -----------------------------------------------------------------

--app: self.frontend:_backend_activated()
--app: self.frontend:_backend_deactivated()
--window: self.frontend:_backend_activated()
--window: self.frontend:_backend_deactivated()

function app:activate()

end

function app:active_window()
	local win = get_window_prop(screen.root, '_NET_ACTIVE_WINDOW')
	return getwin(win)
end

function app:active()
	return true
end

function window:activate()
	--TODO: try activate_window() instead? what's the diff?
	C.xcb_set_input_focus_checked(c, C.XCB_INPUT_FOCUS_NONE,
		self.win, C.XCB_CURRENT_TIME)
	C.xcb_flush(c)
end

function window:active()
	return app:active_window() == self
end

--state/visibility -----------------------------------------------------------

function window:visible()
	return true
end

function window:show()
	C.xcb_map_window_checked(c, self.win)
	C.xcb_flush(c)
end

function window:hide()
	C.xcb_unmap_window_checked(c, self.win)
	C.xcb_flush(c)
end

--state/minimizing -----------------------------------------------------------

function window:minimized()
	local hints = get_wm_hints(self.win) --TODO: returns nil
	return hints and bit.band(hints.initial_state, C.XCB_ICCCM_WM_STATE_ICONIC) ~= 0
end

function window:minimize()
	minimize(self.win)
end

--state/maximizing -----------------------------------------------------------

function window:maximized()
	local states = get_netwm_states(self.win)
	return
		states[atom'_NET_WM_STATE_MAXIMIZED_HORZ'] and
		states[atom'_NET_WM_STATE_MAXIMIZED_VERT']
end

function window:maximize()
	set_netwm_state(self.win, true,
		'_NET_WM_STATE_MAXIMIZED_HORZ',
		'_NET_WM_STATE_MAXIMIZED_VERT')
end

--state/restoring ------------------------------------------------------------

function window:restore()
	set_netwm_state(self.win, false,
		'_NET_WM_STATE_MAXIMIZED_HORZ',
		'_NET_WM_STATE_MAXIMIZED_VERT')
end

function window:shownormal()
	set_netwm_state(self.win, false,
		'_NET_WM_STATE_MAXIMIZED_HORZ',
		'_NET_WM_STATE_MAXIMIZED_VERT')
end

--state/changed event --------------------------------------------------------

--self.frontend:_backend_changed()

--state/fullscreen -----------------------------------------------------------

function window:fullscreen()
	return get_netwm_states(self.win)[atom'_NET_WM_STATE_FULLSCREEN']
end

function window:enter_fullscreen()
	set_netwm_state(self.win, true, '_NET_WM_STATE_FULLSCREEN')
end

function window:exit_fullscreen()
	set_netwm_state(self.win, false, '_NET_WM_STATE_FULLSCREEN')
end

--state/enabled --------------------------------------------------------------

function window:get_enabled()
end

function window:set_enabled(enabled)
end

--positioning/conversions ----------------------------------------------------

function window:to_screen(x, y)
end

function window:to_client(x, y)
end

function app:client_to_frame(frame, x, y, w, h)
end

function app:frame_to_client(frame, x, y, w, h)
end

--positioning/rectangles -----------------------------------------------------

local function translate(c, src_win, dst_win, x, y)
	local cookie = C.xcb_translate_coordinates(c, src_win, dst_win, x, y)
	local reply = C.xcb_translate_coordinates_reply(c, cookie, nil)
	local x, y =
		reply.dst_x,
		reply.dst_y
	free(reply)
	return x, y
end

function window:get_normal_rect()
	local cookie = C.xcb_get_window_attributes(c, self.win)
	local reply = C.xcb_get_window_attributes_reply(c, cookie, nil)
	local visual = visual(reply.visual)
	local x, y, w, h =
		visual.x,
		visual.y,
		visual.width,
		visual.height
	free(reply)
	return x, y, w, h
end

function window:set_normal_rect(x, y, w, h)
 	local xy = ffi.new('uint32_t[2]', x, y)
 	local wh = ffi.new('uint32_t[2]', w, h)
	C.xcb_configure_window_checked(c, self.win,
		bit.bor(C.XCB_CONFIG_WINDOW_X, C.XCB_CONFIG_WINDOW_Y), xy)
	C.xcb_configure_window_checked(c, self.win,
		bit.bor(C.XCB_CONFIG_WINDOW_WIDTH, C.XCB_CONFIG_WINDOW_HEIGHT), wh)
	C.xcb_flush(c)
end

function window:get_frame_rect()
	local x, y, w, h = self:get_normal_rect()
	x, y = translate(c, self.win, 0, x, y)
	return x, y, w, h
end

function window:set_frame_rect(x, y, w, h)

end

function window:get_size()
	local _, _, w, h = self:get_frame_rect()
	return w, h
end

--positioning/constraints ----------------------------------------------------

function window:get_minsize()
end

function window:set_minsize(w, h)
end

function window:get_maxsize()
end

function window:set_maxsize(w, h)
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
	return get_string_prop(self.win, C.XCB_ATOM_WM_NAME)
end

function window:set_title(title)
	set_string_prop(self.win, C.XCB_ATOM_WM_NAME, title)
end

--z-order --------------------------------------------------------------------

function window:get_topmost()
	return get_netwm_states(self.win)[atom'_NET_WM_STATE_ABOVE']
end

function window:set_topmost(topmost)
	set_netwm_state(self.win, topmost, atom'_NET_WM_STATE_ABOVE')
end

function window:set_zorder(mode, relto)
end

--displays -------------------------------------------------------------------

function app:_display(screen)
	return self.frontend:_display{
		x = 0, --TODO
		y = 0,
		w = screen.width_in_pixels,
		h = screen.height_in_pixels,
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
	return C.xcb_setup_roots_length(C.xcb_get_setup(c))
end

function window:display()
	--
end

--self.app.frontend:_backend_displays_changed()

--cursors --------------------------------------------------------------------

function window:cursor(name)
end

--keyboard -------------------------------------------------------------------

ev[C.XCB_KEY_PRESS] = function(e)
	local e = cast('xcb_key_press_event_t*', e)
	local self = getwin(e.event)
	if not self then return end
	if self._keypressed then
		self._keypressed = false
		return
	end
	local key = e.detail
	--print('sequence: ', e.sequence)
	--print('state:    ', e.state)
	self.frontend:_backend_keydown(key)
	self.frontend:_backend_keypress(key)
end

ev[C.XCB_KEY_RELEASE] = function(e)
	local e = cast('xcb_key_press_event_t*', e)
	local self = getwin(e.event)
	if not self then return end
	local key = e.detail

	--peek next message to distinguish between key release and key repeat
 	local e1 = peek_event()
 	if e1 then
 		local v = bit.band(e1.response_type, bit.bnot(0x80))
 		if v == C.XCB_KEY_PRESS then
			local e1 = cast('xcb_key_press_event_t*', e1)
 			if e1.time == e.time and e1.detail == e.detail then
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

ev[C.XCB_BUTTON_PRESS] = function(e)
	e = cast('xcb_button_press_event_t*', e)
	local self = getwin(e.event)
	if not self then return end

	local btn = btns[e.detail]
	if not btn then return end
	local x, y = 0, 0
	self.frontend:_backend_mousedown(btn, x, y)
end

ev[C.XCB_BUTTON_RELEASE] = function(e)
	e = cast('xcb_button_press_event_t*', e)
	local self = getwin(e.event)
	if not self then return end

	local btn = btns[e.detail]
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
- you can't create a xcb_drawable_t, that's just an abstraction: instead,
  any xcb_pixmap_t or xcb_window_t can be used where a xcb_drawable_t
  is expected (they're all int32 ids btw).
- the default screen visual has 24 depth, but a screen can have many visuals.
  if it has a 32 depth visual, then we can make windows with alpha.
- a window with alpha needs XCB_CW_COLORMAP which needs XCB_CW_BORDER_PIXEL.
]]

local function make_bitmap(w, h, win)

	local stride = w * 4
	local size = stride * h

	local bitmap = {
		w      = w,
		h      = h,
		stride = stride,
		size   = size,
		format = 'bgra8',
	}

	local paint, free

	if false and xcb_has_shm() then

		local shmid = shm.shmget(shm.IPC_PRIVATE, size, bit.bor(shm.IPC_CREAT, 0x1ff))
		local data  = shm.shmat(shmid, 0, 0)

		local shmseg  = C.xcb_generate_id(c)
		C.xcb_shm_attach(c, shmseg, shmid, 0)
		shm.shmctl(shmid, shm.IPC_RMID, 0)

		local pix = C.xcb_generate_id(c)

		C.xcb_shm_create_pixmap(c, pix, self.win, w, h, depth_id, shmseg, 0)

		C.xcb_flush(c)

		bitmap.data = data

		function paint()
			C.xcb_copy_area(c, pix, win, gcontext, 0, 0, 0, 0, w, h)
			C.xcb_flush(c)
		end

		function free()
			C.xcb_shm_detach(c, shmseg)
			shm.shmdt(data)
			C.xcb_free_pixmap(c, pix)
		end

	else

		local pix = C.xcb_generate_id(c)
		C.xcb_create_pixmap(c, 32, pix, win, w, h)

		local data = glue.malloc('char', size)
		bitmap.data = data

		local gc = C.xcb_generate_id(c)
		C.xcb_create_gc(c, gc, win, 0, 0)

		function paint()
			print(w, h)
			C.xcb_put_image(c, C.XCB_IMAGE_FORMAT_Z_PIXMAP,
				win, gc, w, h, 0, 0, 0, 32, size, data)
		end

		function free()
			C.xcb_free_gc(c, gc)
			C.xcb_free_pixmap_checked(c, pix)
			glue.free(data)
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

	local w, h, bitmap, free, paint

	function api:get()
		local w1, h1 = api:size()
		if w1 ~= w or h1 ~= h then
			self:free()
			bitmap, free, paint = make_bitmap(w1, h1, win)
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

ev[C.XCB_EXPOSE] = function(e)
	local e = cast('xcb_expose_event_t*', e)
	if e.count ~= 0 then return end --subregion rendering
	local self = getwin(e.window)
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


if not ... then require'nw_test' end

return nw
