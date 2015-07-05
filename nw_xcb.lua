
--native widgets - XCB backend.
--Written by Cosmin Apreutesei. Public domain.

if not ... then require'nw_test'; return end

local ffi = require'ffi'
local bit = require'bit'
local glue = require'glue'
local box2d = require'box2d'
local xcb = require'xcb'
require'xcb_shm_h'
require'xcb_icccm_h' --wm_hints (minimization)
local time = require'time'
local heap = require'heap'
local pp = require'pp'
local shm = require'shm'
local ok, xcbshm = pcall(ffi.load, 'xcb-shm.so.0')
xcbshm = ok and xcbshm

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
		local atom = reply.atom
		free(reply)
		return atom
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

local atom_name = glue.memoize(function(atom)
	local cookie = C.xcb_get_atom_name(c, atom)
	local reply = C.xcb_get_atom_name_reply(c, cookie, nil)
	if reply == nil then return end
	local n = C.xcb_get_atom_name_name_length(reply)
	local s = C.xcb_get_atom_name_name(reply)
	local s = ffi.string(s, n)
	free(reply)
	return s
end)

local function list_props(win)
	local cookie = C.xcb_list_properties(c, win)
	local reply = C.xcb_list_properties_reply(c, cookie, nil)
	local n = C.xcb_list_properties_atoms_length(reply)
	local atomp = C.xcb_list_properties_atoms(reply)
	local t = {}
	for i=1,n do
		t[i] = atom_name(atomp[i-1])
	end
	free(reply)
	return t
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

local function pass(reply, ...)
	free(reply)
	return ...
end
local function get_prop(win, prop, type, decode, sz)
	local format = prop_formats[type] or 32
	local cookie = C.xcb_get_property(c, 0, win, atom(prop), type, 0, sz or 0)
	local reply = C.xcb_get_property_reply(c, cookie, nil)
	if not reply then return end
	if reply.format == format and reply.type == type then
		local val = C.xcb_get_property_value(reply)
		if val == nil then return end
		local len = C.xcb_get_property_value_length(reply)
		return pass(reply, decode(val, len))
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

local function decode_window_list(val, len)
	val = ffi.cast('xcb_window_t*', val)
	local t = {}
	for i=1,len do
		t[i] = val[i-1]
	end
	return t
end
local function get_window_list_prop(win, prop)
	return get_prop(win, prop, C.XCB_ATOM_WINDOW, decode_window_list, 1024)
end

local function client_message_event(win, type, format)
	local e = ffi.new'xcb_client_message_event_t'
	e.window = win
	e.response_type = C.XCB_CLIENT_MESSAGE
	e.type = atom(type)
	e.format = format or 32
	return e
end

local function list_event(win, type, datatype, val_func, ...)
	local e = client_message_event(win, type)
	for i = 1,5 do
		local v = select(i, ...)
		if v then
			e.data[datatype][i-1] = val_func(v)
		end
	end
	return e
end

local function int32_list_event(win, type, ...)
	return list_event(win, type, 'data32', glue.pass)
end

local function atom_list_event(win, type, ...)
	return list_event(win, type, 'data32', atom)
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
	local e = int32_list_event(win, '_NET_ACTIVE_WINDOW',
		1, --message comes from an app
		0, --timestamp
		focused_win or C.XCB_NONE)
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
	local e = client_message_event(win, 'WM_CHANGE_STATE')
	e.data.data32[0] = C.XCB_ICCCM_WM_STATE_ICONIC
	send_client_message_to_root(e)
end

local function xcb_iterator(iter_func, next_func, val_func)
	val_func = val_func or glue.pass
	local function next(state, last)
		if last then
			next_func(state)
		end
		if state.rem == 0 then return end
		return val_func(state.data)
	end
	return function(...)
		local state = iter_func(...)
		return next, state
	end
end

local function decode_wm_hints(val, len)
	return ffi.new('xcb_icccm_wm_hints_t', ffi.cast('xcb_icccm_wm_hints_t*', val)[0])
