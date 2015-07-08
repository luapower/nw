
--native widgets - XCB backend.
--Written by Cosmin Apreutesei. Public domain.

if not ... then require'nw_test'; return end

local ffi = require'ffi'
local bit = require'bit'
local glue = require'glue'
local box2d = require'box2d'
local xcb_module = require'xcb'
local time = require'time' --for timers
local heap = require'heap' --for timers
local pp = require'pp'
local cast = ffi.cast
local free = glue.free

local C = xcb_module.C

local nw = {name = 'xcb'}

--os version -----------------------------------------------------------------

function nw:os(ver)
	return 'Linux 11.0' --11.0 is the X version
end

nw.min_os = 'Linux 11.0'

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

local xcb, screen, c, atom --xcb connection state

function app:new(frontend)
	self = glue.inherit({frontend = frontend}, self)
	xcb = xcb_module.connect()
	c, screen, atom = xcb.c, xcb.screen, xcb.atom
	return self
end

function app:virtual_roots()
	return get_window_list_prop(screen.root, '_NET_VIRTUAL_ROOTS')
end

--message loop ---------------------------------------------------------------

local ev = {} --{xcb_event_code = event_handler}

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
		local e, etype = xcb.poll()
		if e then
			--print('EVENT', etype)
			local f = ev[etype]
			if f then f(e) end
			free(e)
		else
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

	local framed = t.frame ~= 'none' and t.frame ~= 'none-transparent'

	--local parent = t.parent and t.parent.backend.win or screen.root
	local parent = screen.root --TODO

	local depth, visual = xcb.find_bgra8_visual(screen)
	if not depth then
		--settle for the default depth and visual
		depth = C.XCB_COPY_FROM_PARENT
		visual = screen.root_visual
	else
		--create a colormap for the visual and add it to the window values array.
		--this allows us to create a 32bit-depth window (i.e. with alpha).
		local colormap = xcb.gen_id()
		xcb.create_colormap(C.XCB_COLORMAP_ALLOC_NONE, colormap, parent, visual)
		addvalue(C.XCB_CW_COLORMAP, colormap)
	end

	local _, _, cw, ch = app:frame_to_client(t.frame, t.x or 0, t.y or 0, t.w, t.h)

	self.win = xcb.gen_id()

	xcb.create_window(
		depth, self.win, parent,
		0, 0, --x, y (ignored by WM, set after mapping the window)
		cw, ch,
		0, --border width (ignored)
		C.XCB_WINDOW_CLASS_INPUT_OUTPUT, --class
		visual, mask, values)

	--declare the X protocols that the window supports.
	xcb.set_atom_map_prop(self.win, 'WM_PROTOCOLS', {
		WM_DELETE_WINDOW = true, --don't close the connection when a window is closed
		WM_TAKE_FOCUS = true,    --allow focusing the window programatically
		_NET_WM_PING = true,     --respond to ping events
	})

	--set pid for _NET_WM_PING protocol to allow the user to kill a non-responsive process.
	xcb.set_cardinal_prop(self.win, '_NET_WM_PID', getpid())

	if t.title then
		xcb.set_title(self.win, t.title)
	end

	--setting minw/h = maxw/h is how we tell X that a window has fixed size.
	if not t.resizeable then
		xcb.set_minmax(self.win, w, h, w, h)
	else
		xcb.set_minmax(self.win, t.min_cw, t.min_ch, t.max_cw, t.max_ch)
	end

	--set the _NET_WM_STATE property before mapping the window.
	--later on we have to use change_netwm_states() to change these values.
	xcb.set_netwm_states(self.win, {
		_NET_WM_STATE_MAXIMIZED_HORZ = t.maximized or nil,
		_NET_WM_STATE_MAXIMIZED_VERT = t.maximized or nil,
		_NET_WM_STATE_ABOVE = t.topmost or nil,
		_NET_WM_STATE_FULLSCREEN = t.fullscreen or nil,
	})

	--set WM_HINTS before mapping the window.
	if t.minimized then
		local hints = ffi.new'xcb_icccm_wm_hints_t'
		hints.flags = C.XCB_ICCCM_WM_HINT_STATE
		hints.initial_state = C.XCB_ICCCM_WM_STATE_ICONIC
		xcb.set_wm_hints(self.win, hints)
	end

	--set motif hints before mapping the window.
	local hints = ffi.new'xcb_motif_wm_hints_t'
	hints.flags = bit.bor(
		C.MWM_HINTS_FUNCTIONS,
		C.MWM_HINTS_DECORATIONS)
	hints.functions = bit.bor(
		t.resizeable and C.MWM_FUNC_RESIZE or 0,
		C.MWM_FUNC_MOVE,
		t.minimizable and C.MWM_FUNC_MINIMIZE or 0,
		t.maximizable and C.MWM_FUNC_MAXIMIZE or 0,
		t.closeable and C.MWM_FUNC_CLOSE or 0)
	hints.decorations = bit.bor(
		framed and C.MWM_DECOR_BORDER or 0,
		framed and C.MWM_DECOR_TITLE or 0,
		framed and C.MWM_DECOR_MENU or 0,
		t.resizeable and C.MWM_DECOR_RESIZEH or 0)
	xcb.set_motif_wm_hints(self.win, hints)

	--setting the window's position only works after mapping the window.
	if t.x then
		self._init_pos, self._init_x, self._init_y = true, t.x, t.y
	end

	xcb.flush()

	setwin(self.win, self)

	return self
