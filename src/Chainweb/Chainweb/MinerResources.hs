{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeFamilies #-}

-- |
-- Module: Chainweb.Chainweb.MinerResources
-- Copyright: Copyright © 2019 Kadena LLC.
-- License: MIT
-- Maintainer: Lars Kuhtz <lars@kadena.io>
-- Stability: experimental
--
-- TODO
--
module Chainweb.Chainweb.MinerResources
  ( -- * In-process Mining
    MinerResources(..)
  , withMinerResources
  , runMiner
    -- * Remote Work Requests
  , MiningCoordination(..)
  , withMiningCoordination
  ) where

import Data.Generics.Wrapped (_Unwrapped)
import qualified Data.HashMap.Strict as HM
import qualified Data.HashSet as HS
import Data.IORef (IORef, atomicWriteIORef, newIORef, readIORef)
import qualified Data.Map.Strict as M
import Data.Tuple.Strict (T2(..), T3(..))
import qualified Data.Vector as V

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (Concurrently(..), runConcurrently)
import Control.Concurrent.STM (atomically)
import Control.Concurrent.STM.TVar
import Control.Lens (over, view, (^?!))

import System.LogLevel (LogLevel(..))
import qualified System.Random.MWC as MWC

-- internal modules

import Chainweb.BlockHeader (BlockCreationTime(..), BlockHeader(..))
import Chainweb.ChainId (_chainId)
import Chainweb.Cut (Cut, _cutMap)
import Chainweb.CutDB (CutDb, awaitNewCut, cutDbPayloadStore, _cut)
import Chainweb.Logger (Logger, logFunction)
import Chainweb.Miner.Config (MinerConfig(..))
import Chainweb.Miner.Coordinator
    (CachedPayloads(..), MiningState(..), MiningStats(..), PrevTime(..))
import Chainweb.Miner.Miners
import Chainweb.Miner.Pact (Miner)
import Chainweb.Payload (PayloadWithOutputs(..))
import Chainweb.Payload.PayloadStore
import Chainweb.Sync.WebBlockHeaderStore (PactExecutionService, _pactNewBlock)
import Chainweb.Sync.WebBlockHeaderStore (_webBlockPayloadStorePact)
import Chainweb.Time (Micros, Time(..), getCurrentTimeIntegral)
import Chainweb.Utils (EnableConfig(..), int, ixg, runForever, thd)
import Chainweb.Version (ChainId, ChainwebVersion(..), chainIds, window)
import Chainweb.WebPactExecutionService (_webPactExecutionService)

import Data.LogMessage (JsonLog(..), LogFunction)

-- -------------------------------------------------------------------------- --
-- Miner

-- | For coordinating requests for work and mining solutions from remote Mining
-- Clients.
--
data MiningCoordination logger cas = MiningCoordination
    { _coordLogger :: !logger
    , _coordCutDb :: !(CutDb cas)
    , _coordState :: !(TVar MiningState)
    , _coordLimit :: !Int
    , _coord503s :: !(IORef Int)
    , _coordMiners :: !(TVar CachedPayloads)
      -- ^ "Blessed" miners who have payloads pre-cached for fast work request
      -- turn-around.
    }

withMiningCoordination
    :: Logger logger
    => logger
    -> ChainwebVersion
    -> Bool
    -> [Miner]
    -> CutDb cas
    -> (Maybe (MiningCoordination logger cas) -> IO a)
    -> IO a
withMiningCoordination logger ver enabled miners cdb inner
    | not enabled = inner Nothing
    | otherwise = do
        cut <- _cut cdb
        t <- newTVarIO mempty
        m <- initialPayloads cut miners >>= newTVarIO
        c <- newIORef 0
        fmap thd . runConcurrently $ (,,)
            <$> Concurrently (prune t c)
            <*> Concurrently (cachePayloads m cut)
            <*> Concurrently (inner . Just $ MiningCoordination
                { _coordLogger = logger
                , _coordCutDb = cdb
                , _coordState = t
                , _coordLimit = 2500
                , _coord503s = c
                , _coordMiners = m })
  where
    cids :: [ChainId]
    cids = HS.toList $ chainIds ver

    pact :: PactExecutionService
    pact = _webPactExecutionService . _webBlockPayloadStorePact $ view cutDbPayloadStore cdb

    initialPayloads :: Cut -> [Miner] -> IO CachedPayloads
    initialPayloads cut ms =
        CachedPayloads . M.fromList <$> traverse (\m -> (m,) <$> fromCut m pairs) ms
      where
        pairs = map (\cid -> (cid, cut ^?! ixg cid)) cids

    fromCut
      :: Miner
      -> [(ChainId, BlockHeader)]
      -> IO (M.Map ChainId (T2 PayloadWithOutputs BlockCreationTime))
    fromCut m cut = M.fromList <$> traverse (\(cid, bh) -> (cid,) <$> getPayload m bh) cut

    getPayload :: Miner -> BlockHeader -> IO (T2 PayloadWithOutputs BlockCreationTime)
    getPayload m parent = do
        creationTime <- BlockCreationTime <$> getCurrentTimeIntegral
        payload <- _pactNewBlock pact m parent creationTime
        pure $ T2 payload creationTime

    cachePayloads :: TVar CachedPayloads -> Cut -> IO ()
    cachePayloads tcp old = do
        new <- awaitNewCut cdb old
        let oldMap  = _cutMap old
            parents = HM.elems $ HM.filterWithKey (h oldMap) $ _cutMap new
        CachedPayloads cached <- readTVarIO tcp
        newCached <- M.traverseWithKey (g parents) cached
        atomically . writeTVar tcp $ CachedPayloads newCached
        cachePayloads tcp new
      where
        g :: [BlockHeader]
          -> Miner
          -> M.Map ChainId (T2 PayloadWithOutputs BlockCreationTime)
          -> IO (M.Map ChainId (T2 PayloadWithOutputs BlockCreationTime))
        g ps miner pays = do
            news <- M.fromList <$> traverse (\p -> (_chainId p,) <$> getPayload miner p) ps
            -- `union` is left-biased, and so prefers items from the first Map
            -- when duplicate keys are encountered.
            pure $ M.union news pays

        h :: HM.HashMap ChainId BlockHeader -> ChainId -> BlockHeader -> Bool
        h olds cid b = case HM.lookup cid olds of
            Nothing -> False
            Just bold -> _blockHeight bold < _blockHeight b

    prune :: TVar MiningState -> IORef Int -> IO ()
    prune t c = runForever (logFunction logger) "Chainweb.Chainweb.MinerResources.prune" $ do
        let !d = 300000000  -- 5 minutes
        threadDelay d
        ago <- over (_Unwrapped . _Unwrapped) (subtract (int d)) <$> getCurrentTimeIntegral
        m@(MiningState ms) <- atomically $ do
            ms <- readTVar t
            modifyTVar' t . over _Unwrapped $ M.filter (f ago)
            pure ms
        count <- readIORef c
        atomicWriteIORef c 0
        logFunction logger Info . JsonLog $ MiningStats (M.size ms) count (avgTxs m)

    f :: Time Micros -> T3 a PrevTime b -> Bool
    f ago (T3 _ (PrevTime p) _) = p > BlockCreationTime ago

    avgTxs :: MiningState -> Int
    avgTxs (MiningState ms) = summed `div` max 1 (M.size ms)
      where
        summed :: Int
        summed = M.foldl' (\acc (T3 _ _ ps) -> acc + g ps) 0 ms

        g :: PayloadWithOutputs -> Int
        g = V.length . _payloadWithOutputsTransactions

-- | For in-process CPU mining by a Chainweb Node.
--
data MinerResources logger cas = MinerResources
    { _minerResLogger :: !logger
    , _minerResCutDb :: !(CutDb cas)
    , _minerResConfig :: !MinerConfig
    }

withMinerResources
    :: logger
    -> EnableConfig MinerConfig
    -> CutDb cas
    -> (Maybe (MinerResources logger cas) -> IO a)
    -> IO a
withMinerResources logger (EnableConfig enabled conf) cutDb inner
    | not enabled = inner Nothing
    | otherwise = do
        inner . Just $ MinerResources
            { _minerResLogger = logger
            , _minerResCutDb = cutDb
            , _minerResConfig = conf
            }

runMiner
    :: forall logger cas
    .  Logger logger
    => PayloadCas cas
    => ChainwebVersion
    -> MinerResources logger cas
    -> IO ()
runMiner v mr = case window v of
    Nothing -> testMiner
    Just _ -> powMiner
  where
    cdb :: CutDb cas
    cdb = _minerResCutDb mr

    conf :: MinerConfig
    conf = _minerResConfig mr

    lf :: LogFunction
    lf = logFunction $ _minerResLogger mr

    testMiner :: IO ()
    testMiner = do
        gen <- MWC.createSystemRandom
        tcp <- newTVarIO $ CachedPayloads mempty
        localTest lf v tcp (_configMinerInfo conf) cdb gen (_configTestMiners conf)

    powMiner :: IO ()
    powMiner = do
        tcp <- newTVarIO $ CachedPayloads mempty
        localPOW lf v tcp (_configMinerInfo conf) cdb
