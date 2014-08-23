{-# LANGUAGE OverloadedStrings #-}
module Main where

import           Control.Applicative ((<$>))
import           Control.Monad (foldM)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as C8
import qualified Data.ByteString.Base64 as B64
import qualified Data.ByteString.Lazy as LBS
import           Data.Monoid ((<>))
import qualified Data.Map as M
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import           Network.HTTP.Conduit
import           System.Exit (exitSuccess, exitFailure)

import           Data.HBCI.Types
import           Data.HBCI.HbciDef
import           Data.HBCI.Messages
import           Data.HBCI.Gen
import           Data.HBCI.Parser

msgVals :: MSGEntry
msgVals = M.fromList [("Idn", M.fromList [("KIK", DEGentry $ M.fromList [("country", DEStr "280")])])
                     ,("ProcPrep", M.fromList [("BPD", DEentry $ DEStr "0")
                                              ,("UPD", DEentry $ DEStr "0")
                                              ,("lang", DEentry $ DEStr "0")
                                              ,("prodName", DEentry $ DEStr "HsBCI")
                                              ,("prodVersion", DEentry $ DEStr "0.1.0")
                                              ])
                     ]

exitWMsg msg = TIO.putStrLn ("ERROR: " <> msg) >> exitFailure

sendMsg :: BankProperties -> BS.ByteString -> IO BS.ByteString
sendMsg props msg = do
  request' <- parseUrl $ T.unpack $ bankPinTanUrl props
  let request = request' { method = "POST"
                         , requestHeaders = ("Content-Type", "application/octet-stream"): requestHeaders request'
                         , requestBody = RequestBodyBS $ B64.encode msg
                         }
  response <- withManager $ httpLbs request
  return $! B64.decodeLenient $! BS.concat $! LBS.toChunks $! responseBody response

fromEither :: Either T.Text a -> IO a
fromEither = either exitWMsg return

main :: IO ()
main = do
  putStrLn "Please enter your BLZ:"
  blz <- T.pack <$> getLine

  putStrLn "Please enter your User ID:"
  userID <- T.pack <$> getLine

  putStrLn "Please enter your PIN:"
  pin <- T.pack <$> getLine

  bankProps <- getBankPropsFromFile "resources/blz.properties" >>= either (\err -> TIO.putStrLn err >> exitFailure) return
  props <- maybe (TIO.putStrLn ("Unknown BLZ: " <> blz) >> exitFailure) return (M.lookup blz bankProps)
  xml <- getXml ("resources/hbci-" <> (T.unpack $ bankPinTanVersion props) <> ".xml")
  hbciDef <- either exitWMsg return $ getMSGfromXML xml

  dialogInitAnonDef <- maybe (exitWMsg "Error: Can't find 'DialogInitAnon'") return $ M.lookup "DialogInitAnon" hbciDef
  dialogInitAnonVals <- fromEither $ foldM (\acc (k,v) -> nestedInsert k (DEStr v) acc) msgVals [(["Idn","KIK","blz"], blz)
                                                                                                ,(["Idn","customerid"], userID)]
  dialogInitAnonMsg <- fromEither $ gen <$> fillMsg dialogInitAnonVals dialogInitAnonDef

  C8.putStrLn $ "Message to be send:\n" <> dialogInitAnonMsg
  dialogInitAnonResponse <- sendMsg props dialogInitAnonMsg
  C8.putStrLn $ "Message received:\n" <> dialogInitAnonResponse

  dialogInitAnonResDef <- maybe (exitWMsg "ERROR: Can't find 'DialogInitAnonRes'") return $ M.lookup "DialogInitAnonRes" hbciDef
  initAnonRes <- fromEither $ return . extractMsg dialogInitAnonResDef =<< parser dialogInitAnonResponse
  putStrLn $ show $ initAnonRes
  exitSuccess