end

function app:root_props()
	return xcb.list_props(screen.root)
end

function app:root_query_tree()
	return xcb.query_tree(screen.root)
end

function window:props()
	return xcb.list_props(self.win)
end

function window:query_tree()
	return xcb.query_tree(self.win)
end

--closing --------------------------------------------------------------------

function window:_ping_event(e)
	local reply = ffi.new('xcb_client_message_event_t', e[0])
	reply.response_type = C.XCB_CLIENT_MESSAGE
	reply.window = screen.root
	send_client_message_to_root(reply) --pong!
	xcb.flush()
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
	xcb.destroy_window(self.win)
	xcb.flush()
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
	xcb.activate(self.win)
	xcb.flush()
end

function window:active()
	return app:active_window() == self
end

--state/visibility -----------------------------------------------------------

function window:visible()
	return true
end

function window:show()
	xcb.map(self.win)
	if self._init_pos then
		xcb.change_pos(self.win, self._init_x, self._init_y)
		self._init_pos, self._init_x, self._init_y = nil
	end
	xcb.flush()
end

function window:hide()
	xcb.unmap(self.win)
	xcb.flush()
end

--state/minimizing ---------------------------------------------------------h(--

function window:minimized()
	local hints = xcb.get_wm_hints(self.win) --TODO: returns nil
	return hints and bit.band(hints.initial_state, C.XCB_ICCCM_WM_STATE_ICONIC) ~= 0
end

function window:minimize()
	xcb.minimize(self.win)
	xcb.flush()
end

--state/maximizing -----------------------------------------------------------

function window:maximized()
	local states = xcb.get_netwm_states(self.win)
	return
		states[xcb.atom'_NET_WM_STATE_MAXIMIZED_HORZ'] and
		states[xcb.atom'_NET_WM_STATE_MAXIMIZED_VERT']
end

function window:maximize()
	xcb.change_netwm_states(self.win, true,
		'_NET_WM_STATE_MAXIMIZED_HORZ',
		'_NET_WM_STATE_MAXIMIZED_VERT')
	xcb.flush()
end

--state/restoring ------------------------------------------------------------

function window:restore()
	xcb.change_netwm_states(self.win, false,
		'_NET_WM_STATE_MAXIMIZED_HORZ',
		'_NET_WM_STATE_MAXIMIZED_VERT')
	xcb.flush()
end

function window:shownormal()
	xcb.change_netwm_states(self.win, false,
		'_NET_WM_STATE_MAXIMIZED_HORZ',
		'_NET_WM_STATE_MAXIMIZED_VERT')
	xcb.flush()
end

--state/changed event --------------------------------------------------------

--self.frontend:_backend_changed()

--state/fullscreen -----------------------------------------------------------

function window:fullscreen()
	return xcb.get_netwm_states(self.win)[xcb.atom'_NET_WM_STATE_FULLSCREEN']
end

function window:enter_fullscreen()
	xcb.change_netwm_states(self.win, true, '_NET_WM_STATE_FULLSCREEN')
	xcb.flush()
end

function window:exit_fullscreen()
	xcb.change_netwm_states(self.win, false, '_NET_WM_STATE_FULLSCREEN')
	xcb.flush()
end

--state/enabled --------------------------------------------------------------

function window:get_enabled()
end

function window:set_enabled(enabled)
end

--positioning/conversions ----------------------------------------------------

function window:to_screen(x, y)
	return xcb.translate_coords(self.win, screen.root, x, y)
end

function window:to_client(x, y)
	return xcb.translate_coords(screen.root, self.win, x, y)
end

local function frame_extents(frame)

	--create a dummy window
	local depth = C.XCB_COPY_FROM_PARENT
	local visual = screen.root_visual
	local win = xcb.gen_id()
	xcb.create_window(
		depth, win, screen.root,
		0, 0, --x, y (ignored)
		200, 200,
		0, --border width (ignored)
		C.XCB_WINDOW_CLASS_INPUT_OUTPUT, --class
		visual, 0, nil)

	--set its frame
	if frame == 'toolbox' then
		xcb.set_atom_prop(win, '_NET_WM_WINDOW_TYPE', '_NET_WM_WINDOW_TYPE_TOOLBAR')
	end

	--request frame extents estimation from the WM
	xcb.request_frame_extents(win)
	--the WM should have set the frame extents
	local w1, h1, w2, h2 = xcb.frame_extents(win)
	if not w1 then --TODO:
		w1, h1, w2, h2 = 0, 0, 0, 0
	end

	--destroy the window
	xcb.destroy_window(win)
	xcb.flush()

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
	return xcb.frame_extents(self.win)
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
	local x1, y1, w, h = unframe_rect(x, y, w, h, self:_frame_extents())
	xcb.change_pos(self.win, x, y)
	xcb.change_size(self.win, w, h)
	xcb.flush()
end

function window:get_size()
	local geom = xcb.get_geometry(self.win)
	local w, h = geom.width, geom.height
	free(geom)
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

function window:set_minsize(minw, minh)
	xcb.set_minmax(self.win, minw, minh)
	xcb.flush()
end

function window:set_maxsize(maxw, maxh)
	xcb.set_minmax(self.win, nil, nil, maxw, maxh)
	xcb.flush()
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
	return xcb.get_title(win)
end

function window:set_title(title)
	xcb.set_title(self.win, title)
	xcb.flush()
end

--z-order --------------------------------------------------------------------

function window:get_topmost()
	return get_netwm_states(self.win)[atom'_NET_WM_STATE_ABOVE']
end

function window:set_topmost(topmost)
	xcb.change_netwm_states(self.win, topmost, atom'_NET_WM_STATE_ABOVE')
	xcb.flush()
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
	return 1--C.xcb_setup_roots_length(C.xcb_get_setup(c))
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

		local shmseg  = xcb.gen_id()
		xcbshm.xcb_shm_attach(c, shmseg, shmid, 0)
		shm.shmctl(shmid, shm.IPC_RMID, nil)

		local pix = xcb.gen_id()

		xcbshm.xcb_shm_create_pixmap(c, pix, win, w, h, depth_id, shmseg, 0)

		xcb.flush()

		bitmap.data = data

		local gc = xcb.gen_id()
		C.xcb_create_gc(c, gc, win, 0, nil)

		function paint()
			C.xcb_copy_area(c, pix, win, gc, 0, 0, 0, 0, w, h)
			xcb.flush()
		end

		function free()
			xcbshm.xcb_shm_detach(c, shmseg)
			shm.shmdt(data)
			C.xcb_free_pixmap(c, pix)
		end

	else

		local data = glue.malloc('char', size)
		bitmap.data = data

		local pix = xcb.gen_id()
		C.xcb_create_pixmap(c, 32, pix, win, w, h)

		local gc = xcb.gen_id()
		C.xcb_create_gc(c, gc, win, 0, nil)

		function paint()
			C.xcb_put_image(c, C.XCB_IMAGE_FORMAT_Z_PIXMAP,
				pix, gc, w, h, 0, 0, 0, 32, size, data)
			C.xcb_copy_area(c, pix, win, gc, 0, 0, 0, 0, w, h)
			xcb.flush()
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
