-- | A scene's content as the renderer's pure frame: the translation from a 'SceneContent' to a
-- candidate 'Snapshot', and nothing more. The renderer's own validation
-- ('Hetoimasia.Render.TwoD.Validation.validateSnapshot') and draw plan do the rest; the adapter reimplements no sorting, blending or rasterization.
--
-- = The approved subset
--
-- One window pass, cleared to the scene's opaque colour, with one full-window view and one UI layer
-- listing the sprites in the scene's order. The view's camera is at the origin with zoom 1 and no
-- rotation; its settings are written out, not inherited: UI scale 1, pixel snap off, nearest filter,
-- brightness 100%, pixels per world unit. Each sprite places the unit square at its origin with its
-- width and height, shows the whole image (UV 0,0 to 1,1) with the neutral tint, the default sampler
-- (the view's nearest), the default material, no clip, no frame table, no parameter, and neither the
-- translucent override nor the additive flag. All sprites share depth key 0, so the renderer's order
-- (ascending depth key, then submission order) is the script's list order, later over earlier, through
-- its premultiplied-alpha blend.
--
-- = The window
--
-- The scene's rectangles are authored in logical pixels and never change with the window. The view is
-- the whole framebuffer of the metrics the caller supplies, so a resize is a new candidate from the
-- same content and the new metrics: nothing is stretched, recentred or re-read from Lua. A zero
-- framebuffer extent is a valid empty viewport that draws nothing; it suspends drawing without
-- invalidating the scene. Metrics the renderer calls unusable (a negative extent, a content scale that
-- is not finite and positive) are refused here, so a candidate is only ever built for a target that
-- can be mapped.
--
-- = Textures
--
-- The scene names a texture by the backend's registration identity. How that identity is turned into
-- the renderer's handle (index and generation) is the backend's, so the caller supplies it: an
-- identity it cannot resolve refuses the candidate ('UnresolvedTexture') and is never replaced by a
-- placeholder or a newer texture.
module Hetoimasia.LuaEngine.Scene.Snapshot
  ( sceneCandidate
  , initialContent
  , SnapshotRefusal (..)
  ) where

import Data.Word (Word64)
import Hetoimasia.LuaEngine.Scene.Geometry (placement)
import Hetoimasia.LuaEngine.Scene.Types
import Hetoimasia.LuaEngine.Texture (TextureView (viewIdentity))
import Hetoimasia.Math.Vector (V2 (V2))
import Hetoimasia.Render.Api.Texture (TextureHandle)
import Hetoimasia.Render.TwoD.Material (defaultMaterial)
import Hetoimasia.Render.TwoD.Metrics (PixelExtent (PixelExtent), TargetMetrics (metricsFramebuffer), validMetrics)
import Hetoimasia.Render.TwoD.Settings (TextureFilter (FilterNearest), ViewSettings (..), ZoomMode (PixelsPerUnit))
import Hetoimasia.Render.TwoD.Snapshot

-- | Why a candidate could not be built for these metrics and this resolution of identities.
data SnapshotRefusal
  = -- | The metrics have a negative extent, or a content scale that is not finite and positive.
    MetricsUnusable
  | -- | A sprite names an identity the caller's resolution has no handle for.
    UnresolvedTexture !Word64
  deriving (Eq, Show)

-- | The initial scene: opaque black and empty. It is the content of a window before its first
-- publication and never the default of an authored scene that lacks a field.
initialContent ∷ SceneContent
initialContent = SceneContent (ClearColour 0 0 0 1) []

-- | The candidate frame of a scene's content for a target with these metrics, given how the backend's
-- identities resolve to the renderer's handles.
sceneCandidate ∷ (Word64 → Maybe TextureHandle) → TargetMetrics → SceneContent → Either SnapshotRefusal Snapshot
sceneCandidate resolve metrics content
  | not (validMetrics metrics) = Left MetricsUnusable
  | otherwise = do
      instances ← traverse instanceOf (sceneSprites content)
      Right . Snapshot $
        [ Pass
            WindowTarget
            (sceneClear content)
            [View (Camera (V2 0 0) 1 Nothing) viewport settings [] [UiLayer instances]]
        ]
  where
    PixelExtent width height = metricsFramebuffer metrics
    viewport = Viewport (V2 0 0) (V2 (fromIntegral width) (fromIntegral height))
    settings =
      ViewSettings
        { settingUiScale = 1
        , settingPixelSnap = False
        , settingFilter = FilterNearest
        , settingBrightness = 1
        , settingZoomMode = PixelsPerUnit
        }
    instanceOf sprite =
      let identity = viewIdentity (useView (spriteTexture sprite))
       in case resolve identity of
            Nothing → Left (UnresolvedTexture identity)
            Just handle →
              Right
                Instance
                  { instanceTransform = placement (spriteRect sprite)
                  , instanceUv = UvRect 0 0 1 1
                  , instanceTexture = handle
                  , instanceDepthKey = 0
                  , instanceTint = Tint 255 255 255 255
                  , instanceSampler = SamplerDefault
                  , instanceTranslucent = False
                  , instanceAdditive = False
                  , instanceClip = 0
                  , instanceFrameTable = 0
                  , instanceParameter = 0
                  , instanceMaterial = defaultMaterial
                  }
