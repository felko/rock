{-# language CPP #-}
{-# language DefaultSignatures #-}
{-# language FlexibleContexts #-}
{-# language FlexibleInstances #-}
{-# language FunctionalDependencies #-}
{-# language GADTs #-}
{-# language RankNTypes #-}
{-# language ScopedTypeVariables #-}
{-# language TupleSections #-}
{-# language TypeFamilies #-}
{-# language UndecidableInstances #-}
module Rock.Core where

import Control.Concurrent.MVar
import Control.Monad.Base
import Control.Monad.Cont
import Control.Monad.Except
import Control.Monad.Identity
import Control.Monad.Reader
import qualified Control.Monad.RWS.Lazy as Lazy
import qualified Control.Monad.RWS.Strict as Strict
import qualified Control.Monad.State.Lazy as Lazy
import qualified Control.Monad.State.Strict as Strict
import Control.Monad.Trans.Control
import Control.Monad.Trans.Maybe
import qualified Control.Monad.Writer.Lazy as Lazy
import qualified Control.Monad.Writer.Strict as Strict
import Data.Bifunctor
import Data.Constraint.Extras
import Data.Dependent.HashMap (DHashMap)
import qualified Data.Dependent.HashMap as DHashMap
import Data.Dependent.Sum
import Data.Foldable
import Data.Functor.Const
import Data.GADT.Compare (GEq, GCompare, geq, gcompare, GOrdering(..))
import Data.Hashable
import Data.HashMap.Lazy (HashMap)
import qualified Data.HashMap.Lazy as HashMap
import Data.HashSet (HashSet)
import qualified Data.HashSet as HashSet
import Data.IORef
import Data.Maybe
#if !MIN_VERSION_base(4,11,0)
import Data.Semigroup
#endif
import Data.Some
import Data.Type.Equality

import Rock.Traces(Traces)
import qualified Rock.Traces as Traces

-------------------------------------------------------------------------------
-- * Types

-- | A function which, given an @f@ query, returns a 'Task' allowed to make @f@
-- queries to compute its result.
type Rules f = GenRules f f

-- | A function which, given an @f@ query, returns a 'Task' allowed to make @g@
-- queries to compute its result.
type GenRules f g = forall a. f a -> Task g a

-- | An @IO@ action that is allowed to make @f@ queries using the 'fetch'
-- method from its 'MonadFetch' instance.
newtype Task f a = Task { unTask :: IO (Result f a) }

-- | The result of a @Task@, which is either done or wanting to make one or
-- more @f@ queries.
data Result f a where
  Done :: a -> Result f a
  Fetch :: f a -> (a -> Task f b) -> Result f b
  LiftBaseWith :: (RunInBase (Task f) IO -> IO a) -> (a -> Task f b) -> Result f b

-------------------------------------------------------------------------------
-- * Fetch class

-- | Monads that can make @f@ queries by 'fetch'ing them.
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
  fmap f (Task t) = Task $ fmap f <$> t

instance Applicative (Task f) where
  {-# INLINE pure #-}
  pure = Task . pure . Done
  {-# INLINE (<*>) #-}
  Task mrf <*> Task mrx = Task $ (<*>) <$> mrf <*> mrx

instance Monad (Task f) where
  {-# INLINE (>>) #-}
  (>>) = (*>)
  {-# INLINE (>>=) #-}
  Task ma >>= f = Task $ do
    ra <- ma
    case ra of
      Done a -> unTask $ f a
      Fetch key k -> return $ Fetch key $ k >=> f
      LiftBaseWith g k -> return $ LiftBaseWith g $ k >=> f

instance MonadIO (Task f) where
  {-# INLINE liftIO #-}
  liftIO io = Task $ pure <$> io

instance MonadBase IO (Task f) where
  {-# INLINE liftBase #-}
  liftBase = liftIO

instance MonadBaseControl IO (Task f) where
  type StM (Task f) a = a
  {-# INLINE liftBaseWith #-}
  liftBaseWith k = Task $ pure $ LiftBaseWith k pure
  {-# INLINE restoreM #-}
  restoreM = pure

instance MonadFetch f (Task f) where
  {-# INLINE fetch #-}
  fetch key = Task $ pure $ Fetch key pure

instance Functor (Result f) where
  {-# INLINE fmap #-}
  fmap f (Done x) = Done $ f x
  fmap f (Fetch key k) = Fetch key $ fmap f <$> k
  fmap f (LiftBaseWith g k) = LiftBaseWith g $ fmap f <$> k

instance Applicative (Result f) where
  {-# INLINE pure #-}
  pure = Done
  {-# INLINE (<*>) #-}
  Done f <*> y = f <$> y
  Fetch key k <*> y = Fetch key (\a -> k a <*> Task (pure y))
  LiftBaseWith g k <*> y = LiftBaseWith g (\a -> k a <*> Task (pure y))

-------------------------------------------------------------------------------
-- * Transformations

-- | Transform the type of queries that a 'Task' performs.
transFetch
  :: (forall b. f b -> Task f' b)
  -> Task f a
  -> Task f' a
transFetch f task = Task $ do
  result <- unTask task
  case result of
    Done a -> return $ Done a
    Fetch key k -> unTask $ f key >>= transFetch f . k
    LiftBaseWith g k -> return $
      LiftBaseWith (\runInBase -> g (runInBase . transFetch f)) (transFetch f . k)

-------------------------------------------------------------------------------
-- * Running tasks

-- | Perform a 'Task', fetching dependency queries from the given 'Rules' function and using the given 'Strategy' for fetches in an 'Applicative' context.
runTask :: Rules f -> Task f a -> IO a
runTask rules task = do
  result <- unTask task
  case result of
    Done a -> return a
    Fetch key k -> runTask rules (rules key) >>= runTask rules . k
    LiftBaseWith g k -> g (runTask rules) >>= runTask rules . k

-------------------------------------------------------------------------------
-- * Task combinators

-- | Track the query dependencies of a 'Task' in a 'DHashMap'.
track
  :: forall f g a. (GEq f, Hashable (Some f))
  => (forall a'. f a' -> a' -> g a')
  -> Task f a
  -> Task f (a, DHashMap f g)
track f =
  trackM $ \key -> pure . f key

-- | Track the query dependencies of a 'Task' in a 'DHashMap'. Monadic version.
trackM
  :: forall f g a. (GEq f, Hashable (Some f))
  => (forall a'. f a' -> a' -> Task f (g a'))
  -> Task f a
  -> Task f (a, DHashMap f g)
trackM f task = do
  depsVar <- liftIO $ newIORef mempty
  let
    record :: f b -> Task f b
    record key = do
      value <- fetch key
      g <- f key value
      liftIO $ atomicModifyIORef depsVar $ (, ()) . DHashMap.insert key g
      return value
  result <- transFetch record task
  deps <- liftIO $ readIORef depsVar
  return (result, deps)

-- | Remember what @f@ queries have already been performed and their results in
-- a 'DHashMap', and reuse them if a query is performed again a second time.
--
-- The 'DHashMap' should typically not be reused if there has been some change that
-- might make a query return a different result.
memoise
  :: forall f g
  . (GEq f, Hashable (Some f))
  => IORef (DHashMap f MVar)
  -> GenRules f g
  -> GenRules f g
memoise startedVar rules (key :: f a) = do
  maybeValueVar <- DHashMap.lookup key <$> liftIO (readIORef startedVar)
  case maybeValueVar of
    Nothing -> do
      valueVar <- liftIO newEmptyMVar
      join $ liftIO $ atomicModifyIORef startedVar $ \started ->
        case DHashMap.alterLookup (Just . fromMaybe valueVar) key started of
          (Nothing, started') ->
            ( started'
            , do
              value <- rules key
              liftIO $ putMVar valueVar value
              return value
            )

          (Just valueVar', _started') ->
            (started, liftIO $ readMVar valueVar')

    Just valueVar ->
      liftIO $ readMVar valueVar

-- | Remember the results of previous @f@ queries and what their dependencies
-- were then.
--
-- If all dependencies of a 'NonInput' query are the same, reuse the old result.
-- 'Input' queries are not reused.
verifyTraces
  :: (Hashable (Some f), GEq f, Has' Eq f dep)
  => IORef (Traces f dep)
  -> (forall a. f a -> a -> Task f (dep a))
  -> GenRules (Writer TaskKind f) f
  -> Rules f
verifyTraces tracesVar createDependencyRecord rules key = do
  traces <- liftIO $ readIORef tracesVar
  maybeValue <- case DHashMap.lookup key traces of
    Nothing -> return Nothing
    Just oldValueDeps ->
      Traces.verifyDependencies fetch createDependencyRecord oldValueDeps
  case maybeValue of
    Nothing -> do
      ((value, taskKind), deps) <- trackM createDependencyRecord $ rules $ Writer key
      case taskKind of
        Input ->
          return ()
        NonInput ->
          liftIO $ atomicModifyIORef tracesVar
            $ (, ()) . Traces.record key value deps
      return value
    Just value -> return value

data TaskKind
  = Input -- ^ Used for tasks whose results can change independently of their fetched dependencies, i.e. inputs.
  | NonInput -- ^ Used for task whose results only depend on fetched dependencies.

-- | A query that returns a @w@ alongside the ordinary @a@.
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

-- | @'writer' write rules@ runs @write w@ each time a @w@ is returned from a
-- rule in @rules@.
writer
  :: forall f w g
  . (forall a. f a -> w -> Task g ())
  -> GenRules (Writer w f) g
  -> GenRules f g
writer write rules key = do
  (res, w) <- rules $ Writer key
  write key w
  return res

-- | @'traceFetch' before after rules@ runs @before q@ before a query is
-- performed from @rules@, and @after q result@ every time a query returns with
-- result @result@. 
traceFetch
  :: (forall a. f a -> Task g ())
  -> (forall a. f a -> a -> Task g ())
  -> GenRules f g
  -> GenRules f g
traceFetch before after rules key = do
  before key
  result <- rules key
  after key result
  return result

type ReverseDependencies f = HashMap (Some f) (HashSet (Some f))

-- | Write reverse dependencies to the 'IORef.
trackReverseDependencies
  :: (GEq f, Hashable (Some f))
  => IORef (ReverseDependencies f)
  -> Rules f
  -> Rules f
trackReverseDependencies reverseDepsVar rules key = do
  (res, deps) <- track (\_ _ -> Const ()) $ rules key
  unless (DHashMap.null deps) $ do
    let newReverseDeps = HashMap.fromListWith (<>)
          [ (Some depKey, HashSet.singleton $ Some key)
          | depKey :=> Const () <- DHashMap.toList deps
          ]
    liftIO $ atomicModifyIORef reverseDepsVar $ (, ()) . HashMap.unionWith (<>) newReverseDeps
  pure res

-- | @'reachableReverseDependencies' key@ returns all keys reachable, by
-- reverse dependency, from @key@ from the input 'DHashMap'. It also returns the
-- reverse dependency map with those same keys removed.
reachableReverseDependencies
  :: (GEq f, Hashable (Some f))
  => f a
  -> ReverseDependencies f
  -> (DHashMap f (Const ()), ReverseDependencies f)
reachableReverseDependencies key reverseDeps =
  foldl'
    (\(m', reverseDeps') (Some key') -> first (<> m') $ reachableReverseDependencies key' reverseDeps')
    (DHashMap.singleton key $ Const (), HashMap.delete (Some key) reverseDeps)
    (HashSet.toList $ HashMap.lookupDefault mempty (Some key) reverseDeps)
