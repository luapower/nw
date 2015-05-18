
--native widgets - winapi backend.
--Written by Cosmin Apreutesei. Public domain.

local ffi = require'ffi'
local bit = require'bit'
local glue = require'glue'
local box2d = require'box2d'
local xcb = require'xcb'
local C = xcb.C
local cast = ffi.cast
local free = ffi.C.free
local pp = require'pp'
local reflect = require'ffi_reflect'

local nw = {name = 'xcb'}

--os version -----------------------------------------------------------------

function nw:os(ver)
	return 'X 11.0' --TODO
end

nw.min_os = 'X 11.0'

--app object -----------------------------------------------------------------

local app = {}
nw.app = app

function app:new(frontend)
	self = glue.inherit({frontend = frontend}, self)
	self.c = C.xcb_connect(nil, nil)
	self.atoms, self.atom = xcb.atom_map(self.c)
	return self
end

--message loop ---------------------------------------------------------------

local ev = {}

function app:run()
	local pe = self._peeked_event
	local e
	while not self._stopped or pe do
		if pe then
			e = pe
			self._peeked_event = nil
		else
			e = C.xcb_wait_for_event(self.c)
			if e == nil then break end
		end
		local v = bit.band(e.response_type, bit.bnot(0x80))
		local f = ev[v]
		if f then f(e) end
		free(e)
	end
end

function app:_peek_event()
	if not self._peeked_event then
		local e = C.xcb_poll_for_event(self.c)
		if e == nil then return end
		self._peeked_event = e
		local v = bit.band(e.response_type, bit.bnot(0x80))
		local f = ev[v]
		if f then f(e) end
	end
	return self._peeked_event
end

function app:stop()
	self._stopped = true
	--TODO: post quit message instead of this flag
	--[[
	local w = next(win_map)
	local e = ffi.new'xcb_client_message_event_t'
	e.response_type = C.XCB_CLIENT_MESSAGE
	e.window = w
	e.format = 32
	e.sequence = 0
	e.type = self.atom'WM_PROTOCOLS'
	e.data.data32[0] = self.atom'WM_DELETE_WINDOW'
	e.data.data32[1] = C.XCB_CURRENT_TIME
	C.xcb_send_event(self.c, 0, w, C.XCB_EVENT_MASK_NO_EVENT, e)
	]]
end

--time -----------------------------------------------------------------------

function app:time()
	return 0 --TODO
end

local qpf
function app:timediff(start_time, end_time)
	return start_time - end_time --TODO
end

--timers ---------------------------------------------------------------------

function app:runevery(seconds, func)
	func()
end

--windows --------------------------------------------------------------------

local window = {}
app.window = window

local win_map = {} --{xcb_window_t -> window object}

