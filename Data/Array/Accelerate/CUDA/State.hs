{-# LANGUAGE CPP, GADTs, PatternGuards, TemplateHaskell #-}
{-# LANGUAGE TupleSections, TypeFamilies, TypeOperators #-}
-- |
-- Module      : Data.Array.Accelerate.CUDA.State
-- Copyright   : [2008..2011] Manuel M T Chakravarty, Gabriele Keller, Sean Lee, Trevor L. McDonell
-- License     : BSD3
--
-- Maintainer  : Manuel M T Chakravarty <chak@cse.unsw.edu.au>
-- Stability   : experimental
-- Portability : non-partable (GHC extensions)
--
-- This module defines a state monad token which keeps track of the code
-- generator state, including memory transfers and external compilation
-- processes.
--

module Data.Array.Accelerate.CUDA.State (

  -- Types
  CIO, KernelTable, KernelKey, KernelEntry(KernelEntry),

  -- Evaluating computations
  evalCUDA, defaultContext, deviceProps,
  memoryTable, kernelTable, kernelName, kernelStatus

) where

-- friends
import Data.Array.Accelerate.CUDA.Debug                 ( message, verbose )
import Data.Array.Accelerate.CUDA.Array.Table           as MT
import Data.Array.Accelerate.CUDA.Analysis.Device

-- library
import Numeric
import Data.List
import Data.Label
import Control.Exception
import Data.ByteString                                  ( ByteString )
import Control.Monad.State.Strict                       ( StateT(..), evalStateT )
import System.Process                                   ( ProcessHandle )
import System.IO.Unsafe
import Text.PrettyPrint
import qualified Foreign.CUDA.Driver                    as CUDA hiding ( device )
import qualified Foreign.CUDA.Driver.Context            as CUDA ( device )
import qualified Data.HashTable.IO                      as HT

#ifdef ACCELERATE_CUDA_PERSISTENT_CACHE
import Data.Binary                                      ( encodeFile, decodeFile )
import Control.Arrow                                    ( second )
import Paths_accelerate                                 ( getDataDir )
#endif


-- An exact association between an accelerate computation and its
-- implementation, which is either a reference to the external compiler (nvcc)
-- or the resulting binary module.
--
-- We aren't concerned with true (typed) equality of an OpenAcc expression,
-- since we largely want to disregard the array environment; we really only want
-- to assert the type and index of those variables that are accessed by the
-- computation and no more, but we can not do that. Instead, this is keyed to
-- the generated kernel code.
--
type KernelTable = HT.BasicHashTable KernelKey KernelEntry

type KernelKey   = ByteString
data KernelEntry = KernelEntry
  {
    _kernelName         :: FilePath,
    _kernelStatus       :: Either ProcessHandle CUDA.Module
  }

-- The state token for accelerated CUDA array operations
--
type CIO        = StateT CUDAState IO
data CUDAState  = CUDAState
  {
    _deviceProps        :: CUDA.DeviceProperties,
    _kernelTable        :: !KernelTable,
    _memoryTable        :: !MemoryTable
  }

$(mkLabels [''CUDAState, ''KernelEntry])


-- Execution State
-- ---------------

-- |Evaluate a CUDA array computation
--
evalCUDA :: CUDA.Context -> CIO a -> IO a
evalCUDA ctx acc = bracket setup teardown $ evalStateT acc
  where
    teardown _  = CUDA.pop
    setup       = do
      CUDA.push ctx
      dev       <- CUDA.device
      prp       <- CUDA.props dev
      return $ initialise { _deviceProps = prp }


-- Select and initialise the CUDA device, and create a new execution context.
-- This will be done only once per program execution, as initialising the CUDA
-- context is relatively expensive.
--
{-# NOINLINE initialise #-}
initialise :: CUDAState
initialise = unsafePerformIO $ do
  knl   <- HT.new
  mem   <- MT.new
  return $ CUDAState undefined knl mem

{-# NOINLINE defaultContext #-}
defaultContext :: CUDA.Context
defaultContext = unsafePerformIO $ do
  CUDA.initialise []
  (dev,prp)     <- selectBestDevice
  _             <- CUDA.create dev [CUDA.SchedAuto]
  message verbose $ deviceInfo dev prp
  CUDA.pop


-- Debugging
-- ---------

-- Nicely format a summary of the selected CUDA device, example:
--
-- Device 0: GeForce 9600M GT (compute capability 1.1)
--           4 multiprocessors @ 1.25GHz (32 cores), 512MB global memory
--
deviceInfo :: CUDA.Device -> CUDA.DeviceProperties -> String
deviceInfo dev prp = render $
  devID <> colon <+> vcat [ name <+> parens compute
                          , processors <+> at <+> text clock <+> parens cores <> comma <+> memory
                          ]
  where
    name        = text (CUDA.deviceName prp)
    compute     = text "compute capatability" <+> double (CUDA.computeCapability prp)
    devID       = text "Device" <+> int (fromIntegral $ CUDA.useDevice dev)     -- hax
    processors  = int (CUDA.multiProcessorCount prp)                              <+> text "multiprocessors"
    cores       = int (CUDA.multiProcessorCount prp * coresPerMultiProcessor prp) <+> text "cores"
    memory      = text mem <+> text "global memory"
    --
    clock       = showFFloatSIBase (Just 2) 1000 (fromIntegral $ CUDA.clockRate prp * 1000 :: Double) "Hz"
    mem         = showFFloatSIBase (Just 0) 1024 (fromIntegral $ CUDA.totalGlobalMem prp   :: Double) "B"
    at          = char '@'


showFFloatSIBase :: RealFloat a => Maybe Int -> a -> a -> ShowS
showFFloatSIBase p b n
  = showString
  . nubBy (\x y -> x == ' ' && y == ' ')
  $ showFFloat p n' [ ' ', si_unit ]
  where
    n'          = n / (b ^^ (pow-4))
    pow         = max 0 . min 8 . (+) 4 . floor $ logBase b n
    si_unit     = "pnµm kMGT" !! pow


-- Persistent caching (deprecated)
-- -------------------------------

#ifdef ACCELERATE_CUDA_PERSISTENT_CACHE
-- Load and save the persistent kernel index file
--
indexFileName :: IO FilePath
indexFileName = do
  tmp <- (</> "cache") `fmap` getDataDir
  dir <- createDirectoryIfMissing True tmp >> canonicalizePath tmp
  return (dir </> "_index")

saveIndexFile :: CUDAState -> IO ()
saveIndexFile s = do
  ind <- indexFileName
  encodeFile ind . map (second _kernelName) =<< HT.toList (_kernelTable s)

-- Read the kernel index map file (if it exists), loading modules into the
-- current context
--
loadIndexFile :: IO (KernelTable, Int)
loadIndexFile = do
  f <- indexFileName
  x <- doesFileExist f
  e <- if x then mapM reload =<< decodeFile f
            else return []
  (,length e) <$> HT.fromList hashAccKey e
  where
    reload (k,n) = (k,) . KernelEntry n . Right <$> CUDA.loadFile (n `replaceExtension` ".cubin")
#endif

