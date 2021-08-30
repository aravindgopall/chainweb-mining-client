{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

-- |
-- Module: Worker.CPU
-- Copyright: Copyright © 2020 Kadena LLC.
-- License: MIT
-- Maintainer: Lars Kuhtz <lars@kadena.io>
-- Stability: experimental
--
-- TODO
--
module Worker.CPU
( cpuWorker
) where

import Crypto.Hash.IO

import qualified Data.ByteArray as BA
import Data.Bytes.Signed
import qualified Data.ByteString as B
import qualified Data.ByteString.Short as BS
import Data.Int
import Data.IORef
import qualified Data.Memory.Endian as BA
import qualified Data.Text as T
import Data.Time.Clock.System
import Data.Word

import Foreign.Marshal.Alloc (allocaBytes)
import Foreign.Ptr (Ptr, castPtr)
import Foreign.Storable (peekElemOff, pokeByteOff)

import System.LogLevel

-- internal modules

import Logger
import Worker
import qualified Crypto.Hash.SHA256 as SHA256


-- -------------------------------------------------------------------------- --
-- Utils

int :: Integral a => Num b => a -> b
int = fromIntegral

getCurrentTimeMicros :: IO Int64
getCurrentTimeMicros = do
    MkSystemTime secs nanos <- getSystemTime
    return $! secs * 1000000 + (int nanos `div` 1000)

-- | `injectNonce` makes low-level assumptions about the byte layout of a
-- hashed `BlockHeader`. If that layout changes, this functions need to be
-- updated. The assumption allows us to iterate on new nonces quickly.
--
-- Recall: `Nonce` contains a `Word64`, and is thus 8 bytes long.
--
-- See also: https://github.com/kadena-io/chainweb-node/wiki/Block-Header-Binary-Encoding
--
injectNonce :: Nonce -> Ptr Word8 -> IO ()
injectNonce (Nonce n) buf = pokeByteOff buf 278 n
{-# INLINE injectNonce #-}

injectTime :: Int64 -> Ptr Word8 -> IO ()
injectTime t buf = pokeByteOff buf 8 $ encodeTimeToWord64 t
{-# INLINE injectTime #-}

encodeTimeToWord64 :: Int64 -> Word64
encodeTimeToWord64 t = BA.unLE . BA.toLE $ unsigned t
{-# INLINE encodeTimeToWord64 #-}

-- | `PowHashNat` interprets POW hashes as unsigned 256 bit integral numbers in
-- little endian encoding, hence we compare against the target from the end of
-- the bytes first, then move toward the front 8 bytes at a time.
--
fastCheckTarget :: Ptr Word64 -> Ptr Word64 -> IO Bool
fastCheckTarget !trgPtr !powPtr =
    fastCheckTargetN 3 trgPtr powPtr >>= \case
        LT -> return False
        GT -> return True
        EQ -> fastCheckTargetN 2 trgPtr powPtr >>= \case
            LT -> return False
            GT -> return True
            EQ -> fastCheckTargetN 1 trgPtr powPtr >>= \case
                LT -> return False
                GT -> return True
                EQ -> fastCheckTargetN 0 trgPtr powPtr >>= \case
                    LT -> return False
                    GT -> return True
                    EQ -> return True
{-# INLINE fastCheckTarget #-}

-- | Recall that `peekElemOff` acts like `drop` for the size of the type in
-- question. Here, this is `Word64`. Since our hash is treated as a `Word256`,
-- each @n@ knocks off a `Word64`'s worth of bytes, and there would be 4 such
-- sections (64 * 4 = 256).
--
-- This must never be called for @n >= 4@.
--
fastCheckTargetN :: Int -> Ptr Word64 -> Ptr Word64 -> IO Ordering
fastCheckTargetN n trgPtr powPtr = compare
    <$> peekElemOff trgPtr n
    <*> peekElemOff powPtr n
{-# INLINE fastCheckTargetN #-}

-- -------------------------------------------------------------------------- --
-- Worker

-- | Single threaded CPU mining worker for Chainweb.
--
-- TODO: Check the chainweb version to make sure this function can handle the
-- respective version.
--
cpuWorker
  :: forall a
  . HashAlgorithm a
  => Logger
  -> Worker
cpuWorker logger orig@(Nonce o) target work = do
  return (Work $ BS.toShort $ SHA256.hash (B.pack [0..255]))
  where
    tbytes = let (Target b) = target in BS.fromShort b
    hbytes = let (Work b) = work in BS.fromShort b

    bufSize :: Int
    !bufSize = B.length hbytes

    powSize :: Int
    !powSize = hashDigestSize @a undefined

    --  Compute POW hash
    hash :: MutableContext a -> Ptr Word8 -> Ptr Word8 -> IO ()
    hash ctx buf pow = do
        hashMutableReset ctx
        BA.withByteArray ctx $ \ctxPtr -> do
            hashInternalUpdate @a ctxPtr buf $ fromIntegral bufSize
            hashInternalFinalize ctxPtr $ castPtr pow
    {-# INLINE hash #-}