end
local function get_wm_hints(win)
	return get_prop(win, C.XCB_ATOM_WM_HINTS, C.XCB_ATOM_WM_HINTS,
		decode_wm_hints, C.XCB_ICCCM_NUM_WM_HINTS_ELEMENTS)
end

local function set_wm_hints(win, hints)
	set_prop(win, C.XCB_ATOM_WM_HINTS, C.XCB_ATOM_WM_HINTS, hints,
		C.XCB_ICCCM_NUM_WM_HINTS_ELEMENTS)
end

local function decode_wm_size_hints(val, len)
	return ffi.new('xcb_icccm_wm_size_hints_t', ffi.cast('xcb_icccm_wm_size_hints_t*', val)[0])
end
local function get_wm_normal_hints(win)
	return get_prop(win, C.XCB_ATOM_WM_NORMAL_HINTS, C.XCB_ATOM_WM_SIZE_HINTS,
		decode_wm_size_hints, C.XCB_ICCCM_NUM_WM_SIZE_HINTS_ELEMENTS)
end

local function set_wm_normal_hints(win, hints)
	return set_prop(win, C.XCB_ATOM_WM_NORMAL_HINTS, C.XCB_ATOM_WM_SIZE_HINTS,
		hints, C.XCB_ICCCM_NUM_WM_SIZE_HINTS_ELEMENTS)
end

local function str_tostring(str)
	local s = C.xcb_str_name(str)
	return ffi.string(s, str.name_len)
end
local extensions_iter = xcb_iterator(
	C.xcb_list_extensions_names_iterator, C.xcb_str_next, str_tostring)
local function xcb_extensions()
	local cookie = C.xcb_list_extensions(c)
	local reply = C.xcb_list_extensions_reply(c, cookie, nil)
	--TODO: free reply
	return extensions_iter(reply)
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
	if not xcbshm then return end
	local cookie = xcbshm.xcb_shm_query_version(c)
	local reply = xcbshm.xcb_shm_query_version_reply(c, cookie, nil)
	local ret = reply ~= nil and reply.shared_pixmaps ~= 0
	free(reply)
	return ret
end

local function query_tree(win)
	local cookie = C.xcb_query_tree(c, win)
	local reply = C.xcb_query_tree_reply(c, cookie, nil)
	local winp = C.xcb_query_tree_children(reply)
	local n = C.xcb_query_tree_children_length(reply)
	local t = {}
	for i=1,n do
		t[i] = winp[i-1]
	end
	local t = {
		root = reply.root,
		parent = reply.parent ~= 0 and reply.parent or nil,
		children = t,
	}
	free(reply)
	return t
end

local xcb_net_supported_map = glue.memoize(function()
	return get_atom_map_prop(screen.root, '_NET_SUPPORTED')
end)

local function xcb_net_supported(s)
	return xcb_net_supported_map()[atom(s)]
end

--request frame extents estimation from the WM
local function request_frame_extents(win)
	local e = client_message_event(win, atom'_NET_REQUEST_FRAME_EXTENTS')
	send_client_message_to_root(e)
end

local function decode_extents(val)
	val = cast('int32_t*', val)
	return val[0], val[2], val[1], val[3] --left, top, right, bottom
end
local function xcb_frame_extents(win)
	if not xcb_net_supported'_NET_REQUEST_FRAME_EXTENTS' then
		return 0, 0, 0, 0
	end
	return get_prop(win, atom'_NET_FRAME_EXTENTS', C.XCB_ATOM_CARDINAL, decode_extents, 4)
end

local function xcb_translate_coords(src_win, dst_win, x, y)
	local cookie = C.xcb_translate_coordinates(c, src_win, dst_win, x, y)
	local reply = C.xcb_translate_coordinates_reply(c, cookie, nil)
	assert(reply ~= nil)
	local x, y = reply.dst_x, reply.dst_y
	free(reply)
	return x, y
end

--check if a given screen has a visual for a target depth.
local function xcb_find_visual(screen, depth)
	for d in depths(screen) do
		if d.depth == depth then
			for v in visuals(d) do
				if v.bits_per_rgb_value == 8 and v.blue_mask == 0xff then --BGRA8
					return depth, v.visual_id
				end
			end
		end
	end
