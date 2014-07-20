---
project:   nw api
tagline:   native widgets API
---

## `local nw = require'nw'`

----------------- -------------------------------- ----------------------------------- --------------------------
__topic__			__actions__								__queries__									__events__

backends				nw:init([backendname]) 				nw.backends-> {OS = backendname} \
																	nw.backend.name -> backendname

oo						obj:override(method, func)

events				obj:observe(event, func) 															obj:event(name, args...) \
																													obj:\<eventname\>(args...)

app singleton													nw:app() -> app

message loop		app:run() \								app:running()
						app:stop()

quitting				app:autoquit(?) \						app:autoquit() -> ? \					\
						win:autoquit(?) \						win:autoquit() -> ?						\
						app:quit()																				app:quitting() -> ?

time																app:time() -> time \
																	app:timediff(time1, time2) -> ms

timers				app:runevery(seconds, func) \														func() -> continue?
						app:runafter(seconds, func)

window list														app:windows([order]) -> {win1,...}\	app:window_created() \
																	app:window_count() -> n  				app:window_closed()

windows				app:window(params) -> win \		\												\
						win:close() 							win:dead() -> ? 							win:closing() -> ? \
																													win:closed()

activation			app:activate()	\						app:active() -> ? \						app:activated() \
						\											\												app:deactivated() \
						win:activate()							win:active() -> ? \						win:activated() \
																	app:active_window() -> win				win:deactivated()

state					win:show() \							win:visible() -> ? \
						win:hide() \							\
						win:minimize() \						win:minimized() -> ? \					win:state_changed(how)
						win:maximize() \						win:maximized() -> ? \
						win:restore() \						\
						win:shownormal() \					\
						win:fullscreen()						win:fullscreen() -> ?

position				win:frame_rect(x, y, w, h)			win:frame_rect() -> x, y, w, h \		win:resizing(how, x, y, w, h) -> x, y, w, h \
																	win:client_rect() -> x, y, w, h		win:resized()

displays															app:displays() -> {disp1, ...} \		app:displays_changed()
																	app:main_display() -> disp \
																	win:display() -> disp \
																	disp:rect() -> x, y, w, h \
																	disp:client_rect() -> x, y, w, h

mouse pointer		win:cursor(name)

frame					win:title(title) \					win:title() -> title \
						\											win:frame() -> frame \
						\											win:minimizable() -> ? \
						\											win:maximizable() -> ? \
						\											win:closeable() -> ? \
						\											win:resizeable() -> ? \
						\											win:fullscreenable() -> ? \
						win:edgesnapping(?)					win:edgesnapping() -> ?

z-order				win:topmost(?) \						win:topmost() -> ? \
						win:order(z|'back'|'front')		win:zorder() -> z

parent															win:parent() -> parent

keyboard				app:ignore_numlock(?)				app:ignore_numlock() -> ? \			win:keydown(key, vkey) \
																	win:key(keyquery) -> pressed?			win:keyup(key, vkey) \
																													win:keypress(key, vkey) \
																													win:keychar(char)

mouse																win:mouse() -> m \						win:mousedown(button) \
																	m.x, m.y, \									win:click(button, count) -> reset? \
																	m.left, m.right, m.middle, \			win:mouseup(button) \
																	m.xbutton1, m.xbutton2					win:mouseenter() \
																													win:mouseleave() \
																													win:mousemove(x, y) \
																													win:mousewheel(delta) \
																													win:mousehwheel(delta)

rendering			win:invalidate()																		win:render(cr)
----------------- -------------------------------- ----------------------------------- --------------------------

