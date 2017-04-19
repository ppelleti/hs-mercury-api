{-# LANGUAGE OverloadedStrings #-}

import Control.Concurrent
import Control.Exception
import Control.Monad
import qualified Data.ByteString as B
import qualified Data.Text as T
import qualified Data.Text.IO as T
import Data.Word
import qualified System.Hardware.MercuryApi as TMR
import Text.Printf

listener :: TMR.TransportListener
listener tx dat _ = lstn dat (prefix tx)
  where
    prefix True  = "Sending: "
    prefix False = "Received:"
    lstn bs pfx = do
      let (bs1, bs2) = B.splitAt 16 bs
          hex = concatMap (printf " %02x") (B.unpack bs1)
      putStrLn $ pfx ++ hex
      when (not $ B.null bs2) $ lstn bs2 "         "

stringParams :: [TMR.Param]
stringParams =
  [ TMR.PARAM_VERSION_HARDWARE
  , TMR.PARAM_VERSION_SERIAL
  , TMR.PARAM_VERSION_MODEL
  , TMR.PARAM_VERSION_SOFTWARE
  , TMR.PARAM_URI
  , TMR.PARAM_PRODUCT_GROUP
  , TMR.PARAM_READER_DESCRIPTION
  , TMR.PARAM_READER_HOSTNAME
  ]

main = do
  putStrLn "create"
  rdr <- TMR.create "tmr:///dev/ttyUSB0"
  putStrLn "addTransportListener"
  TMR.addTransportListener rdr listener
  putStrLn "paramGet PARAM_TRANSPORTTIMEOUT"
  timeout <- TMR.paramGet rdr TMR.PARAM_TRANSPORTTIMEOUT :: IO Word32
  print timeout
  putStrLn "connect"
  TMR.connect rdr
  putStrLn "paramList"
  params <- TMR.paramList rdr
  forM_ params $ \param -> do
    putStrLn $ show param ++ " - " ++ T.unpack (TMR.paramName param)
  forM_ stringParams $ \param -> do
    putStrLn $ "paramGet " ++ show param
    txt <- TMR.paramGet rdr param
    T.putStrLn txt
  putStrLn "destroy"
  TMR.destroy rdr