end

local function xcb_change_pos(win, cx, cy)
	local xy = ffi.new('int32_t[2]', cx, cy)
	C.xcb_configure_window(c, win,
		bit.bor(C.XCB_CONFIG_WINDOW_X, C.XCB_CONFIG_WINDOW_Y), xy)
end

local function xcb_change_size(win, cw, ch)
	local wh = ffi.new('int32_t[2]', cw, ch)
	C.xcb_configure_window(c, self.win,
		bit.bor(C.XCB_CONFIG_WINDOW_WIDTH, C.XCB_CONFIG_WINDOW_HEIGHT), wh)
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

--check an X extension or return all extensions.
local extensions = glue.memoize(function()
	local t = {}
	for x in xcb_extensions() do
		t[x:lower():gsub('[- ]', '_')] = true
	end
	return t
end)
function app:ext(ext)
	if ext then
		return extensions()[ext:lower():gsub('[- ]', '_')]
	end
	return extensions()
end

function app:virtual_roots()
	return get_window_list_prop(screen.root, '_NET_VIRTUAL_ROOTS')
end

local function atom_names(t)
	local dt = {}
	for atom in pairs(t) do
		local name = atom_name(atom)
		if name then
			dt[name] = atom
		end
	end
	return dt
end

--message loop ---------------------------------------------------------------

local ev = {} --{xcb_event_code = event_handler}

local function check_event(e)
	if e == nil then return end
	if e.response_type == 0 then
		e = ffi.cast('xcb_generic_error_t*', e)
		local code = e.error_code
		free(e)
		error('XCB error: '..code)
	end
	return e, bit.band(e.response_type, bit.bnot(0x80))
end

local function xcb_poll(e)
	return check_event(C.xcb_poll_for_event(c))
end

local function xcb_wait(e)
	return check_event(C.xcb_wait_for_event(c))
end

local peeked_event, peeked_etype

local function peek_event()
	if not peeked_event then
		peeked_event, peeked_etype = xcb_poll()
	end
	return peeked_event, peeked_etype
end

function poll_event(wait)
	local e, etype
	if peeked_event then
		e, etype = peeked_event, peeked_etype
		peeked_event, peeked_etype = nil
	else
		local poll_or_wait = wait and xcb_wait or xcb_poll
		e, etype = poll_or_wait()
		if not e then return end
	end
	--print('EVENT', etype)
	local f = ev[etype]
	if f then
		local ok, ret = xpcall(f, debug.traceback, e)
		if not ok then
			free(e)
			error(ret, 2)
		end
	end
	free(e)
	return true
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
	local e, etype
	while not self._stop do
		last_poll_time = time.clock()
		if not poll_event() then
			self:_check_timers()
			self:_sleep()
		end
	end
