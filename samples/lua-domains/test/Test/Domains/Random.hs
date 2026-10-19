-- | The application-owned seeded stream for gameplay (requirement 12; D-23, D-44).
module Test.Domains.Random (spec) where

import Data.Maybe (fromJust)
import qualified Data.Text as Text
import Data.Word (Word64)
import Hetoimasia.Sample.LuaDomains
  ( Bounds (boundEntities)
  , DomainsConfig (configGameplaySource, configInput, configSeed, configUiSource)
  , GameSnapshot (snapWorld)
  , defaultBounds
  , stepTick
  )
import Hetoimasia.Sample.LuaDomains.World (World (worldRandom, worldTick), drawBelow, initialWorld, moveEntity)
import Test.Domains.Support
import Test.Hspec

-- | The sample's gameplay behavior, stated again as a pure model: three draws a tick, one move.
model ∷ Word64 → [World]
model seed = drop 1 (iterate step (initialWorld defaultBounds 1 seed))
  where
    entities = fromIntegral (boundEntities defaultBounds)
    step world =
      let (who, s1) = fromJust (drawBelow entities (worldRandom world))
          (dx, s2) = fromJust (drawBelow 3 s1)
          (dy, s3) = fromJust (drawBelow 3 s2)
       in (moveEntity (fromIntegral who) (dx - 1) (dy - 1) world) {worldTick = worldTick world + 1, worldRandom = s3}

-- | The committed worlds of this many ticks of a session at this seed, with no input at all: the
-- same initial state and the same (empty) tick-assigned intentions every time. The UI owner is
-- given this source, and its update is made due once before the ticks if the example asks.
sessionWorlds ∷ Word64 → Int → Maybe String → IO [World]
sessionWorlds seed ticks uiSource =
  withSample
    ( \config →
        config
          { configSeed = seed
          , configInput = []
          , configUiSource = maybe (configUiSource config) (luaLines . pure . Text.pack) uiSource
          }
    )
    $ \_ ui domains → do
      case uiSource of
        Nothing → pure ()
        Just _ → tickUi domains ui >> awaitUpdates domains 1
      mapM (const (snapWorld <$> stepTick domains)) [1 .. ticks]

probe ∷ String → [String]
probe own =
  [ "function init(self, api) fx.record('" <> own <> " random ' .. type(math.random) .. ' ' .. type(math.randomseed)) end"
  , "function update(self, dt) " <> (if own == "ui" then "ui.updated()" else "staging.finish()") <> " end"
  ]

spec ∷ Spec
spec = describe "gameplay's random stream" $ do
  it "gives the same seed the same committed worlds, and they are what the stream's pure model says" $ do
    first ← sessionWorlds 42 12 Nothing
    second ← sessionWorlds 42 12 Nothing
    first `shouldBe` second
    first `shouldBe` take 12 (model 42)

  it "gives a different seed a different sequence" $ do
    a ← sessionWorlds 42 12 Nothing
    b ← sessionWorlds 43 12 Nothing
    a `shouldNotBe` b
    map worldRandom a `shouldNotBe` map worldRandom b

  it "removes math.random and math.randomseed from the gameplay VM and keeps them in the UI VM" $
    withSample
      (\config → config {configGameplaySource = luaLines (map Text.pack (probe "gameplay")), configUiSource = luaLines (map Text.pack (probe "ui"))})
      $ \fx _ _ →
        fxLines fx `shouldReturn` ["gameplay random nil nil", "ui random function function"]

  it "leaves the gameplay stream and the committed worlds unchanged when a UI script draws many math.random values" $ do
    quiet ← sessionWorlds 7 10 Nothing
    drawing ← sessionWorlds 7 10 (Just uiDraws)
    drawing `shouldBe` quiet
  where
    uiDraws =
      unlines
        [ "function update(self, dt)"
        , "  math.randomseed(1234)"
        , "  for i = 1, 5000 do math.random() math.random(1, 100) end"
        , "  ui.updated()"
        , "end"
        ]