function window:new(app, frontend, t)
	self = glue.inherit({app = app, frontend = frontend, c = app.c,
		atom = app.atom, atoms = app.atoms}, self)

	self.win = C.xcb_generate_id(self.c)

	local mask = bit.bor(
		C.XCB_CW_EVENT_MASK,
		C.XCB_CW_BACK_PIXMAP
	)
   local val = ffi.new('uint32_t[2]',
   	--XCB_CW_EVENT_MASK values
   	C.XCB_NONE,
   	--XCB_CW_BACK_PIXMAP values
   	bit.bor(
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
		)
	)

	local screen = C.xcb_setup_roots_iterator(C.xcb_get_setup(self.c)).data

	C.xcb_create_window_checked(
		self.c,
		C.XCB_COPY_FROM_PARENT,          -- depth
		self.win,                        -- window id
		screen.root,                     -- parent window
		0, 0,                            -- x, y (ignored)
		t.w, t.h,
		0,                               -- border width (ignored)
		C.XCB_WINDOW_CLASS_INPUT_OUTPUT, -- class
		screen.root_visual,              -- visual
		mask, val)                       -- event mask and value

	--set WM_PROTOCOLS = WM_DELETE_WINDOW indicates that the connection
	--should survive the closing of a top-level window.
	local a = self.atoms('WM_PROTOCOLS', 'WM_DELETE_WINDOW')
	C.xcb_change_property(self.c, C.XCB_PROP_MODE_REPLACE, self.win,
		a.WM_PROTOCOLS, C.XCB_ATOM_ATOM, 32, 1, ffi.new('int32_t[1]', a.WM_DELETE_WINDOW))

	if t.title then
		C.xcb_change_property(self.c, C.XCB_PROP_MODE_REPLACE, self.win,
			C.XCB_ATOM_WM_NAME, C.XCB_ATOM_STRING, 8, #t.title, t.title)
	end

	if t.visible then
		C.xcb_map_window(self.c, self.win)
	end

	--NOTE: setting the window's position only works after the window is mapped.
	if t.x or t.y then
	 	local xy = ffi.new('int32_t[2]', t.x, t.y)
		C.xcb_configure_window(self.c, self.win,
			bit.bor(C.XCB_CONFIG_WINDOW_X, C.XCB_CONFIG_WINDOW_Y), xy)
	end

	C.xcb_flush(self.c)

	win_map[self.win] = self

	--[[
	local framed = t.frame == 'normal' or t.frame == 'toolbox'
	self._layered = t.frame == 'none-transparent'

	self.win = Window{
		min_cw = t.min_cw,
		min_ch = t.min_ch,
		max_cw = t.max_cw,
		max_ch = t.max_ch,
		maximized = t.maximized,
		enabled = t.enabled,
		--frame
		border = framed,
		frame = framed,
		window_edge = framed, --must be off for frameless windows!
		layered = self._layered,
		tool_window = t.frame == 'toolbox',
		owner = t.parent and t.parent.backend.win,
		--behavior
		topmost = t.topmost,
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

ev[C.XCB_CLIENT_MESSAGE] = function(e)
	e = cast('xcb_client_message_event_t*', e)
	local self = win_map[e.window]
	if not self then return end
	if e.data.data32[0] ~= self.atom'WM_DELETE_WINDOW' then return end --close

	if self.frontend:_backend_closing() then
		self:forceclose()
	end
end

function window:forceclose()
	C.xcb_destroy_window_checked(self.c, self.win)
	C.xcb_flush(self.c)
	self.frontend:_backend_closed()
	win_map[self.win] = nil
end

--activation -----------------------------------------------------------------

--app: self.frontend:_backend_activated()
--app: self.frontend:_backend_deactivated()
--window: self.frontend:_backend_activated()
--window: self.frontend:_backend_deactivated()

function app:activate()
end

function app:active_window()
end

function app:active()
	return true
end

function window:activate()
end

function window:active()
	return true
end

--state/visibility -----------------------------------------------------------

function window:visible()
	return true
end

function window:show()
	C.xcb_map_window_checked(self.c, self.win)
end

function window:hide()
	C.xcb_unmap_window_checked(self.c, self.win)
end

--state/minimizing -----------------------------------------------------------

function window:minimized()
	return false
end

function window:minimize()
end

--state/maximizing -----------------------------------------------------------

function window:maximized()
	return false
end

function window:maximize()
end

--state/restoring ------------------------------------------------------------

function window:restore()
end

function window:shownormal()
end

--state/changed event --------------------------------------------------------

--self.frontend:_backend_changed()

--state/fullscreen -----------------------------------------------------------

function window:fullscreen()
	return self._fullscreen
end

function window:enter_fullscreen()
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
	local cookie = C.xcb_get_window_attributes(self.c, self.win)
	local reply = C.xcb_get_window_attributes_reply(self.c, cookie, nil)
	local x, y, w, h =
		reply.visual.x,
		reply.visual.y,
		reply.visual.width,
		reply.visual.height
	free(reply)
	return x, y, w, h
end

function window:set_normal_rect(x, y, w, h)
 	local xy = ffi.new('uint32_t[2]', x, y)
 	local wh = ffi.new('uint32_t[2]', w, h)
	C.xcb_configure_window_checked(self.c, self.win,
		bit.bor(C.XCB_CONFIG_WINDOW_X, C.XCB_CONFIG_WINDOW_Y), xy)
	C.xcb_configure_window_checked(self.c, self.win,
		bit.bor(C.XCB_CONFIG_WINDOW_WIDTH, C.XCB_CONFIG_WINDOW_HEIGHT), wh)
end

function window:get_frame_rect()
	local x, y, w, h = self:get_normal_rect()
	x, y = translate(self.c, self.win, 0, x, y)
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
end

function window:set_title(title)
	return C.xcb_change_property_checked(self.c, C.XCB_PROP_MODE_REPLACE, self.w,
		C.XCB_ATOM_WM_NAME, C.XCB_ATOM_STRING, 8, #title, title)
end

--z-order --------------------------------------------------------------------

function window:get_topmost()
end

function window:set_topmost(topmost)
end

function window:set_zorder(mode, relto)
end

--displays -------------------------------------------------------------------

function app:_display(monitor)
	return self.frontend:_display{
		x = info.monitor_rect.x,
		y = info.monitor_rect.y,
		w = info.monitor_rect.w,
		h = info.monitor_rect.h,
		client_x = info.work_rect.x,
		client_y = info.work_rect.y,
		client_w = info.work_rect.w,
		client_h = info.work_rect.h,
	}
end

function app:displays()
	local monitors = winapi.EnumDisplayMonitors()
	local displays = {}
	for i = 1, #monitors do
		table.insert(displays, self:_display(monitors[i])) --invalid displays are skipped
	end
	return displays
end

function app:active_display()
end

function app:display_count()
end

function window:display()
end

--self.app.frontend:_backend_displays_changed()

--cursors --------------------------------------------------------------------

function window:cursor(name)
end

--keyboard -------------------------------------------------------------------

ev[C.XCB_KEY_PRESS] = function(e)
	local e = cast('xcb_key_press_event_t*', e)
	local self = win_map[e.event]
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
	local self = win_map[e.event]
	if not self then return end
	local key = e.detail

	--peek next message to distinguish between key release and key repeat
 	local e1 = self.app:_peek_event()
 	if e1 then
 		local v = bit.band(e1.response_type, bit.bnot(0x80))
 		if v == C.XCB_KEY_PRESS then
			local e1 = cast('xcb_key_press_event_t*', e1)
 			if e1.time == e.time and e1.detail == e.detail then
				print'reeeeeeeepeat'
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
	local self = win_map[e.event]
	if not self then return end

	local btn = btns[e.detail]
	if not btn then return end
	local x, y = 0, 0
	self.frontend:_backend_mousedown(btn, x, y)
end

ev[C.XCB_BUTTON_RELEASE] = function(e)
	e = cast('xcb_button_press_event_t*', e)
	local self = win_map[e.event]
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

--??

--rendering ------------------------------------------------------------------

ev[C.XCB_EXPOSE] = function(e)
	local e = cast('xcb_expose_event_t*', e)
	if e.count ~= 0 then return end --subregion rendering
	local self = win_map[e.window]
	if not self then return end

	self:invalidate()
end

function window:bitmap()
end

function window:invalidate()
	self.frontend:_backend_repaint()
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
		return self.cairoview
	else
		return self.cairoview2
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
