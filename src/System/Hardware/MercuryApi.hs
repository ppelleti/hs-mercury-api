{-# LANGUAGE ForeignFunctionInterface, DeriveDataTypeable, OverloadedStrings, BangPatterns #-}

module System.Hardware.MercuryApi
  ( Reader
  , Param (..)
  , ParamType (..)
  , ParamValue
  , MercuryException (..)
  , StatusType (..)
  , Status (..)
  , TransportListener
  , TransportListenerId
  , Region (..)
  , TagProtocol (..)
  , ReadPlan (..)
  , MetadataFlag (..)
  , TagReadData (..)
  , GpioPin (..)
  , TagData (..)
  , GEN2_TagData (..)
  , GEN2_Bank (..)
  , TagOp (..)
  , apiVersion
  , create
  , connect
  , destroy
  , read
  , executeTagOp
  , firmwareLoad
  , firmwareLoadFile
  , paramSet
  , paramGet
  , defaultReadPlan
  , antennaReadPlan
  , paramList
  , paramName
  , paramID
  , paramType
  , addTransportListener
  , removeTransportListener
  , hexListener
  , bytesToHex
  , hexToBytes
  , displayTimestamp
  , displayLocalTimestamp
  , displayTagData
  , displayTagReadData
  ) where

import Prelude hiding (read)

import Control.Applicative
import Control.Concurrent
import Control.Exception
import Control.Monad
import qualified Data.ByteString as B
import qualified Data.HashMap.Strict as H
import Data.IORef
import Data.Monoid
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import qualified Data.Text.Encoding.Error as T
import Data.Typeable
import Data.Word
import Foreign
import Foreign.C
import Text.Printf
import System.Console.ANSI
import System.IO
import qualified System.IO.Unsafe as U

import System.Hardware.MercuryApi.Generated

newtype Reader = Reader (ForeignPtr ReaderEtc)

type RawStatus = Word32
type RawType = Word32

type RawTransportListener =
  CBool -> Word32 -> Ptr Word8 -> Word32 -> Ptr () -> IO ()

type TransportListener = Bool -> B.ByteString -> Word32 -> IO ()

newtype TransportListenerId = TransportListenerId Integer

newtype Locale = Locale ()

-- Many of these need to be safe because they could call back
-- into Haskell via the transport listener.

foreign import ccall unsafe "glue.h c_TMR_create"
    c_TMR_create :: Ptr ReaderEtc
                 -> CString
                 -> IO RawStatus

foreign import ccall safe "glue.h c_TMR_connect"
    c_TMR_connect :: Ptr ReaderEtc
                  -> IO RawStatus

foreign import ccall unsafe "glue.h c_TMR_destroy"
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
-- not contacted at this point.
create :: T.Text -- ^ a reader URI, such as @tmr:\/\/\/dev\/ttyUSB0@
       -> IO Reader
create deviceUri = do
  B.useAsCString (textToBS deviceUri) $ \cs -> do
    fp <- mallocForeignPtrBytes sizeofReaderEtc
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
-- that have been consumed by the reader structure.
destroy :: Reader -> IO ()
destroy rdr = withReaderEtc rdr "destroy" "" c_TMR_destroy

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

-- | Search for tags for a fixed duration.
read :: Reader -- ^ The reader being operated on
     -> Word32 -- ^ The number of milliseconds to search for tags
     -> IO [TagReadData]
read rdr timeoutMs = do
  alloca $ \tagCountPtr -> do
    withReaderEtc rdr "read" "read" $ \p -> c_TMR_read p timeoutMs tagCountPtr
    tagCount <- peek tagCountPtr
    alloca $ \trdPtr -> alloca $
                        \boolPtr -> readLoop rdr tagCount trdPtr boolPtr 0 []

-- | Directly executes a 'TagOp' command.
-- Operates on the first tag found, with applicable tag filtering.
-- The call returns immediately after finding one tag
-- and operating on it, unless the command timeout expires first.
-- The operation is performed on the antenna specified in the
-- @\/reader\/tagop\/antenna@ parameter.
-- @\/reader\/tagop\/protocol@ specifies the protocol to be used.
executeTagOp :: Reader -> TagOp -> TagFilter -> IO B.ByteString
executeTagOp rdr tagOp tagFilter = alloca $ \pOp -> alloca $ \pFilt -> do
  eth1 <- try $ poke pOp tagOp
  case eth1 of
    Left err -> throwPE rdr err "executeTagOp" "tagop"
    Right _ -> return ()
  eth2 <- try $ poke pFilt tagFilter
  case eth2 of
    Left err -> throwPE rdr err "executeTagOp" "filter"
    Right _ -> return ()
  results <- getList16 $ \pList -> do
    withReaderEtc rdr "executeTagOp" "" $ \pRdr -> do
      c_TMR_executeTagOp pRdr pOp pFilt (castPtr pList)
  return $ B.pack results

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
firmwareLoadFile :: Reader   -- ^ The reader being operated on
                 -> FilePath -- ^ Name of file containing firmware image
                 -> IO ()
firmwareLoadFile rdr filename = do
  firmware <- B.readFile filename
  firmwareLoad' (T.pack filename) rdr firmware

throwPE :: Reader -> ParamException -> T.Text -> T.Text -> IO ()
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
  ( "Expected " <> paramTypeDisplay expected <>
    " but got " <> paramTypeDisplay actual )

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

-- | Get the read plan that the reader starts out with by default.
-- This has reasonable settings for most things, except for the
-- antennas, which need to be set.
defaultReadPlan :: ReadPlan
defaultReadPlan = U.unsafePerformIO $ do
  alloca $ \p -> do
    c_default_read_plan p
    peek p

-- | Like 'defaultReadPlan', but with the antenna list set to [1].
-- This is the correct setting for the
-- <http://sparkfun.com/products/14066 Sparkfun Simultaneous RFID Reader>.
antennaReadPlan :: ReadPlan
antennaReadPlan = defaultReadPlan { rpAntennas = [1] }

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

callTransportListener :: TransportListener -> RawTransportListener
callTransportListener listener tx dataLen dataPtr timeout _ = do
  bs <- B.packCStringLen (castToCStringLen dataLen dataPtr)
  listener (toBool tx) bs timeout

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
-- prints the data in magenta.
hexListener :: Handle -> IO TransportListener
hexListener h = do
  useColor <- hSupportsANSI h
  return (hexListener' h useColor)

hexListener' :: Handle -> Bool -> TransportListener
hexListener' h useColor tx dat _ = do
  setColors useColor [SetColor Foreground Vivid Magenta]
  lstn dat (prefix tx)
  setColors useColor [Reset]
  flushColor useColor
  where
    setColors False _ = return ()
    setColors True sgr = hSetSGR h sgr
    flushColor False = return ()
    flushColor True = hFlush h
    prefix True  = "Sending: "
    prefix False = "Received:"
    lstn bs pfx = do
      let (bs1, bs2) = B.splitAt 16 bs
          hex = concatMap (printf " %02x") (B.unpack bs1)
      hPutStrLn h $ pfx ++ hex
      when (not $ B.null bs2) $ lstn bs2 "         "

-- | Convert a hexadecimal string into a 'B.ByteString'.  The hex string may
-- optionally include a "0x" prefix, which will be ignored.  If the input
-- cannot be parsed as a hex string, returns 'Nothing'.
hexToBytes :: T.Text -> Maybe B.ByteString
hexToBytes hex = U.unsafePerformIO $ do
  let hexBs = textToBS hex
      hexLen = B.length hexBs
      bufLen = hexLen `div` 2
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

-- | Convert a 'TagData' to a human-readable list of lines.
displayTagData :: TagData -> [T.Text]
displayTagData td =
  concat
  [ [ "TagData"
    , "  epc         = <" <> bytesToHex (tdEpc td) <> ">"
    , "  protocol    = " <> tShow (tdProtocol td)
    , "  crc         = " <> T.pack (printf "0x%04x" $ tdCrc td)
    ]
  , case tdGen2 td of
      Nothing -> []
      Just gen2 -> ["  gen2.pc     = <" <> bytesToHex (g2Pc gen2) <> ">"]
  ]

indent :: [T.Text] -> [T.Text]
indent = map ("  " <>)

cLocale :: Ptr Locale
{-# NOINLINE cLocale #-}
cLocale = U.unsafePerformIO $ throwErrnoIfNull "newlocale" c_new_c_locale

formatTimestamp :: Word64 -> CBool -> String -> IO T.Text
formatTimestamp t local z = do
  let (seconds, millis) = t `divMod` 1000
      fmt = "%FT%H:%M:%S" ++ printf ".%03d" millis ++ z
      bufSize = 80
  withCAString fmt $ \cFmt -> allocaBytes bufSize $ \buf -> do
    ret <- c_format_time buf (fromIntegral bufSize) cFmt
           (CTime $ fromIntegral seconds) local cLocale
    if ret < 0
      then fail "error formatting time"
      else textFromCString buf

-- | Convert a timestamp into ISO 8601 format in UTC.
displayTimestamp :: Word64 -- ^ milliseconds since 1\/1\/1970 UTC
                 -> T.Text
displayTimestamp t = U.unsafePerformIO $ formatTimestamp t cFalse "Z"

-- | Convert a timestamp into ISO 8601 format in the local timezone.
displayLocalTimestamp :: Word64 -- ^ milliseconds since 1\/1\/1970 UTC
                      -> IO T.Text
displayLocalTimestamp t = formatTimestamp t cTrue "%z"

-- | Convert a 'TagReadData' to a human-readable list of lines.
displayTagReadData :: TagReadData -> [T.Text]
displayTagReadData trd =
  concat
  [ [ "TagReadData" ]
  , indent (displayTagData $ trTag trd)
  , [ "  metadataFlags = " <> T.intercalate "|" (map fl $ trMetadataFlags trd)
    , "  phase         = " <> tShow (trPhase trd)
    , "  antenna       = " <> tShow (trAntenna trd)
    , "  Gpio"
    ]
  , map dispGpio (trGpio trd)
  , [ "  readCount     = " <> tShow (trReadCount trd)
    , "  rssi          = " <> tShow (trRssi trd)
    , "  frequency     = " <> tShow (trFrequency trd)
    , "  timestamp     = " <> displayTimestamp (trTimestamp trd)
    ]
  , dat "data         " (trData trd)
  , dat "epcMemData   " (trEpcMemData trd)
  , dat "tidMemData   " (trTidMemData trd)
  , dat "userMemData  " (trUserMemData trd)
  , dat "reservedMemData" (trReservedMemData trd)
  ]
  where
    nDrop = T.length "METADATA_FLAG_"
    fl = T.drop nDrop . tShow
    dispGpio gpio = "    pin " <> tShow (gpId gpio) <>
                    (if (gpHigh gpio) then " high" else " low ") <>
                    (if (gpOutput gpio) then " output" else "  input")
    dat name bs = if B.null bs
                  then []
                  else ["  " <> name <> " = <" <> bytesToHex bs <> ">"]
