-- | The exit classification ("Hetoimasia.Foundation.Exit"): every row of its decision table, each exception carried
-- with its original, distinguishable context, and each refusal with its value.
module Test.Foundation.Ownership.Exits (spec) where

import Control.Exception
  ( AsyncException (ThreadKilled)
  , ErrorCall (ErrorCall)
  , Exception
  , ExceptionWithContext (ExceptionWithContext)
  , SomeException
  , catch
  , fromException
  , throwIO
  , toException
  , try
  )
import Control.Exception.Annotation (ExceptionAnnotation (displayExceptionAnnotation))
import Control.Exception.Context (addExceptionAnnotation, emptyExceptionContext, getExceptionAnnotations)
import Data.IORef (newIORef, readIORef, writeIORef)
import Hetoimasia.Foundation.Exit
import Test.Hspec

-- A distinguishable annotation: which raise a context belongs to.
newtype Site = Site String
  deriving (Eq, Show)

instance ExceptionAnnotation Site where
  displayExceptionAnnotation (Site name) = "raised at " <> name

-- An exception with a nonempty context naming its site.
raisedAt ∷ Exception e ⇒ String → e → ExceptionWithContext SomeException
raisedAt site exception = ExceptionWithContext (addExceptionAnnotation (Site site) emptyExceptionContext) (toException exception)

-- What an exit is, with the site and the exception (or the refusal) it carries.
data Seen = SeenCompleted Int | SeenRefused String | SeenRaised [Site] String | SeenCancelled [Site] String | SeenTerminalRefusal String | SeenTerminal [Site] String
  deriving (Eq, Show)

seen ∷ Exit String Int → Seen
seen = \case
  Completed value → SeenCompleted value
  Refused refusal → SeenRefused refusal
  Raised carried → uncurry SeenRaised (carriedBy carried)
  Cancelled carried → uncurry SeenCancelled (carriedBy carried)
  Terminal (Left refusal) → SeenTerminalRefusal refusal
  Terminal (Right carried) → uncurry SeenTerminal (carriedBy carried)
  where
    carriedBy (ExceptionWithContext annotated exception) =
      ( getExceptionAnnotations annotated
      , case (fromException exception, fromException exception) of
          (Just (ErrorCall message), _) → message
          (_, Just (killed ∷ AsyncException)) → show killed
          _ → "another exception"
      )

spec ∷ Spec
spec = describe "exits" $ do
  let synchronous = raisedAt "the operation" (ErrorCall "the operation failed")
      asynchronous = raisedAt "the canceller" ThreadKilled
      escape = raisedAt "the construction" (ErrorCall "the construction escaped")
      returned ∷ Either (ExceptionWithContext SomeException) (Either String Int)
      returned = Right (Right 7)
      refusal ∷ Either (ExceptionWithContext SomeException) (Either String Int)
      refusal = Right (Left "full for now")
  it "classifies every result while the issuer lives: a value, a refusal, a recoverable raise, a cancellation" $ do
    seen (classifyExit IssuerLive returned) `shouldBe` SeenCompleted 7
    seen (classifyExit IssuerLive refusal) `shouldBe` SeenRefused "full for now"
    seen (classifyExit IssuerLive (Left synchronous)) `shouldBe` SeenRaised [Site "the operation"] "the operation failed"
    seen (classifyExit IssuerLive (Left asynchronous)) `shouldBe` SeenCancelled [Site "the canceller"] "thread killed"

  it "classifies every result once the issuer has ended: the value stands, a refusal and a raise are terminal, a cancellation stays one" $ do
    seen (classifyExit IssuerEnded returned) `shouldBe` SeenCompleted 7
    seen (classifyExit IssuerEnded refusal) `shouldBe` SeenTerminalRefusal "full for now"
    seen (classifyExit IssuerEnded (Left synchronous)) `shouldBe` SeenTerminal [Site "the operation"] "the operation failed"
    seen (classifyExit IssuerEnded (Left asynchronous)) `shouldBe` SeenCancelled [Site "the canceller"] "thread killed"

  it "classifies every result after an escaped construction: the escape is terminal under a value or a refusal, the operation's own raise is terminal, and a cancellation keeps its priority" $ do
    seen (classifyExit (IssuerEscaped escape) returned) `shouldBe` SeenTerminal [Site "the construction"] "the construction escaped"
    seen (classifyExit (IssuerEscaped escape) refusal) `shouldBe` SeenTerminal [Site "the construction"] "the construction escaped"
    seen (classifyExit (IssuerEscaped escape) (Left synchronous)) `shouldBe` SeenTerminal [Site "the operation"] "the operation failed"
    seen (classifyExit (IssuerEscaped escape) (Left asynchronous)) `shouldBe` SeenCancelled [Site "the canceller"] "thread killed"

  it "answers an action that caught its construction's fatal failure and returned normally with that failure, terminal, in its original context" $ do
    recorded ← newIORef Nothing
    -- the construction records what escaped it, as an issuer does, and raises it
    let construction = do
          let failure = raisedAt "the lent construction" (ErrorCall "the device was lost")
          writeIORef recorded (Just failure)
          throwIO (ErrorCall "the device was lost")
    -- the action catches it and returns normally
    outcome ← tryExit ((Right <$> construction) `catch` \(ErrorCall _) → pure (Right (0 ∷ Int)) ∷ IO (Either String Int))
    standing ← maybe IssuerLive IssuerEscaped <$> readIORef recorded
    seen (classifyExit standing outcome) `shouldBe` SeenTerminal [Site "the lent construction"] "the device was lost"

  it "delivers a recoverable raise as the original exception, and a refusal and a value as they were" $ do
    delivered ← try (deliverExit (classifyExit IssuerLive (Left synchronous) ∷ Exit String Int))
    either (\(ErrorCall message) → message) (const "delivered nothing") delivered `shouldBe` "the operation failed"
    deliverExit (classifyExit IssuerLive refusal) `shouldReturn` Left "full for now"
    deliverExit (classifyExit IssuerLive returned) `shouldReturn` Right 7
