{-# LANGUAGE OverloadedStrings #-}

-- | The Lua and manifests the graphics facade's examples share between the controlled suite and the native one: the
-- accepted common-entry quad example (P-73) verbatim, and the variant whose logical update raises after startup.
module Test.LuaEngine.Graphics.FacadeScripts
  ( manifestFor
  , quadExample
  , failingLogicalExample
  ) where

import Data.ByteString (ByteString)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text

manifestFor ∷ Bool → ByteString
manifestFor both =
  Text.encodeUtf8 . Text.concat $
    [ "{\"format\":1,\"id\":\"graphics-test\",\"entry\":\"lua/main.lua\""
    , if both then ",\"tick_seconds\":\"0.05\"" else ""
    , ",\"vms\":["
    , if both then "{\"role\":\"gameplay\",\"clock\":\"logical\"}," else ""
    , "{\"role\":\"presentation\",\"clock\":\"elapsed\"}]}"
    ]

-- | The accepted common-entry example (P-73), verbatim.
quadExample ∷ ByteString
quadExample =
  Text.encodeUtf8 . Text.unlines $
    [ "local function remember(self, key, request, refusal)"
    , "  if request then self[key] = request"
    , "  else assert(refusal.code == \"busy\") end"
    , "end"
    , ""
    , "local function begin(self)"
    , "  local api = self.api"
    , "  if not self.window and not self.window_request then"
    , "    remember(self, \"window_request\", api.window.open({"
    , "      title=\"Lua quad\", width=640, height=480"
    , "    }))"
    , "  end"
    , "  if not self.image and not self.texture_request then"
    , "    remember(self, \"texture_request\","
    , "      api.content.texture(\"images/quad.png\"))"
    , "  end"
    , "end"
    , ""
    , "local function collect(self, request_key, value_key)"
    , "  local api, request = self.api, self[request_key]"
    , "  if not request or not api.request.ready(request) then return true end"
    , "  local result = api.request.take(request)"
    , "  self[request_key] = nil"
    , "  if result.status == \"success\" then"
    , "    self[value_key] = result.value"
    , "    return true"
    , "  elseif result.status == \"cancelled\" then"
    , "    api.session.quit()"
    , "    return false"
    , "  else"
    , "    error(result.error.message)"
    , "  end"
    , "end"
    , ""
    , "return {"
    , "  gameplay = {"
    , "    every_ticks=1,"
    , "    update=function(self, dt_seconds) end"
    , "  },"
    , "  presentation = {"
    , "    every_seconds=0.02,"
    , "    init=function(self, api) begin(self) end,"
    , "    update=function(self, dt_seconds)"
    , "      local api = self.api"
    , "      begin(self)"
    , "      if not collect(self, \"window_request\", \"window\") then return end"
    , "      if not collect(self, \"texture_request\", \"image\") then return end"
    , "      local status = api.session.status()"
    , "      if status.gameplay.present and status.gameplay.failed then"
    , "        if self.window and not self.error_shown then"
    , "          warn(status.gameplay.failure.message)"
    , "          api.scene.publish(self.window, {"
    , "            clear={r=96, g=0, b=0}, sprites={}"
    , "          })"
    , "          self.error_shown = true"
    , "        end"
    , "        return"
    , "      end"
    , "      if self.window and self.image and not self.drawn then"
    , "        api.scene.publish(self.window, {"
    , "          clear={r=24, g=24, b=24},"
    , "          sprites={{texture=self.image.texture,"
    , "                    x=32, y=32, width=256, height=256}}"
    , "        })"
    , "        self.drawn = true"
    , "        api.texture.release(self.image.texture)"
    , "      end"
    , "    end"
    , "  }"
    , "}"
    ]

-- | The same example whose logical role raises in its first update, after startup: the presentation role sees the
-- failure in its status and publishes the exact empty red-clear scene.
failingLogicalExample :: ByteString
failingLogicalExample =
  Text.encodeUtf8 (Text.replace "update=function(self, dt_seconds) end" "update=function(self, dt_seconds) error(\"logical failure\") end" (Text.decodeUtf8 quadExample))