end

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
		C.XCB_EVENT_MASK_SUBSTRUCTURE_NOTIFY,
		C.XCB_EVENT_MASK_FOCUS_CHANGE,
		C.XCB_EVENT_MASK_PROPERTY_CHANGE,
		C.XCB_EVENT_MASK_COLOR_MAP_CHANGE,
		C.XCB_EVENT_MASK_OWNER_GRAB_BUTTON
	))

	local parent = t.parent and t.parent.backend.win or screen.root

	local depth, visual = xcb_find_visual(screen, 32)
	if not depth then
		--settle for the default depth and visual
		depth = C.XCB_COPY_FROM_PARENT
		visual = screen.root_visual
	else
		--create a colormap for the visual and add it to the window values array.
		--this allows us to create a 32bit-depth window (i.e. with alpha).
		local colormap = C.xcb_generate_id(c)
		C.xcb_create_colormap(c, C.XCB_COLORMAP_ALLOC_NONE, colormap, parent, visual)
		addvalue(C.XCB_CW_COLORMAP, colormap)
	end

	self.win = C.xcb_generate_id(c)

	local cx, cy, cw, ch = app:frame_to_client(t.frame, t.x or 0, t.y or 0, t.w, t.h)

	C.xcb_create_window(
		c, depth, self.win, parent,
		0, 0, --x, y (ignored by WM, set later)
		cw, ch,
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

	--[[
	self._minimizable = opt.minimizable
	self._maximizable = opt.maximizable
	self._closeable = opt.closeable
	self._resizeable = opt.resizeable
	self._fullscreenable = opt.fullscreenable
	self._activable = opt.activable
	]]

	set_atom_map_prop(self.win, '_NET_WM_ALLOWED_ACTIONS', {
		_NET_WM_ACTION_MOVE = true,
		_NET_WM_ACTION_RESIZE = t.resizeable,
		_NET_WM_ACTION_MINIMIZE = t.minimizable,
		_NET_WM_ACTION_MAXIMIZE_HORZ = t.maximizable,
		_NET_WM_ACTION_MAXIMIZE_VERT = t.maximizable,
		_NET_WM_ACTION_FULLSCREEN = t.fullscreenable,
		_NET_WM_ACTION_CLOSE = t.closeable,
	})

	if t.min_cw or t.min_ch or t.max_cw or t.max_ch or not t.resizeable then
		local hints = get_wm_normal_hints(self.win)
		local min_cw, min_ch, max_cw, max_ch
		if not t.resizeable then
			--this is how we tell
			min_cw, min_ch = w, h
			max_cw, max_ch = w, h
		else
			min_cw, min_ch = t.min_cw, t.min_ch
			max_cw, max_ch = t.max_cw, t.max_ch
		end
		hints.flags = 0
		if min_cw or min_ch then
			hints.flags = bit.bor(hints.flags, C.XCB_ICCCM_SIZE_HINT_P_MIN_SIZE)
			hints.min_width  = min_cw or 0
			hints.min_height = min_ch or 0
		end
		if max_cw or max_ch then
			hints.flags = bit.bor(hints.flags, C.XCB_ICCCM_SIZE_HINT_P_MAX_SIZE)
			hints.max_width  = max_cw or 2^30 --arbitrary long number
			hints.max_height = max_ch or 2^30
		end
		set_wm_normal_hints(self.win, hints)
	end

	if t.visible then
		C.xcb_map_window(c, self.win)
	end

	--NOTE: setting the window's position only works after the window is mapped.
	if t.x then
		xcb_change_pos(self.win, t.x, t.y)
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

function app:root_props()
	return list_props(screen.root)
end

function app:root_query_tree()
	return query_tree(screen.root)
end

function window:props()
	return list_props(self.win)
end

function window:query_tree()
	return query_tree(self.win)
end

--closing --------------------------------------------------------------------

function window:_ping_event(e)
	local reply = ffi.new('xcb_client_message_event_t', e[0])
	reply.response_type = C.XCB_CLIENT_MESSAGE
	reply.window = screen.root
	send_client_message_to_root(reply) --pong!
	C.xcb_flush(c)
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

ev[C.XCB_PROPERTY_NOTIFY] = function(e)
	e = cast('xcb_property_notify_event_t*', e)
	local self = getwin(e.window)
	if not self then return end
	if e.atom == atom'_NET_FRAME_EXTENTS' then
	end
end

ev[C.XCB_CONFIGURE_NOTIFY] = function(e)
	e = cast('xcb_configure_notify_event_t*', e)
	local self = getwin(e.window)
	if not self then return end
	self.x = e.x
	self.y = e.y
	self.w = e.width
	self.h = e.height
	print('XCB_CONFIGURE_NOTIFY', self.x, self.y, self.w, self.h)
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
	C.xcb_flush(c)
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
	C.xcb_flush(c)
end

--state/restoring ------------------------------------------------------------

function window:restore()
	set_netwm_state(self.win, false,
		'_NET_WM_STATE_MAXIMIZED_HORZ',
		'_NET_WM_STATE_MAXIMIZED_VERT')
	C.xcb_flush(c)
end

function window:shownormal()
	set_netwm_state(self.win, false,
		'_NET_WM_STATE_MAXIMIZED_HORZ',
		'_NET_WM_STATE_MAXIMIZED_VERT')
	C.xcb_flush(c)
end

--state/changed event --------------------------------------------------------

--self.frontend:_backend_changed()

--state/fullscreen -----------------------------------------------------------

function window:fullscreen()
	return get_netwm_states(self.win)[atom'_NET_WM_STATE_FULLSCREEN']
end

function window:enter_fullscreen()
	set_netwm_state(self.win, true, '_NET_WM_STATE_FULLSCREEN')
	C.xcb_flush(c)
end

function window:exit_fullscreen()
	set_netwm_state(self.win, false, '_NET_WM_STATE_FULLSCREEN')
	C.xcb_flush(c)
end

--state/enabled --------------------------------------------------------------

function window:get_enabled()
end

function window:set_enabled(enabled)
end

--positioning/conversions ----------------------------------------------------

function window:to_screen(x, y)
	return xcb_translate_coords(self.win, screen.root, x, y)
end

function window:to_client(x, y)
	return xcb_translate_coords(screen.root, self.win, x, y)
end

local function frame_extents(frame)

	--create a dummy window
	local depth = C.XCB_COPY_FROM_PARENT
	local visual = screen.root_visual
	local win = C.xcb_generate_id(c)
	C.xcb_create_window(
		c, depth, win, screen.root,
		0, 0, --x, y (ignored)
		200, 200,
		0, --border width (ignored)
		C.XCB_WINDOW_CLASS_INPUT_OUTPUT, --class
		visual, 0, nil)

	--set its frame
	if frame == 'toolbox' then
		set_atom_prop(win, '_NET_WM_WINDOW_TYPE', '_NET_WM_WINDOW_TYPE_TOOLBAR')
	end

	--request frame extents estimation from the WM
	request_frame_extents(win)
	--the WM should have set the frame extents
	local w1, h1, w2, h2 = xcb_frame_extents(win)

	--destroy the window
	C.xcb_destroy_window(c, win)
	C.xcb_flush(c)

	--compute/return the frame rectangle
	return {w1, h1, w2, h2}
end

local frame_extents = glue.memoize(frame_extents)

local frame_extents = function(frame)
	return unpack(frame_extents(frame))
end

local function frame_rect(x, y, w, h, w1, h1, w2, h2)
	return x - w1, y - h1, w + w1 + w2, h + h1 + h2
end

local function unframe_rect(x, y, w, h, w1, h1, w2, h2)
	return frame_rect(x, y, w, h, -w1, -h1, -w2, -h2)
end

function app:client_to_frame(frame, x, y, w, h)
	return frame_rect(x, y, w, h, frame_extents(frame))
end

function app:frame_to_client(frame, x, y, w, h)
	local fx, fy, fw, fh = self:client_to_frame(frame, 0, 0, 200, 200)
	local cx = x - fx
	local cy = y - fy
	local cw = w - (fw - 200)
	local ch = h - (fh - 200)
	return cx, cy, cw, ch
end

--positioning/rectangles -----------------------------------------------------

function window:_frame_extents()
	return xcb_frame_extents(self.win)
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
	x, y, w, h = unframe_rect(x, y, w, h, self:_frame_extents())
	xcb_change_pos(x, y)
	xcb_change_size(w, h)
	C.xcb_flush(c)
end

function window:get_size()
	local cookie = C.xcb_get_geometry(c, self.win)
	local reply = C.xcb_get_geometry_reply(c, cookie, nil)
	local w, h = reply.width, reply.height
	free(reply)
	return w, h
end

--positioning/constraints ----------------------------------------------------

function window:get_minsize()
	local hints = get_wm_normal_hints(self.win)
	return hints.min_width, hints.min_height
end

function window:get_maxsize()
	local hints = get_wm_normal_hints(self.win)
	return hints.max_width, hints.max_height
end

function window:set_minsize(w, h)
	local hints = get_wm_normal_hints(self.win)
	hints.min_width = w
	hints.min_height = h
	set_wm_normal_hints(self.win, hints)
end

function window:set_maxsize(w, h)
	local hints = get_wm_normal_hints(self.win)
	hints.max_width = w
	hints.max_height = h
	set_wm_normal_hints(self.win, hints)
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
	C.xcb_flush(c)
end

--z-order --------------------------------------------------------------------

function window:get_topmost()
	return get_netwm_states(self.win)[atom'_NET_WM_STATE_ABOVE']
end

function window:set_topmost(topmost)
	set_netwm_state(self.win, topmost, atom'_NET_WM_STATE_ABOVE')
	C.xcb_flush(c)
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

--[[
     # NQR means default shape is not pretty... surely there is another
        # cursor font?
        cursor_shapes = {
            self.CURSOR_CROSSHAIR:       cursorfont.XC_crosshair,
            self.CURSOR_HAND:            cursorfont.XC_hand2,
            self.CURSOR_HELP:            cursorfont.XC_question_arrow,  # NQR
            self.CURSOR_NO:              cursorfont.XC_pirate,          # NQR
            self.CURSOR_SIZE:            cursorfont.XC_fleur,
            self.CURSOR_SIZE_UP:         cursorfont.XC_top_side,
            self.CURSOR_SIZE_UP_RIGHT:   cursorfont.XC_top_right_corner,
            self.CURSOR_SIZE_RIGHT:      cursorfont.XC_right_side,
            self.CURSOR_SIZE_DOWN_RIGHT: cursorfont.XC_bottom_right_corner,
            self.CURSOR_SIZE_DOWN:       cursorfont.XC_bottom_side,
            self.CURSOR_SIZE_DOWN_LEFT:  cursorfont.XC_bottom_left_corner,
            self.CURSOR_SIZE_LEFT:       cursorfont.XC_left_side,
            self.CURSOR_SIZE_UP_LEFT:    cursorfont.XC_top_left_corner,
            self.CURSOR_SIZE_UP_DOWN:    cursorfont.XC_sb_v_double_arrow,
            self.CURSOR_SIZE_LEFT_RIGHT: cursorfont.XC_sb_h_double_arrow,
            self.CURSOR_TEXT:            cursorfont.XC_xterm,
            self.CURSOR_WAIT:            cursorfont.XC_watch,
            self.CURSOR_WAIT_ARROW:      cursorfont.XC_watch,           # NQR
        }
        if name not in cursor_shapes:
            raise MouseCursorException('Unknown cursor name "%s"' % name)
        cursor = xlib.XCreateFontCursor(self._x_display, cursor_shapes[name])
        return XlibMouseCursor(cursor)
]]

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
		local data  = shm.shmat(shmid, nil, 0)

		local shmseg  = C.xcb_generate_id(c)
		xcbshm.xcb_shm_attach(c, shmseg, shmid, 0)
		shm.shmctl(shmid, shm.IPC_RMID, nil)

		local pix = C.xcb_generate_id(c)

		xcbshm.xcb_shm_create_pixmap(c, pix, win, w, h, depth_id, shmseg, 0)

		C.xcb_flush(c)

		bitmap.data = data

		local gc = C.xcb_generate_id(c)
		C.xcb_create_gc(c, gc, win, 0, nil)

		function paint()
			C.xcb_copy_area(c, pix, win, gc, 0, 0, 0, 0, w, h)
			C.xcb_flush(c)
		end

		function free()
			xcbshm.xcb_shm_detach(c, shmseg)
			shm.shmdt(data)
			C.xcb_free_pixmap(c, pix)
		end

	else

		local data = glue.malloc('char', size)
		bitmap.data = data

		local pix = C.xcb_generate_id(c)
		C.xcb_create_pixmap(c, 32, pix, win, w, h)

		local gc = C.xcb_generate_id(c)
		C.xcb_create_gc(c, gc, win, 0, nil)

		function paint()
			C.xcb_put_image(c, C.XCB_IMAGE_FORMAT_Z_PIXMAP,
				pix, gc, w, h, 0, 0, 0, 32, size, data)
			C.xcb_copy_area(c, pix, win, gc, 0, 0, 0, 0, w, h)
			C.xcb_flush(c)
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


return nw
