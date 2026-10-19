-- | The UI intention contract (requirement 6): answered once and at once, accepted only when the
-- queue has taken the intention for a tick that has not started, never blocking, with a recoverable
-- answer for anything malformed or over a bound, given before the typed binding is reached.
module Test.Domains.Intentions (spec) where

import Control.Concurrent.STM (atomically, readTVarIO)
import qualified Data.Text as Text
import Hetoimasia.Sample.LuaDomains
  ( Bounds (boundPlaces, boundQueue)
  , Domains (domainsShared, domainsUi)
  , DomainsConfig (configBounds, configGameplaySource, configUiSource)
  , Started (startedInstance, startedOwner)
  , stepTick
  )
import Hetoimasia.Sample.LuaDomains.Shared (Shared (sharedCounts))
import Hetoimasia.Sample.LuaDomains.Tally (Counts (..), noCounts)
import Hetoimasia.Scripting.Lua.Instance (InstancePhase (Active), InstanceSnapshot (snapshotPhase), inspectInstance)
import Hetoimasia.Scripting.Lua.Scheduled (scheduledEndpoint)
import Test.Domains.Support
import Test.Hspec

-- | Each UI update runs the next phase of this script, recording what every call answered.
phased ∷ [String] → [String]
phased phases =
  [ "local phase = 0"
  , "local function try(label, ...)"
  , "  local ok, reason = intent.submit(...)"
  , "  fx.record(label .. ' ' .. tostring(ok) .. ' ' .. tostring(reason))"
  , "end"
  , "function update(self, dt)"
  , "  phase = phase + 1"
  , "  local session = view.session()"
  , "  local present, x, y, version = view.entity(0)"
  ]
    <> phases
    <> ["  ui.updated()", "end"]

holdingGameplay ∷ String
holdingGameplay = "function update(self, dt) fx.hold('gameplay') staging.finish() end"

spec ∷ Spec
spec = describe "the intention contract" $ do
  it "answers true once taken for the next unstarted tick, and full at once, without waiting for a held gameplay tick" $
    withSample
      ( \config →
          config
            { configBounds = (configBounds config) {boundQueue = 3, boundPlaces = 2}
            , configGameplaySource = luaLinesOf [holdingGameplay]
            , configUiSource =
                luaLinesOf . phased $
                  [ "  if phase == 1 then"
                  , "    try('a1', session, 0, 0, version, 1, 0)"
                  , "    try('a2', session, 0, 1, 0, 1, 0)"
                  , "    try('a3', session, 0, 2, 0, 1, 0)"
                  , "  elseif phase == 2 then"
                  , "    try('b1', session, 0, 3, 0, 1, 0)"
                  , "    try('b2', session, 0, 4, 0, 1, 0)"
                  , "    try('b3', session, 0, 5, 0, 1, 0)"
                  , "  end"
                  ]
            }
      )
      $ \fx ui domains → withReleased fx ["gameplay"] $ do
        -- Nothing has started: tick one takes two places, and the third is full by the tick's places.
        tickUi domains ui
        awaitUpdates domains 1
        fxLines fx `shouldReturn` ["a1 true nil", "a2 true nil", "a3 false full"]
        -- Hold gameplay inside tick one, which keeps its two reservations; tick two is the next
        -- unstarted tick and takes one more, and the queue's bound of three makes the rest full.
        collect ← spawn (stepTick domains)
        awaitEntered fx "gameplay"
        tickUi domains ui
        -- The UI's update completed while gameplay was held: the answers never waited for it.
        awaitUpdates domains 2
        fxLines fx `shouldReturn` ["a1 true nil", "a2 true nil", "a3 false full", "b1 true nil", "b2 false full", "b3 false full"]
        counts ← readTVarIO (sharedCounts (domainsShared domains))
        (countAccepted counts, countFull counts, countRefused counts, countMalformed counts) `shouldBe` (3, 3, 0, 0)
        releaseGate fx "gameplay"
        _ ← collect
        pure ()

  it "answers a malformed call as data, before the typed binding, without faulting the instance" $
    withSample
      ( \config →
          config
            { configGameplaySource = luaLinesOf ["function update(self, dt) staging.finish() end"]
            , configUiSource =
                luaLinesOf . phased $
                  [ "  try('no arguments')"
                  , "  try('three arguments', session, 0, 0)"
                  , "  try('seven arguments', session, 0, 0, version, 1, 0, 0)"
                  , "  try('a string', 'one', 0, 0, version, 1, 0)"
                  , "  try('a float', session, 0, 0.5, version, 1, 0)"
                  , "  try('an integral float', session, 0, 0.0, version, 1, 0)"
                  , "  try('a boolean', session, 0, 0, true, 1, 0)"
                  , "  try('a nil', session, 0, 0, nil, 1, 0)"
                  , "  try('a table', session, {}, 0, version, 1, 0)"
                  , "  try('a function', session, 0, 0, version, print, 0)"
                  , "  local protected = {pcall(intent.submit, 'x')}"
                  , "  fx.record('under pcall ' .. tostring(protected[1]) .. ' ' .. tostring(protected[2]) .. ' ' .. tostring(protected[3]))"
                  ]
            }
      )
      $ \fx ui domains → do
        tickUi domains ui
        awaitUpdates domains 1
        fxLines fx
          `shouldReturn` [ "no arguments false malformed"
                         , "three arguments false malformed"
                         , "seven arguments false malformed"
                         , "a string false malformed"
                         , "a float false malformed"
                         , "an integral float false malformed"
                         , "a boolean false malformed"
                         , "a nil false malformed"
                         , "a table false malformed"
                         , "a function false malformed"
                         , "under pcall true false malformed"
                         ]
        -- None was admitted, none reached the typed binding, and the instance is still active.
        counts ← readTVarIO (sharedCounts (domainsShared domains))
        counts `shouldBe` noCounts {countMalformed = 11}
        active ← atomically (inspectInstance (scheduledEndpoint (startedOwner (domainsUi domains))) (startedInstance (domainsUi domains)))
        fmap snapshotPhase active `shouldBe` Just Active

  it "answers a value over the application's bounds with the bound it broke, admitting nothing" $
    withSample
      ( \config →
          config
            { configGameplaySource = luaLinesOf ["function update(self, dt) staging.finish() end"]
            , configUiSource =
                luaLinesOf . phased $
                  [ "  try('entity past the world', session, 0, 99, 0, 1, 0)"
                  , "  try('negative entity', session, 0, -1, 0, 1, 0)"
                  , "  try('delta past the bound', session, 0, 0, 0, 9, 0)"
                  , "  try('second delta', session, 0, 0, 0, 0, -9)"
                  , "  try('negative version', session, 0, 0, -1, 1, 0)"
                  , "  try('negative session', -1, 0, 0, 0, 1, 0)"
                  , "  try('negative tick', session, -1, 0, 0, 1, 0)"
                  , "  try('at the bounds', session, 0, 7, 0, 8, -8)"
                  ]
            }
      )
      $ \fx ui domains → do
        tickUi domains ui
        awaitUpdates domains 1
        fxLines fx
          `shouldReturn` [ "entity past the world false entity"
                         , "negative entity false entity"
                         , "delta past the bound false delta"
                         , "second delta false delta"
                         , "negative version false version"
                         , "negative session false session"
                         , "negative tick false tick"
                         , "at the bounds true nil"
                         ]
        counts ← readTVarIO (sharedCounts (domainsShared domains))
        (countAccepted counts, countRefused counts, countMalformed counts) `shouldBe` (1, 7, 0)
  where
    luaLinesOf = luaLines . map Text.pack
