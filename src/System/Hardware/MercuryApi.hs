{-# LANGUAGE ForeignFunctionInterface, DeriveDataTypeable, OverloadedStrings, BangPatterns #-}
{-|
Module      : System.Hardware.MercuryApi
Description : Control ThingMagic RFID readers
Copyright   : © Patrick Pelletier, 2017
License     : MIT
Maintainer  : code@funwithsoftware.org
Portability : POSIX, Windows

This module is a Haskell binding to the \"Mercury API\" C API for
ThingMagic RFID readers.  It is especially geared toward the
<https://www.sparkfun.com/products/14066 SparkFun Simultaneous RFID Reader>,
which uses ThingMagic's M6e Nano module, but it should work with other
ThingMagic readers.  (Though currently, only support for serial readers
is compiled in.)  Most of the function and type names are the same as
their counterparts in the C API, with the @TMR_@ prefix dropped.  For more
in-depth, language-independent documentation of Mercury API, see
<http://www.thingmagic.com/images/Downloads/Docs/MercuryAPI_ProgrammerGuide_for_v1.27.3.pdf Mercury API Programmers Guide>.

This module is intended to be imported @qualified@, e. g.

> import qualified System.Hardware.MercuryApi as TMR
-}

module System.Hardware.MercuryApi
  ( -- * Reader
    create
  , connect
  , read
  , executeTagOp
  , reboot
  , destroy
  , withReader
    -- ** Parameters
    -- | Although 'paramGet' and 'paramSet' are very flexible, they only
    -- check that the parameter type is correct at runtime.  You may
    -- prefer to use the functions in "System.Hardware.MercuryApi.Params",
    -- which ensure the correct type at compile time.
  , paramList
  , paramGet
  , paramSet
  , paramSetBasics
  , paramSetReadPlanFilter
  , paramSetReadPlanTagop
    -- ** Listeners
    -- | Transport listeners can be used to monitor the raw serial data
    -- going to and from the reader, for debugging purposes.  A listener
    -- that prints the data to a 'Handle' is available from 'hexListener'
    -- or 'opcodeListener'.
  , addTransportListener
  , removeTransportListener
    -- ** GPIO
    -- | The M6e Nano has 4 GPIO pins that can be controlled by software,
    -- numbered 1-4.  On the
    -- <https://www.sparkfun.com/products/14066 SparkFun Simultaneous RFID Reader>,
    -- GPIO 1 is available on the GPIO1 pin, and GPIOs 2, 3, and 4 are available
    -- on the LV2, LV3, and LV4 pins.  The GPIO1 pin is 5V, but
    -- <https://learn.sparkfun.com/tutorials/simultaneous-rfid-tag-reader-hookup-guide/hardware-overview the LV pins are 3.3V only>.
    -- To configure GPIOs as inputs or outputs, use 'PARAM_GPIO_INPUTLIST'
    -- and 'PARAM_GPIO_OUTPUTLIST'.
  , gpiGet
  , gpoSet
    -- ** Firmware
    -- | Firmware for the M6e Nano can be obtained
    -- <http://www.thingmagic.com/index.php/download-nano-firmware here>.
  , firmwareLoad
  , firmwareLoadFile
    -- * Utility functions
    -- ** Listeners
  , hexListener
  , opcodeListener
    -- ** Data helpers
  , packBytesIntoWords
  , passwordToWords
  , mkFilterGen2
    -- ** Parameters
  , paramName
  , paramID
  , paramType
  , paramUnits
    -- ** Hex conversion
  , bytesToHex
  , bytesToHexWithSpaces
  , hexToBytes
    -- ** Display
    -- | Some functions to format data in a more human-friendly
    -- format than 'show'.
  , displayTimestamp
  , displayLocalTimestamp
  , displayData
  , displayGpio
  , displayTagData
  , displayTagReadData
  , displayParamType
  , displayRegion
  , displayRegionDescription
  , parseRegion
    -- * Constants
  , apiVersion
  , sparkFunAntennas
  , defaultReadPlan
  , killPasswordAddress
  , accessPasswordAddress
    -- * Types
    -- ** Opaque types
  , Reader
  , ParamValue
  , TransportListenerId
    -- ** Typedefs
  , TransportListener
  , PinNumber
  , AntennaPort
  , GEN2_Password
  , MillisecondsSinceEpoch
    -- ** Records
  , MercuryException (..)
  , ReadPlan (..)
  , TagOp (..)
  , TagFilter (..)
  , FilterOn (..)
  , TagReadData (..)
  , GpioPin (..)
  , TagData (..)
  , GEN2_TagData (..)
  , ReadWrite (..)
    -- ** Enums
  , StatusType (..)
  , Status (..)
  , Param (..)
  , ParamType (..)
  , Region (..)
  , TagProtocol (..)
  , MetadataFlag (..)
  , GEN2_Bank (..)
  , GEN2_LockBits (..)
  , GEN2_WriteMode (..)
  , PowerMode (..)
  , TransportDirection (..)
  ) where

import Prelude hiding (read)

import Control.Applicative ( (<$>) )
-- IOException is needed here so that Haddock can link to it
import Control.Exception ( Exception, IOException, throwIO, try, bracket )
import Control.Monad ( when )
import qualified Data.ByteString as B
import qualified Data.HashMap.Strict as H
import Data.IORef ( IORef, newIORef, atomicModifyIORef' )
import Data.List ( intercalate )
import Data.Monoid ( (<>) )
import qualified Data.Text as T
import qualified Data.Text.IO as T ( hPutStrLn )
import Data.Typeable ( Typeable )
import Data.Word ( Word8, Word16, Word32 )
import Foreign
    ( Int32,
      Ptr,
      FunPtr,
      ForeignPtr,
      nullPtr,
      withForeignPtr,
      Storable(peek, poke),
      Bits((.&.), (.|.), bit, shiftL, shiftR, testBit),
      castPtr,
      mallocForeignPtrBytes,
      addForeignPtrFinalizer,
      with,
      toBool,
      withArrayLen,
      peekArray,
      allocaArray,
      allocaBytes,
      alloca )
import Foreign.C
    ( CStringLen,
      CString,
      CInt(..),
      CTime(..),
      CSize(..),
      Errno(..),
      withCAString,
      newCAString,
      throwErrnoIfNull,
      errnoToIOError )
import Text.Printf ( printf )
import System.Clock
    ( TimeSpec(nsec, sec), Clock(Monotonic), getTime )
import System.Console.ANSI
    ( SGR(Reset, SetColor),
      ConsoleLayer(Foreground),
      ColorIntensity(Vivid),
      Color(Cyan, Magenta),
      hSupportsANSI,
      hSetSGR )
import System.IO ( Handle, hFlush )
import qualified System.IO.Unsafe as U ( unsafePerformIO )
import Text.Read (readMaybe)

import System.Hardware.MercuryApi.Enums
import System.Hardware.MercuryApi.Records
import System.Hardware.MercuryApi.ParamValue

-- | An opaque type which represents a connection to an RFID reader.
-- Note that @Reader@ is not threadsafe, so if you want to use a
-- @Reader@ from more than one thread, you will need to implement
-- your own locking.
newtype Reader = Reader (ForeignPtr ReaderEtc)

type RawStatus = Word32
type RawType = Word32

type RawTransportListener =
  CBool -> Word32 -> Ptr Word8 -> Word32 -> Ptr () -> IO ()

-- | The direction of data travel.  Passed to 'TransportListener'.
data TransportDirection = Rx -- ^ Receive
                        | Tx -- ^ Transmit
                        deriving (Eq, Ord, Show, Read, Bounded, Enum)

-- | A function which can be installed via 'addTransportListener'
-- to be called every time Mercury API sends or receives data on
-- the serial port.
type TransportListener = TransportDirection -- ^ Direction of data transmission
                       -> B.ByteString  -- ^ Binary data sent or received
                       -> Word32        -- ^ Timeout
                       -> IO ()

-- | An opaque type which can be passed to 'removeTransportListener'
-- to remove a transport listener.
newtype TransportListenerId = TransportListenerId Integer deriving (Eq)

newtype Locale = Locale ()

-- Many of these need to be safe because they could call back
-- into Haskell via the transport listener.  (Or via the custom
-- transport we use for testing.)

foreign import ccall safe "glue.h c_TMR_create"
    c_TMR_create :: Ptr ReaderEtc
                 -> CString
                 -> IO RawStatus

foreign import ccall safe "glue.h c_TMR_connect"
    c_TMR_connect :: Ptr ReaderEtc
                  -> IO RawStatus

foreign import ccall safe "glue.h c_TMR_destroy"
    c_TMR_destroy :: Ptr ReaderEtc
                  -> IO RawStatus

foreign import ccall unsafe "glue.h &c_TMR_destroy"
    p_TMR_destroy :: FunPtr (Ptr ReaderEtc -> IO ())

foreign import ccall safe "glue.h c_TMR_read"
    c_TMR_read :: Ptr ReaderEtc
               -> Word32
               -> Ptr Word32
               -> IO RawStatus

foreign import ccall safe "glue.h c_TMR_hasMoreTags"
    c_TMR_hasMoreTags :: Ptr ReaderEtc
                      -> IO RawStatus

foreign import ccall safe "glue.h c_TMR_getNextTag"
    c_TMR_getNextTag :: Ptr ReaderEtc
                     -> Ptr TagReadData
                     -> IO RawStatus

foreign import ccall unsafe "tmr_tag_data.h TMR_TRD_init"
    c_TMR_TRD_init :: Ptr TagReadData
                   -> IO RawStatus

foreign import ccall safe "glue.h c_TMR_executeTagOp"
    c_TMR_executeTagOp :: Ptr ReaderEtc
                       -> Ptr TagOp
                       -> Ptr TagFilter
                       -> Ptr List16
                       -> IO RawStatus

foreign import ccall safe "glue.h c_TMR_gpoSet"
    c_TMR_gpoSet :: Ptr ReaderEtc
                 -> Word8
                 -> Ptr GpioPin
                 -> IO RawStatus

foreign import ccall safe "glue.h c_TMR_gpiGet"
    c_TMR_gpiGet :: Ptr ReaderEtc
                 -> Ptr Word8
                 -> Ptr GpioPin
                 -> IO RawStatus

foreign import ccall safe "glue.h c_TMR_firmwareLoad"
    c_TMR_firmwareLoad :: Ptr ReaderEtc
                       -> Ptr Word8
                       -> Word32
                       -> IO RawStatus

foreign import ccall safe "glue.h c_TMR_paramSet"
    c_TMR_paramSet :: Ptr ReaderEtc
                   -> RawParam
                   -> Ptr ()
                   -> IO RawStatus

foreign import ccall safe "glue.h c_TMR_paramGet"
    c_TMR_paramGet :: Ptr ReaderEtc
                   -> RawParam
                   -> Ptr ()
                   -> IO RawStatus

foreign import ccall safe "glue.h c_TMR_reboot"
    c_TMR_reboot :: Ptr ReaderEtc
                 -> IO RawStatus

foreign import ccall unsafe "glue.h c_default_read_plan"
    c_default_read_plan :: Ptr ReadPlan
                        -> IO ()

foreign import ccall safe "glue.h c_TMR_paramList"
    c_TMR_paramList :: Ptr ReaderEtc
                    -> Ptr RawParam
                    -> Ptr Word32
                    -> IO RawStatus

foreign import ccall "wrapper"
    wrapTransportListener :: RawTransportListener
                          -> IO (FunPtr RawTransportListener)

-- takes ownership of the FunPtr and the CString
foreign import ccall unsafe "glue.h c_TMR_addTransportListener"
    c_TMR_addTransportListener :: Ptr ReaderEtc
                               -> FunPtr RawTransportListener
                               -> CString
                               -> IO RawStatus

foreign import ccall unsafe "glue.h c_TMR_removeTransportListener"
    c_TMR_removeTransportListener :: Ptr ReaderEtc
                                  -> CString
                                  -> IO RawStatus

foreign import ccall unsafe "glue.h c_TMR_strerr"
    c_TMR_strerr :: Ptr ReaderEtc
                 -> RawStatus
                 -> IO CString

-- This is a pure function, because it returns a string literal
foreign import ccall unsafe "tm_reader.h TMR_paramName"
    c_TMR_paramName :: RawParam
                    -> CString

foreign import ccall unsafe "tmr_tag_data.h TMR_hexToBytes"
    c_TMR_hexToBytes :: CString
                     -> Ptr Word8
                     -> Word32
                     -> Ptr Word32
                     -> IO RawStatus

foreign import ccall unsafe "tmr_tag_data.h TMR_bytesToHex"
    c_TMR_bytesToHex :: Ptr Word8
                     -> Word32
                     -> CString
                     -> IO ()

foreign import ccall unsafe "glue.h c_new_c_locale"
    c_new_c_locale :: IO (Ptr Locale)

foreign import ccall unsafe "glue.h c_format_time"
    c_format_time :: CString
                  -> CSize
                  -> CString
                  -> CTime
                  -> CBool
                  -> Ptr Locale
                  -> IO CInt

-- | Represents any error that can occur in a MercuryApi call,
-- except for those which can be represented by 'IOException'.
data MercuryException =
  MercuryException
  { meStatusType :: StatusType -- ^ general category of error
  , meStatus     :: Status     -- ^ the specific error
  , meMessage    :: T.Text     -- ^ the error message
  , meLocation   :: T.Text     -- ^ function where the error occurred
  , meParam      :: T.Text     -- ^ more information, such as the parameter
                               -- in 'paramGet' or 'paramSet'
  , meUri        :: T.Text     -- ^ URI of the reader
  }
  deriving (Eq, Ord, Show, Read, Typeable)

instance Exception MercuryException

statusGetType :: RawStatus -> RawType
statusGetType stat = stat `shiftR` 24

errnoBit :: Int
errnoBit = 15

statusIsErrno :: StatusType -> RawStatus -> Bool
statusIsErrno ERROR_TYPE_COMM rstat = rstat `testBit` errnoBit
statusIsErrno _ _ = False

statusGetErrno :: RawStatus -> Errno
statusGetErrno rstat = Errno $ fromIntegral $ rstat .&. (bit errnoBit - 1)

checkStatus' :: Ptr ReaderEtc
             -> RawStatus
             -> T.Text
             -> T.Text
             -> IO T.Text
             -> IO ()
checkStatus' rdr rstat loc param getUri = do
  let t = toStatusType $ statusGetType rstat
      stat = toStatus rstat
  case t of
    SUCCESS_TYPE -> return ()
    _ -> do
      uri <- getUri
      if statusIsErrno t rstat
        then do
        let errno = statusGetErrno rstat
            ioe = errnoToIOError (T.unpack loc) errno Nothing
                  (Just $ T.unpack uri)
        throwIO ioe
        else do
        cstr <- c_TMR_strerr rdr rstat
        msg <- textFromCString cstr
        let exc = MercuryException
                  { meStatusType = t
                  , meStatus = stat
                  , meMessage = msg
                  , meLocation = loc
                  , meParam = param
                  , meUri = uri
                  }
        throwIO exc

checkStatus :: Ptr ReaderEtc -> RawStatus -> T.Text -> T.Text -> IO ()
checkStatus rdr rstat loc param =
  checkStatus' rdr rstat loc param (textFromCString $ uriPtr rdr)

uniqueCounter :: IORef Integer
{-# NOINLINE uniqueCounter #-}
uniqueCounter = U.unsafePerformIO $ newIORef 0

newUnique :: IO Integer
newUnique = atomicModifyIORef' uniqueCounter f
  where f x = (x + 1, x)

castToCStringLen :: Integral a => a -> Ptr Word8 -> CStringLen
castToCStringLen len ptr = (castPtr ptr, fromIntegral len)

paramPairs :: [(Param, T.Text)]
paramPairs = map f [minBound..maxBound]
  where
    f p = (p, U.unsafePerformIO $ textFromCString $ c_TMR_paramName $ fromParam p)

paramMap :: H.HashMap Param T.Text
paramMap = H.fromList paramPairs

paramMapReverse :: H.HashMap T.Text Param
paramMapReverse = H.fromList $ map swap paramPairs
  where swap (x, y) = (y, x)

-- | Return the string name (e. g. \"\/reader\/read\/plan\")
-- corresponding to a 'Param'.
paramName :: Param -> T.Text
paramName p = paramMap H.! p -- all possible keys are in the map, so can't fail

-- | Return the 'Param' corresponding to a string name
-- (e. g. \"\/reader\/read\/plan\").  Returns 'PARAM_NONE' if no such
-- parameter exists.
paramID :: T.Text -> Param
paramID name = H.lookupDefault PARAM_NONE name paramMapReverse

-- | Create a new 'Reader' with the specified URI.  The reader is
-- not contacted at this point.  On Mac OS X, be sure to use the
-- serial device that starts with @cu.@, not the one that starts with
-- @tty.@.
create :: T.Text -- ^ a reader URI, such as @tmr:\/\/\/dev\/ttyUSB0@ on Linux,
                 -- @tmr:\/\/\/dev\/cu.SLAB_USBtoUART@ on Mac OS X, or
                 -- @tmr:\/\/\/COM4@ on Windows.
       -> IO Reader
create deviceUri = do
  B.useAsCStringLen (textToBS deviceUri) $ \(cs, len) -> do
    fp <- mallocForeignPtrBytes (sizeofReaderEtc + len)
    withForeignPtr fp $ \p -> do
      status <- c_TMR_create p cs
      checkStatus' p status "create" "" (return deviceUri)
    addForeignPtrFinalizer p_TMR_destroy fp
    return $ Reader fp

withReaderEtc :: Reader
              -> T.Text
              -> T.Text
              -> (Ptr ReaderEtc -> IO RawStatus)
              -> IO ()
withReaderEtc (Reader fp) location param func = do
  withForeignPtr fp $ \p -> do
    status <- func p
    checkStatus p status location param

-- | Establishes the connection to the reader at the URI specified in
-- the 'create' call.  The existence of a reader at the address is
-- verified and the reader is brought into a state appropriate for
-- performing RF operations.
connect :: Reader -> IO ()
connect rdr = withReaderEtc rdr "connect" "" c_TMR_connect

-- | Closes the connection to the reader and releases any resources
-- that have been consumed by the reader structure.  Any further
-- operations performed on the reader will fail with
-- 'ERROR_ALREADY_DESTROYED'.  On finalization of the 'Reader',
-- 'destroy' will be called automatically if it has not already been called.
destroy :: Reader -> IO ()
destroy rdr = withReaderEtc rdr "destroy" "" c_TMR_destroy

-- | Create a new 'Reader' with the specified URI, pass it to the given
-- computation, and destroy it when the computation exits.
withReader :: T.Text -- ^ a reader URI, such as @tmr:\/\/\/dev\/ttyUSB0@ on
                     -- Linux, @tmr:\/\/\/dev\/cu.SLAB_USBtoUART@ on Mac OS X,
                     -- or @tmr:\/\/\/COM4@ on Windows.
           -> (Reader -> IO a) -- ^ computation to run with Reader
           -> IO a
withReader uri = bracket (create uri) destroy

hasMoreTags :: Ptr CBool -> Ptr ReaderEtc -> IO RawStatus
hasMoreTags boolPtr rdrPtr = do
  status <- c_TMR_hasMoreTags rdrPtr
  let (moreTags, status') = case toStatus status of
                              ERROR_NO_TAGS -> (cFalse, 0)
                              _ -> (cTrue, status)
  poke boolPtr moreTags
  return status'

tShow :: Show a => a -> T.Text
tShow = T.pack . show

readLoop :: Reader
         -> Word32
         -> Ptr TagReadData
         -> Ptr CBool
         -> Int
         -> [TagReadData]
         -> IO [TagReadData]
readLoop rdr tagCount trdPtr boolPtr !tagNum !trds = do
  let tagNum' = tagNum + 1
      progress = "(" <> tShow tagNum' <> " of " <> tShow tagCount <> ")"
  withReaderEtc rdr "read"
    ("hasMoreTags " <> progress)
    (hasMoreTags boolPtr)
  moreTags <- toBool' <$> peek boolPtr
  if moreTags
    then do
    c_TMR_TRD_init trdPtr -- ignore return value because it is always success
    withReaderEtc rdr "read" ("getNextTag " <> progress)
      $ \p -> c_TMR_getNextTag p trdPtr
    trd <- peek trdPtr
    readLoop rdr tagCount trdPtr boolPtr tagNum' (trd : trds)
    else do
    return $ reverse trds

-- | Search for tags for a fixed duration.  Follows the 'ReadPlan'
-- stored in 'PARAM_READ_PLAN'.
read :: Reader -- ^ The reader being operated on
     -> Word32 -- ^ The number of milliseconds to search for tags
     -> IO [TagReadData]
read rdr timeoutMs = do
  alloca $ \tagCountPtr -> do
    withReaderEtc rdr "read" "" $ \p -> c_TMR_read p timeoutMs tagCountPtr
    tagCount <- peek tagCountPtr
    alloca $ \trdPtr -> alloca $
                        \boolPtr -> readLoop rdr tagCount trdPtr boolPtr 0 []

-- | Directly executes a 'TagOp' command.
-- Operates on the first tag found, with applicable tag filtering.
-- The call returns immediately after finding one tag
-- and operating on it, unless the command timeout expires first.
-- The operation is performed on the antenna specified in the
-- 'PARAM_TAGOP_ANTENNA' parameter.
-- 'PARAM_TAGOP_PROTOCOL' specifies the protocol to be used.
-- Some TagOps return data, while others will just return an
-- empty 'B.ByteString'.
executeTagOp :: Reader -> TagOp -> Maybe TagFilter -> IO B.ByteString
executeTagOp rdr tagOp tagFilter = alloca $ \pOp -> alloca $ \pFilt -> do
  eth1 <- try $ poke pOp tagOp
  case eth1 of
    Left err -> throwPE rdr err "executeTagOp" "tagop"
    Right _ -> return ()
  pFilt' <- case tagFilter of
              Nothing -> return nullPtr
              Just tf -> do
                eth2 <- try $ poke pFilt tf
                case eth2 of
                  Left err -> throwPE rdr err "executeTagOp" "filter"
                  Right _ -> return pFilt
  results <- getList16 $ \pList -> do
    withReaderEtc rdr "executeTagOp" (tagOpName tagOp) $ \pRdr -> do
      c_TMR_executeTagOp pRdr pOp pFilt' (castPtr pList)
  return $ B.pack results

-- | Set the state of some GPO pins.
gpoSet :: Reader -> [GpioPin] -> IO ()
gpoSet rdr gpios = do
  withArrayLen gpios $ \len gpioPtr -> do
    eth <- try $ castLen "[GpioPin]" len
    case eth of
      Left err -> throwPE rdr err "gpoSet" ""
      Right len' -> do
        withReaderEtc rdr "gpoSet" "" $ \pRdr -> do
          c_TMR_gpoSet pRdr len' gpioPtr

-- | Get the state of all GPI pins.
gpiGet :: Reader -> IO [GpioPin]
gpiGet rdr = do
  let maxLen = maxBound
  with maxLen $ \lenPtr -> do
    allocaArray (fromIntegral maxLen) $ \gpioPtr -> do
      withReaderEtc rdr "gpiGet" "" $ \pRdr -> do
        c_TMR_gpiGet pRdr lenPtr gpioPtr
      len <- peek lenPtr
      peekArray (fromIntegral len) gpioPtr

-- | Attempts to install firmware on the reader, then restart and reinitialize.
firmwareLoad :: Reader       -- ^ The reader being operated on
             -> B.ByteString -- ^ The binary firmware image to install
             -> IO ()
firmwareLoad = firmwareLoad' ""

firmwareLoad' :: T.Text -> Reader -> B.ByteString -> IO ()
firmwareLoad' filename rdr firmware = do
  B.useAsCStringLen firmware $ \(fwPtr, fwLen) -> do
    withReaderEtc rdr "firmwareLoad" filename $
      \p -> c_TMR_firmwareLoad p (castPtr fwPtr) (fromIntegral fwLen)

-- | Like 'firmwareLoad', but loads firmware from a file.
-- (e. g. @NanoFW-1.7.1.2.sim@)
firmwareLoadFile :: Reader   -- ^ The reader being operated on
                 -> FilePath -- ^ Name of file containing firmware image
                 -> IO ()
firmwareLoadFile rdr filename = do
  firmware <- B.readFile filename
  firmwareLoad' (T.pack filename) rdr firmware

throwPE :: Reader -> ParamException -> T.Text -> T.Text -> IO a
throwPE (Reader fp) (ParamException statusType status msg) loc param = do
  uri <- withForeignPtr fp (textFromCString . uriPtr)
  throwIO $ MercuryException
    { meStatusType = statusType
    , meStatus = status
    , meMessage = msg
    , meLocation = loc
    , meParam = param
    , meUri = uri
    }

unimplementedParam :: ParamException
unimplementedParam =
  ParamException ERROR_TYPE_BINDING ERROR_UNIMPLEMENTED_PARAM
  "The given parameter is not yet implemented in the Haskell binding."

invalidParam :: ParamType -> ParamType -> ParamException
invalidParam expected actual =
  ParamException ERROR_TYPE_BINDING ERROR_INVALID_PARAM_TYPE
  ( "Expected " <> displayParamType expected <>
    " but got " <> displayParamType actual )

-- | Sets the value of a reader parameter.  Throws 'MercuryException'
-- with a 'meStatus' of 'ERROR_INVALID_PARAM_TYPE' if the parameter value
-- is not of the correct type (sadly, this is only checked at runtime) or
-- 'ERROR_UNIMPLEMENTED_PARAM' if the parameter has not yet been implemented
-- in the Haskell binding.  Can also propagate errors from the C API, such
-- as 'ERROR_UNSUPPORTED' or 'ERROR_READONLY'.
paramSet :: ParamValue a => Reader -> Param -> a -> IO ()
paramSet rdr param value = do
  let pt = paramType param
      pt' = pType value
      rp = fromParam param
      pName = T.pack $ show param
  when (pt == ParamTypeUnimplemented) $
    throwPE rdr unimplementedParam "paramSet" pName
  when (pt /= pt') $
    throwPE rdr (invalidParam pt pt') "paramSet" pName
  eth <- try $ pSet value $ \pp -> withReaderEtc rdr "paramSet" pName $
                                   \p -> c_TMR_paramSet p rp pp
  case eth of
    Left err -> throwPE rdr err "paramSet" pName
    Right _ -> return ()

withReturnType :: (a -> IO a) -> IO a
withReturnType f = f undefined

-- | Gets the value of a reader parameter.  Throws 'MercuryException'
-- with a 'meStatus' of 'ERROR_INVALID_PARAM_TYPE' if the parameter value
-- is not of the correct type (sadly, this is only checked at runtime) or
-- 'ERROR_UNIMPLEMENTED_PARAM' if the parameter has not yet been implemented
-- in the Haskell binding.  Can also propagate errors from the C API, such
-- as 'ERROR_UNSUPPORTED'.
paramGet :: ParamValue a => Reader -> Param -> IO a
paramGet rdr param = withReturnType $ \returnType -> do
  let pt = paramType param
      pt' = pType returnType
      rp = fromParam param
      pName = T.pack $ show param
  when (pt == ParamTypeUnimplemented) $
    throwPE rdr unimplementedParam "paramGet" pName
  when (pt /= pt') $
    throwPE rdr (invalidParam pt pt') "paramGet" pName
  pGet $ \pp -> withReaderEtc rdr "paramGet" pName $
                \p -> c_TMR_paramGet p rp pp

-- | Convenience function to set some of the most essential parameters.
-- The specified 'Region' is written into 'PARAM_REGION_ID'.
-- The specified power level is written into 'PARAM_RADIO_READPOWER'
-- and 'PARAM_RADIO_WRITEPOWER'.  The specified antenna list is
-- written into the 'rpAntennas' field of 'PARAM_READ_PLAN', and the first
-- antenna in the list is written into 'PARAM_TAGOP_ANTENNA'.  For the
-- <https://www.sparkfun.com/products/14066 SparkFun Simultaneous RFID Reader>,
-- the antenna list should be 'sparkFunAntennas', and if powering the reader
-- off USB, the power level should be 500
-- (<https://learn.sparkfun.com/tutorials/simultaneous-rfid-tag-reader-hookup-guide/power-supply-considerations 5 dBm>).
-- (Higher power levels can be used with a separate power supply.)
paramSetBasics :: Reader   -- ^ The reader being operated on
               -> Region   -- ^ The region
               -> Int32    -- ^ Power in centi-dBm
               -> [AntennaPort] -- ^ Antenna list
               -> IO ()
paramSetBasics rdr rgn pwr ant = do
  paramSet rdr PARAM_REGION_ID rgn
  paramSet rdr PARAM_RADIO_READPOWER pwr
  paramSet rdr PARAM_RADIO_WRITEPOWER pwr
  plan <- paramGet rdr PARAM_READ_PLAN
  paramSet rdr PARAM_READ_PLAN plan { rpAntennas = ant }
  when (not $ null ant) $ paramSet rdr PARAM_TAGOP_ANTENNA (head ant)

-- | Sets the 'rpFilter' field of the 'PARAM_READ_PLAN' parameter,
-- while leaving the rest of the read plan unchanged.
paramSetReadPlanFilter :: Reader -> Maybe TagFilter -> IO ()
paramSetReadPlanFilter rdr filt = do
  plan <- paramGet rdr PARAM_READ_PLAN
  paramSet rdr PARAM_READ_PLAN plan { rpFilter = filt }

-- | Sets the 'rpTagop' field of the 'PARAM_READ_PLAN' parameter,
-- while leaving the rest of the read plan unchanged.
paramSetReadPlanTagop :: Reader -> Maybe TagOp -> IO ()
paramSetReadPlanTagop rdr op = do
  plan <- paramGet rdr PARAM_READ_PLAN
  paramSet rdr PARAM_READ_PLAN plan { rpTagop = op }

-- | The read plan that the reader starts out with by default.
-- This has reasonable settings for most things, except for the
-- antennas, which need to be set.  (e. g. set 'rpAntennas' to
-- 'sparkFunAntennas')
defaultReadPlan :: ReadPlan
defaultReadPlan = U.unsafePerformIO $ do
  alloca $ \p -> do
    c_default_read_plan p
    peek p

-- | The constant @[1]@, which is the correct value for 'rpAntennas'
-- when using the
-- <http://sparkfun.com/products/14066 SparkFun Simultaneous RFID Reader>.
sparkFunAntennas :: [AntennaPort]
sparkFunAntennas = [1]

-- | Reboot the reader
reboot :: Reader -> IO ()
reboot rdr = withReaderEtc rdr "reboot" "" c_TMR_reboot

-- | Get a list of parameters supported by the reader.
paramList :: Reader -> IO [Param]
paramList rdr = do
  let maxParams = paramMax + 1
  alloca $ \nParams -> do
    poke nParams (fromIntegral maxParams)
    allocaArray (fromIntegral maxParams) $ \params -> do
      withReaderEtc rdr "paramList" "" $ \p -> c_TMR_paramList p params nParams
      actual <- peek nParams
      result <- peekArray (min (fromIntegral actual) (fromIntegral maxParams)) params
      return $ map toParam result

txToDirection :: Bool -> TransportDirection
txToDirection True = Tx
txToDirection False = Rx

callTransportListener :: TransportListener -> RawTransportListener
callTransportListener listener tx dataLen dataPtr timeout _ = do
  bs <- B.packCStringLen (castToCStringLen dataLen dataPtr)
  listener (txToDirection $ toBool tx) bs timeout

-- | Add a listener to the list of functions that will be called for
-- each message sent to or recieved from the reader.
addTransportListener :: Reader                 -- ^ The reader to operate on.
                     -> TransportListener      -- ^ The listener to call.
                     -> IO TransportListenerId -- ^ A unique identifier which
                                               -- can be used to remove the
                                               -- listener later.
addTransportListener rdr listener = do
  unique <- newUnique
  funPtr <- wrapTransportListener (callTransportListener listener)
  cs <- newCAString (show unique)
  withReaderEtc rdr "addTransportListener" "" $
    \p -> c_TMR_addTransportListener p funPtr cs
  return (TransportListenerId unique)

-- | Remove a listener from the list of functions that will be called
-- for each message sent to or recieved from the reader.
removeTransportListener :: Reader              -- ^ The reader to operate on.
                        -> TransportListenerId -- ^ The return value of a call
                                               -- to 'addTransportListener'.
                        -> IO ()
removeTransportListener rdr (TransportListenerId unique) = do
  withCAString (show unique) $ \cs -> do
    withReaderEtc rdr "removeTransportListener" "" $
      \p -> c_TMR_removeTransportListener p cs

-- | Given a 'Handle', returns a 'TransportListener' which prints
-- transport data to that handle in hex.  If the handle is a terminal,
-- prints transmitted data in magenta and received data in cyan.
hexListener :: Handle -> IO TransportListener
hexListener h = do
  useColor <- hSupportsANSI h
  return (listenerImpl h useColor False)

-- | Identical to 'hexListener', but also prints the opcode of each packet,
-- and a timestamp.  (The timestamp is relative to an arbitrary point in
-- time, so is only useful for computing differences between timestamps.)
opcodeListener :: Handle -> IO TransportListener
opcodeListener h = do
  useColor <- hSupportsANSI h
  return (listenerImpl h useColor True)

listenerImpl :: Handle -> Bool -> Bool -> TransportListener
listenerImpl h useColor printOpcode dir dat _ = do
  setColors useColor [SetColor Foreground Vivid (color dir)]
  opc <- if printOpcode
         then opcodeAndTime dat
         else return []
  mapM_ (T.hPutStrLn h) $ lstn opc (prefix dir)
  setColors useColor [Reset]
  flushColor useColor
  where
    setColors False _ = return ()
    setColors True sgr = hSetSGR h sgr
    flushColor False = return ()
    flushColor True = hFlush h
    prefix Tx = "Sending: "
    prefix Rx = "Received:"
    color Tx = Magenta
    color Rx = Cyan
    lstn opc pfx =
      zipWith T.append (pfx : repeat "         ") (opc ++ displayData dat)

extractOpcode :: B.ByteString -> T.Text
extractOpcode bs
  | B.length bs < 3 = "too short"
  | otherwise = opcodeName (bs `B.index` 2)

opcodeAndTime :: B.ByteString -> IO [T.Text]
opcodeAndTime bs = do
  now <- getTime Monotonic
  let opcode = extractOpcode bs
      tm = printf "%d.%09d" (sec now) (nsec now)
  return [pad 30 opcode <> T.pack tm]

-- | Convert a hexadecimal string (without spaces) into a
-- 'B.ByteString'.  The hex string may optionally include a "0x"
-- prefix, which will be ignored.  If the input cannot be parsed as a
-- hex string, returns 'Nothing'.
hexToBytes :: T.Text -> Maybe B.ByteString
hexToBytes hex = U.unsafePerformIO $ do
  let hexBs = textToBS hex
      hexLen = B.length hexBs
      bufLen = 1 + (hexLen `div` 2)
  alloca $ \pLen -> allocaBytes bufLen $ \buf -> B.useAsCString hexBs $ \cs -> do
    status <- c_TMR_hexToBytes cs buf (fromIntegral bufLen) pLen
    outLen <- peek pLen
    if (status == 0)
      then Just <$> B.packCStringLen (castPtr buf, fromIntegral outLen)
      else return Nothing

-- | Convert a 'B.ByteString', such as a tag EPC, into a hexadecimal string.
bytesToHex :: B.ByteString -> T.Text
bytesToHex bytes = U.unsafePerformIO $ do
  let bytesLen = B.length bytes
      bufLen = 1 + bytesLen * 2
  allocaBytes bufLen $ \buf -> B.useAsCString bytes $ \cs -> do
    c_TMR_bytesToHex (castPtr cs) (fromIntegral bytesLen) buf
    textFromBS <$> B.packCString buf

-- | Like 'bytesToHex', but with a space between each byte.
bytesToHexWithSpaces :: B.ByteString -> T.Text
bytesToHexWithSpaces = T.pack . intercalate " " . map (printf "%02x") . B.unpack

pad :: Int -> T.Text -> T.Text
pad x t = t <> T.replicate (x - T.length t) " "

-- | Format a 'B.ByteString' as 16 bytes per line, with both hex and ascii
-- on the line.
displayData :: B.ByteString -> [T.Text]
displayData bytes
  | B.null bytes = []
  | otherwise =
    let (bs1, bs2) = B.splitAt 16 bytes
        (bs1a, bs1b) = B.splitAt 8 bs1
        dotify x = if x < 0x20 || x >= 0x7f then 0x2e else x
        hex = map (pad 25 . bytesToHexWithSpaces) [bs1a, bs1b]
        ascii = B.map dotify bs1
        txt = T.concat $ hex ++ ["|", textFromBS ascii, "|"]
    in txt : displayData bs2

displayByteString :: B.ByteString -> T.Text
displayByteString bs =
  "<" <> bytesToHex bs <> "> (" <> T.pack (show $ B.length bs) <> " bytes)"

-- | Convert a 'TagData' to a human-readable list of lines.
displayTagData :: TagData -> [T.Text]
displayTagData td =
  concat
  [ [ "TagData"
    , "  epc         = " <> displayByteString (tdEpc td)
    , "  protocol    = " <> tShow (tdProtocol td)
    , "  crc         = " <> T.pack (printf "0x%04x" $ tdCrc td)
    ]
  , case tdGen2 td of
      Nothing -> []
      Just gen2 -> ["  gen2.pc     = " <> displayByteString (g2Pc gen2)]
  ]

indent :: [T.Text] -> [T.Text]
indent = map ("  " <>)

cLocale :: Ptr Locale
{-# NOINLINE cLocale #-}
cLocale = U.unsafePerformIO $ throwErrnoIfNull "newlocale" c_new_c_locale

formatTimestamp :: MillisecondsSinceEpoch -> CBool -> String -> IO T.Text
formatTimestamp t local z = do
  let (seconds, millis) = t `divMod` 1000
      fmt = "%Y-%m-%dT%H:%M:%S" ++ printf ".%03d" millis ++ z
      bufSize = 80
  withCAString fmt $ \cFmt -> allocaBytes bufSize $ \buf -> do
    ret <- c_format_time buf (fromIntegral bufSize) cFmt
           (CTime $ fromIntegral seconds) local cLocale
    if ret < 0
      then return $ T.pack $ printf "%d.%03d" seconds millis
      else textFromCString buf

-- | Convert a timestamp into
-- <https://en.wikipedia.org/wiki/ISO_8601 ISO 8601> format in UTC.
displayTimestamp :: MillisecondsSinceEpoch -- ^ milliseconds since 1\/1\/1970 UTC
                 -> T.Text
displayTimestamp t = U.unsafePerformIO $ formatTimestamp t cFalse "Z"

-- | Convert a timestamp into <https://en.wikipedia.org/wiki/ISO_8601 ISO 8601>
-- format in the local timezone.
displayLocalTimestamp :: MillisecondsSinceEpoch -- ^ milliseconds since 1\/1\/1970 UTC
                      -> IO T.Text
displayLocalTimestamp t = formatTimestamp t cTrue "%z"

-- | Convert a list of 'GpioPin' to a human-readable list of lines.
displayGpio :: [GpioPin] -> [T.Text]
displayGpio gpios = "Gpio" : map dispGpio gpios
  where
    dispGpio gpio = "  pin " <> tShow (gpId gpio) <>
                    (if (gpHigh gpio) then " high" else " low ") <>
                    (if (gpOutput gpio) then " output" else "  input")

-- | Convert a 'TagReadData' to a human-readable list of lines.
displayTagReadData :: TagReadData -> [T.Text]
displayTagReadData trd =
  concat
  [ [ "TagReadData" ]
  , indent (displayTagData $ trTag trd)
  , [ "  metadataFlags = " <> T.intercalate "|" (map fl $ trMetadataFlags trd)
    , "  phase         = " <> tShow (trPhase trd)
    , "  antenna       = " <> tShow (trAntenna trd)
    ]
  , indent (displayGpio $ trGpio trd)
  , [ "  readCount     = " <> tShow (trReadCount trd)
    , "  rssi          = " <> tShow (trRssi trd)
    , "  frequency     = " <> tShow (trFrequency trd)
    , "  timestamp     = " <> displayTimestamp (trTimestamp trd)
    ]
  , dat "data" (trData trd)
  , dat "epcMemData" (trEpcMemData trd)
  , dat "tidMemData" (trTidMemData trd)
  , dat "userMemData" (trUserMemData trd)
  , dat "reservedMemData" (trReservedMemData trd)
  ]
  where
    nDrop = T.length "METADATA_FLAG_"
    fl = T.drop nDrop . tShow
    dat name bs =
      if B.null bs
      then []
      else indent ((name <> ": " <> T.pack (show $ B.length bs) <> " bytes")
                   : indent (displayData bs))

regionPrefix :: T.Text
regionPrefix = "REGION_"

-- | Like 'show' for 'Region', but in lower case and without the
-- @REGION_@ prefix.
displayRegion :: Region -> T.Text
displayRegion = T.toLower . T.pack . drop (T.length regionPrefix) . show

-- | Like 'readMaybe' for 'Region', but case-insenstive and without the
-- @REGION_@ prefix.
parseRegion :: T.Text -> Maybe Region
parseRegion = readMaybe . T.unpack . T.toUpper . T.append regionPrefix

-- | Convert a 'B.ByteString' into a list of 'Word16', in big-endian
-- order.  Padded with 0 if the number of bytes is odd.
packBytesIntoWords :: B.ByteString -> [Word16]
packBytesIntoWords bs = pbw (B.unpack bs)
  where pbw [] = []
        pbw [x] = [pk x 0]
        pbw (x1:x2:xs) = pk x1 x2 : pbw xs
        pk x1 x2 = (fromIntegral x1 `shiftL` 8) .|. fromIntegral x2

-- | Split a password into two 16-bit words, suitable for writing
-- into reserved memory.
passwordToWords :: GEN2_Password -> [Word16]
passwordToWords pwd = map fromIntegral [pwd `shiftR` 16, pwd .&. 0xffff]

-- | Create a 'TagFilterGen2' with the most common settings
mkFilterGen2 :: GEN2_Bank    -- ^ The bank to filter on
             -> Word32       -- ^ The location (in bits) at which to begin
                             -- comparing the mask
             -> B.ByteString -- ^ The mask value to compare with the specified
                             -- region of tag memory
             -> TagFilter
mkFilterGen2 bank bitPointer mask =
  TagFilterGen2
  { tfInvert = False
  , tfFilterOn = FilterOnBank bank
  , tfBitPointer = bitPointer
  , tfMaskBitLength = fromIntegral $ 8 * B.length mask
  , tfMask = mask
  }

-- | Word address of kill password in reserved memory.
killPasswordAddress :: Word32
killPasswordAddress = 0

-- | Word address of access password in reserved memory.
accessPasswordAddress :: Word32
accessPasswordAddress = 2
