{-# language DefaultSignatures #-}
{-# language DeriveFunctor #-}
{-# language FlexibleInstances #-}
{-# language FunctionalDependencies #-}
{-# language GADTs #-}
{-# language GeneralizedNewtypeDeriving #-}
{-# language MultiParamTypeClasses #-}
{-# language RankNTypes #-}
{-# language ScopedTypeVariables #-}
{-# language UndecidableInstances #-}
module Rock.Core where

import Protolude

import Control.Monad.Cont
import Control.Monad.Identity
import qualified Control.Monad.RWS.Lazy as Lazy
import qualified Control.Monad.RWS.Strict as Strict
import qualified Control.Monad.State.Lazy as Lazy
import qualified Control.Monad.State.Strict as Strict
import Control.Monad.Trans.Maybe
import qualified Control.Monad.Writer.Lazy as Lazy
import qualified Control.Monad.Writer.Strict as Strict
import Data.Dependent.Map(DMap, GCompare)
import qualified Data.Dependent.Map as DMap
import Data.GADT.Compare

import Rock.Hashed
import Rock.HashTag
import Rock.Traces(Traces)
import qualified Rock.Traces as Traces

-------------------------------------------------------------------------------
-- Types

type Rules f = GenRules f f

type GenRules f g = forall a. f a -> Task g a

newtype Task f a = MkTask { unTask :: IO (Result f a) }

data Result f a
  = Done a
  | Blocked !(BlockedTask f a)

data BlockedTask f a where
  BlockedTask :: Block f a -> (a -> Task f b) -> BlockedTask f b

data Block f a where
  Fetch :: f a -> Block f a
  Fork :: !(BlockedTask f (a -> b)) -> !(BlockedTask f a) -> Block f b

-------------------------------------------------------------------------------
-- Fetch class

class Monad m => MonadFetch f m | m -> f where
  fetch :: f a -> m a
  default fetch
    :: (MonadTrans t, MonadFetch f m1, m ~ t m1)
    => f a
    -> m a
  fetch = lift . fetch

instance MonadFetch f m => MonadFetch f (ContT r m)
instance MonadFetch f m => MonadFetch f (ExceptT e m)
instance MonadFetch f m => MonadFetch f (IdentityT m)
instance MonadFetch f m => MonadFetch f (MaybeT m)
instance MonadFetch f m => MonadFetch f (ReaderT r m)
instance (MonadFetch f m, Monoid w) => MonadFetch f (Strict.RWST r w s m)
instance (MonadFetch f m, Monoid w) => MonadFetch f (Lazy.RWST r w s m)
instance MonadFetch f m => MonadFetch f (Strict.StateT s m)
instance MonadFetch f m => MonadFetch f (Lazy.StateT s m)
instance (Monoid w, MonadFetch f m) => MonadFetch f (Strict.WriterT w m)
instance (Monoid w, MonadFetch f m) => MonadFetch f (Lazy.WriterT w m)

-------------------------------------------------------------------------------
-- Instances

instance Functor (Task f) where
  {-# INLINE fmap #-}
  fmap f (MkTask t) = MkTask $ fmap f <$> t

instance Applicative (Task f) where
  {-# INLINE pure #-}
  pure = MkTask . pure . Done
  {-# INLINE (<*>) #-}
  MkTask mrf <*> MkTask mrx = MkTask $ (<*>) <$> mrf <*> mrx

instance Monad (Task f) where
  {-# INLINE (>>) #-}
  (>>) = (*>)
  {-# INLINE (>>=) #-}
  MkTask ma >>= f = MkTask $ do
    ra <- ma
    case ra of
      Done a -> unTask $ f a
      Blocked (BlockedTask b k) -> return $ Blocked $ BlockedTask b $ k >=> f

instance MonadIO (Task f) where
  {-# INLINE liftIO #-}
  liftIO io = MkTask $ pure <$> io

instance Functor (Result f) where
  {-# INLINE fmap #-}
  fmap f (Done x) = Done $ f x
  fmap f (Blocked b) = Blocked $ f <$> b

instance Applicative (Result f) where
  {-# INLINE pure #-}
  pure = Done
  {-# INLINE (<*>) #-}
  Done f <*> Done x = Done $ f x
  Done f <*> Blocked b = Blocked $ f <$> b
  Blocked b <*> Done x = Blocked $ ($ x) <$> b
  Blocked b1 <*> Blocked b2 = Blocked $ BlockedTask (Fork b1 b2) pure

instance Monad (Result f) where
  {-# INLINE (>>) #-}
  (>>) = (*>)
  {-# INLINE (>>=) #-}
  Done x >>= f = f x
  Blocked (BlockedTask b t) >>= f = Blocked $ BlockedTask b $ t >=> MkTask . pure . f

instance Functor (BlockedTask f) where
  {-# INLINE fmap #-}
  fmap f (BlockedTask b t) = BlockedTask b $ fmap f <$> t

-------------------------------------------------------------------------------

transFetch
  :: (forall b. f b -> Task f' b)
  -> Task f a
  -> Task f' a
transFetch f task = MkTask $ do
  result <- unTask task
  case result of
    Done a -> return $ Done a
    Blocked b -> unTask $ transFetchBT f b

transFetchBT
  :: (forall b. f b -> Task f' b)
  -> BlockedTask f a
  -> Task f' a
transFetchBT f (BlockedTask b t) = do
  a <- transFetchB f b
  transFetch f $ t a

transFetchB
  :: (forall b. f b -> Task f' b)
  -> Block f a
  -> Task f' a
transFetchB f (Fetch k) = f k
transFetchB f (Fork b1 b2) = transFetchBT f b1 <*> transFetchBT f b2

-------------------------------------------------------------------------------

instance MonadFetch f (Task f) where
  fetch key = MkTask $ pure $ Blocked $ BlockedTask (Fetch key) pure

-------------------------------------------------------------------------------

type Strategy = forall a b. IO (a -> b) -> IO a -> IO b

sequentially :: Strategy
sequentially = (<*>)

inParallel :: Strategy
inParallel mf mx = withAsync mf $ \af -> do
  x <- mx
  f <- wait af
  return $ f x

-- | Uses the underlying instances, except for the Applicative instance which
-- is defined in terms of 'return' and '(>>=)'.
--
-- When used with 'Task', i.e. if you construct @m :: 'Sequential' ('Task' f)
-- a@, this means that fetches within @m@ are done sequentially.
newtype Sequential m a = Sequential { runSequential :: m a }
  deriving (Functor, Monad, MonadIO, MonadFetch f)

-- | Defined in terms of 'return' and '(>>=)'.
instance Monad m => Applicative (Sequential m) where
  {-# INLINE pure #-}
  pure = Sequential . return
  {-# INLINE (<*>) #-}
  Sequential mf <*> Sequential mx = Sequential $ mf >>= \f -> fmap f mx

-------------------------------------------------------------------------------

runTask :: Strategy -> Rules f -> Task f a -> IO a
runTask fork rules task = do
  result <- unTask task
  case result of
    Done a -> return a
    Blocked b -> runBT fork rules b

runBT :: Strategy -> Rules f -> BlockedTask f a -> IO a
runBT fork rules (BlockedTask b f) = do
  a <- runB fork rules b
  runTask fork rules $ f a

runB :: Strategy -> Rules f -> Block f a -> IO a
runB fork rules (Fetch key) =
  runTask fork rules $ rules key
runB fork rules (Fork bf bx) =
  fork (runBT fork rules bf) (runBT fork rules bx)

-------------------------------------------------------------------------------

track :: forall f a. GCompare f => Task f a -> Task f (a, DMap f Identity)
track task = do
  depsVar <- liftIO $ newMVar mempty
  let
    record :: f b -> Task f b
    record key = do
      value <- fetch key
      liftIO $ modifyMVar_ depsVar $ pure . DMap.insert key (Identity value)
      return value
  result <- transFetch record task
  deps <- liftIO $ readMVar depsVar
  return (result, deps)

memoise
  :: forall f g
  . GCompare f
  => MVar (DMap f MVar)
  -> GenRules f g
  -> GenRules f g
memoise startedVar rules (key :: f a) = do
  join $ liftIO $ modifyMVar startedVar $ \started ->
    case DMap.lookup key started of
      Nothing -> do
        valueVar <- newEmptyMVar
        return
          ( DMap.insert key valueVar started
          , do
            value <- rules key
            liftIO $ putMVar valueVar value
            return value
          )
      Just valueVar ->
        return (started, liftIO $ readMVar valueVar)

verifyTraces
  :: (GCompare f, HashTag f)
  => MVar (Traces f)
  -> Rules f
  -> Rules f
verifyTraces tracesVar rules key = do
  traces <- liftIO $ readMVar tracesVar
  maybeValue <- case DMap.lookup key traces of
    Nothing -> return Nothing
    Just oldValueDeps ->
      Traces.verifyDependencies fetchHashed oldValueDeps
  case maybeValue of
    Nothing -> do
      (value, deps) <- track $ rules key
      liftIO $ modifyMVar_ tracesVar
        $ pure
        . Traces.record key value deps
      return value
    Just value -> return value
  where
    fetchHashed :: HashTag f => f a -> Task f (Hashed a)
    fetchHashed key' = hashed key' <$> fetch key'

data Writer w f a where
  Writer :: f a -> Writer w f (a, w)

instance GEq f => GEq (Writer w f) where
  geq (Writer f) (Writer g) = case geq f g of
    Nothing -> Nothing
    Just Refl -> Just Refl

instance GCompare f => GCompare (Writer w f) where
  gcompare (Writer f) (Writer g) = case gcompare f g of
    GLT -> GLT
    GEQ -> GEQ
    GGT -> GGT

writer
  :: forall f w g
  . (forall a. f a -> w -> IO ())
  -> GenRules (Writer w f) g
  -> GenRules f g
writer write rules key = do
  (res, w) <- rules $ Writer key
  liftIO $ write key w
  return res

versioned
  :: forall f version g
  . GCompare f
  => MVar (DMap f (Const version))
  -> version
  -> GenRules f g
  -> GenRules f g
versioned var version rules key = do
  res <- rules key
  liftIO $ modifyMVar_ var $ pure . DMap.insert key (Const version)
  return res

traceFetch
  :: (forall a. f a -> IO ())
  -> (forall a. f a -> a -> IO ())
  -> GenRules f g
  -> GenRules f g
traceFetch before after rules key = do
  liftIO $ before key
  result <- rules key
  liftIO $ after key result
  return result
