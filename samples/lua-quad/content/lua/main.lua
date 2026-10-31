local function remember(self, key, request, refusal)
  if request then self[key] = request
  else assert(refusal.code == "busy") end
end

local function begin(self)
  local api = self.api
  if not self.window and not self.window_request then
    remember(self, "window_request", api.window.open({
      title="Lua quad", width=640, height=480
    }))
  end
  if not self.image and not self.texture_request then
    remember(self, "texture_request",
      api.content.texture("images/quad.png"))
  end
end

local function collect(self, request_key, value_key)
  local api, request = self.api, self[request_key]
  if not request or not api.request.ready(request) then return true end
  local result = api.request.take(request)
  self[request_key] = nil
  if result.status == "success" then
    self[value_key] = result.value
    return true
  elseif result.status == "cancelled" then
    api.session.quit()
    return false
  else
    error(result.error.message)
  end
end

return {
  gameplay = {
    every_ticks=1,
    update=function(self, dt_seconds) end
  },
  presentation = {
    every_seconds=0.02,
    init=function(self, api) begin(self) end,
    update=function(self, dt_seconds)
      local api = self.api
      begin(self)
      if not collect(self, "window_request", "window") then return end
      if not collect(self, "texture_request", "image") then return end
      local status = api.session.status()
      if status.gameplay.present and status.gameplay.failed then
        if self.window and not self.error_shown then
          warn(status.gameplay.failure.message)
          api.scene.publish(self.window, {
            clear={r=96, g=0, b=0}, sprites={}
          })
          self.error_shown = true
        end
        return
      end
      if self.window and self.image and not self.drawn then
        api.scene.publish(self.window, {
          clear={r=24, g=24, b=24},
          sprites={{texture=self.image.texture,
                    x=32, y=32, width=256, height=256}}
        })
        self.drawn = true
        api.texture.release(self.image.texture)
      end
    end
  }
}
