function love.conf (t)
	io.stdout:setvbuf("no")
	t.window.title = "Dungeon Fighter Quest"
	t.window.width = 1280
	t.window.height = 720
	t.window.highdpi = true
	t.window.borderless = true
	-- 关闭 DPI 缩放：绘制单位回到物理像素，和原版 0.10 引擎一致
	t.window.usedpiscale = false
end
