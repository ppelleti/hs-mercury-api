{-# LANGUAGE OverloadedStrings #-}

import Control.Concurrent
import Control.Exception
import Control.Monad
import qualified Data.ByteString as B
import Data.Int
import Data.List
import Data.Monoid
import Data.Ord
import qualified Data.Text as T
import qualified Data.Text.IO as T
import Data.Word
import Options.Applicative
import System.Console.ANSI
import qualified System.Hardware.MercuryApi as TMR
import qualified System.Hardware.MercuryApi.Params as TMR
import System.Exit
import System.IO
import Text.Printf

import ExampleUtil

data Opts = Opts
  { oUri :: String
  , oRegion :: String
  , oPower :: Int32
  , oListen :: Bool
  , oLong :: Bool
  }

opts :: Parser Opts
opts = Opts
  <$> optUri
  <*> optRegion
  <*> optPower
  <*> optListen
  <*> switch (long "long" <>
              short 'l' <>
              help "Print lots of information per tag")

opts' = info (helper <*> opts)
  ( fullDesc <>
    header "tmr-read - read tags" )

readUser =
  TMR.TagOp_GEN2_ReadData
  { TMR.opBank = TMR.GEN2_BANK_USER
  , TMR.opExtraBanks = []
  , TMR.opWordAddress = 0
  , TMR.opLen = 32
  }

printInColor :: [T.Text] -> Int -> IO ()
printInColor xs n = do
  let color = if n `mod` 2 == 0 then Blue else Green
  setSGR [SetColor Foreground Vivid color]
  mapM_ T.putStrLn xs
  setSGR [Reset]

displayTag :: TMR.TagReadData -> T.Text
displayTag trd = strength <> " <" <> epc <> "> " <> user
  where
    strength = T.pack $ printf "%3d" (TMR.trRssi trd)
    epc = TMR.bytesToHex $ TMR.tdEpc $ TMR.trTag trd
    user = T.pack $ show $ B.takeWhile (/= 0) (TMR.trData trd)

main = do
  o <- execParser opts'

  rdr <- createConnectAndParams (oUri o) (oListen o) (oRegion o) (oPower o)
  TMR.paramSetReadPlanTagop rdr (Just readUser)

  tags <- TMR.read rdr 1000
  let tags' = reverse $ sortBy (comparing TMR.trRssi) tags
  putStrLn $ "read " ++ show (length tags') ++ " tags"
  if oLong o
    then zipWithM_ printInColor (map TMR.displayTagReadData tags') [0..]
    else forM_ tags' (T.putStrLn . displayTag)

  TMR.destroy rdr
