-- This file is inserted at the top of Generated.hsc by generate-tmr-hsc.pl
{-# LANGUAGE OverloadedStrings, FlexibleInstances, DeriveDataTypeable #-}
module System.Hardware.MercuryApi.Generated where

import Control.Applicative
import Control.Exception
import Data.Hashable
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import Data.Monoid
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import qualified Data.Text.Encoding.Error as T
import Data.Typeable
import Data.Word
import Foreign
import Foreign.C

#include <tm_reader.h>
#include <glue.h>
#include <stdbool.h>

type CBool = #{type bool}
newtype ReaderEtc = ReaderEtc ()

cFalse, cTrue :: CBool
cFalse = 0
cTrue = 1

toBool' :: CBool -> Bool
toBool' = toBool

fromBool' :: Bool -> CBool
fromBool' = fromBool

sizeofReaderEtc :: Int
sizeofReaderEtc = #{size ReaderEtc}

uriPtr :: Ptr ReaderEtc -> CString
uriPtr = #{ptr ReaderEtc, reader.uri}

-- I'm not sure what encoding MercuryApi uses for its strings.
-- I'm guessing UTF-8 for now, but the encoding is encapsulated in
-- these two functions (textFromBS and textToBS) so it can be
-- easily changed.
textFromBS :: ByteString -> Text
textFromBS = T.decodeUtf8With T.lenientDecode

textToBS :: Text -> ByteString
textToBS = T.encodeUtf8

textFromCString :: CString -> IO Text
textFromCString cs = textFromBS <$> B.packCString cs

-- This exception is never seen by the user.  It is caught
-- internally and turned into a MercuryException (with some added fields).
data ParamException = ParamException StatusType Status Text
  deriving (Eq, Ord, Show, Read, Typeable)

instance Exception ParamException

castLen' :: Integral a => a -> Text -> Int -> IO a
castLen' bound description x = do
  let tShow = T.pack . show
      maxLen = fromIntegral bound
  if x > maxLen
    then throwIO ( ParamException ERROR_TYPE_MISC ERROR_TOO_BIG $
                   description <> " had length " <> tShow x <>
                   " but maximum is " <> tShow maxLen )
    else return $ fromIntegral x

castLen :: (Integral a, Bounded a) => Text -> Int -> IO a
castLen = castLen' maxBound

class ParamValue a where
  pType :: a -> ParamType
  pGet :: (Ptr () -> IO ()) -> IO a
  pSet :: a -> (Ptr () -> IO ()) -> IO ()

data ReadPlan =
  SimpleReadPlan
  { rpWeight :: Word32
  , rpEnableAutonomousRead :: Bool
  , rpAntennas :: [Word8]
  , rpProtocol :: TagProtocol
  , rpUseFastSearch :: Bool
  , rpStopOnCount :: Maybe Word32
  , rpTriggerRead :: Maybe [Word8]
  } deriving (Eq, Ord, Show, Read)

antennasInfo :: Ptr ReadPlan -> (Ptr List8, Word8, Ptr Word8, Text)
antennasInfo rp =
  ( #{ptr ReadPlanEtc, plan.u.simple.antennas} rp
  , #{const GLUE_MAX_ANTENNAS}
  , #{ptr ReadPlanEtc, antennas} rp
  , "rpAntennas"
  )

gpiListInfo :: Ptr ReadPlan -> (Ptr List8, Word8, Ptr Word8, Text)
gpiListInfo rp =
  ( #{ptr ReadPlanEtc, plan.u.simple.triggerRead.gpiList} rp
  , #{const GLUE_MAX_GPIPORTS}
  , #{ptr ReadPlanEtc, gpiPorts} rp
  , "rpTriggerRead"
  )

readPlanTypeSimple :: #{type TMR_ReadPlanType}
readPlanTypeSimple = #{const TMR_READ_PLAN_TYPE_SIMPLE}

pokeList8 :: (Ptr List8, Word8, Ptr Word8, Text) -> [Word8] -> IO ()
pokeList8 (lp, maxLen, storage, name) ws = do
  len <- castLen' maxLen name (length ws)
  poke lp $ List8
    { l8_list = castPtr storage
    , l8_max = maxLen
    , l8_len = len
    }
  pokeArray storage ws

instance Storable ReadPlan where
  sizeOf _ = #{size ReadPlanEtc}
  alignment _ = 8

  poke p x = do
    #{poke ReadPlanEtc, plan.type} p readPlanTypeSimple
    #{poke ReadPlanEtc, plan.weight} p (rpWeight x)
    #{poke ReadPlanEtc, plan.enableAutonomousRead} p
      (fromBool' $ rpEnableAutonomousRead x)
    pokeList8 (antennasInfo p) (rpAntennas x)
    #{poke ReadPlanEtc, plan.u.simple.protocol} p
      (fromTagProtocol $ rpProtocol x)
    #{poke ReadPlanEtc, plan.u.simple.useFastSearch} p
      (fromBool' $ rpUseFastSearch x)
    let (stop, nTags) = case rpStopOnCount x of
                          Nothing -> (cFalse, 0)
                          Just n -> (cTrue, n)
    #{poke ReadPlanEtc, plan.u.simple.stopOnCount.stopNTriggerStatus} p stop
    #{poke ReadPlanEtc, plan.u.simple.stopOnCount.noOfTags} p nTags
    let (enable, ports) = case rpTriggerRead x of
                            Nothing -> (cFalse, [])
                            Just ps -> (cTrue, ps)
    #{poke ReadPlanEtc, plan.u.simple.triggerRead.enable} p enable
    pokeList8 (gpiListInfo p) ports

  peek p = undefined
