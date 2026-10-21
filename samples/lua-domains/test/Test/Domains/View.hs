-- | A coherent view for each UI segment (requirement 9; P-2): every snapshot query of one segment
-- answers from the capture the segment began with, whatever gameplay publishes meanwhile, and the
-- next segment may see a newer one.
module Test.Domains.View (spec) where

import qualified Data.Text as Text
import Hetoimasia.Sample.LuaDomains
  ( DomainsConfig (configGameplaySource, configUiSource)
  , GameSnapshot (snapTick)
  )
import Test.Domains.Support
import Test.Hspec

-- | Every entity as the view shows it, with the tick, as one line.
viewProbe ∷ [String]
viewProbe =
  [ "local phase = 0"
  , "local function text()"
  , "  local parts = {tostring(view.tick())}"
  , "  for i = 0, view.count() - 1 do"
  , "    local present, x, y, version = view.entity(i)"
  , "    parts[#parts + 1] = x .. ',' .. y .. ',' .. version"
  , "  end"
  , "  return table.concat(parts, ' ')"
  , "end"
  , "function update(self, dt)"
  , "  phase = phase + 1"
  , "  local first = text()"
  , "  if phase == 1 then fx.hold('mid segment') end"
  , "  local second = text()"
  , "  fx.record('segment ' .. phase .. ' first=[' .. first .. '] second=[' .. second .. ']')"
  , "  ui.updated()"
  , "end"
  ]

-- | Gameplay moves entity zero one to the right in every tick.
movesEntityZero ∷ [String]
movesEntityZero =
  [ "function update(self, dt)"
  , "  staging.move(0, 1, 0)"
  , "  staging.finish()"
  , "end"
  ]

spec ∷ Spec
spec = describe "the UI's view" $
  it "answers every query of a segment from one capture, though a tick commits in the middle of it, and shows the next segment the new one" $
    withSample
      ( \config →
          config
            { configGameplaySource = luaLines (map Text.pack movesEntityZero)
            , configUiSource = luaLines (map Text.pack viewProbe)
            }
      )
      $ \fx ui domains → withReleased fx ["mid segment"] $ do
        -- The first UI segment begins with the initial snapshot and is held in the middle.
        tickUi domains ui
        awaitEntered fx "mid segment"
        committed ← stepCommitted domains
        snapTick committed `shouldBe` 1
        releaseGate fx "mid segment"
        awaitUpdates domains 1
        -- The next segment is captured afterwards, and sees tick one.
        tickUi domains ui
        awaitUpdates domains 2
        let initial = "0 0,0,0 4,1,0 8,2,0 12,3,0 16,4,0 20,5,0 24,6,0 28,7,0"
            later = "1 1,0,1 4,1,0 8,2,0 12,3,0 16,4,0 20,5,0 24,6,0 28,7,0"
        fxLines fx
          `shouldReturn` [ Text.pack ("segment 1 first=[" <> initial <> "] second=[" <> initial <> "]")
                         , Text.pack ("segment 2 first=[" <> later <> "] second=[" <> later <> "]")
                         ]
