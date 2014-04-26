local nw = require'nw'

local app = nw:app()

print('impl.double_click_time', app.impl:double_click_time())
print('impl.double_click_target_area', app.impl:double_click_target_area())

for display in app:displays() do
	print('screen_rect',  app:screen_rect(display))
	print('desktop_rect', app:desktop_rect(display))
end

local t = app:time()
print('app:time', t)
print('app:timediff', app:timediff(t))


