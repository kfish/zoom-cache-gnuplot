{-# LANGUAGE DeriveDataTypeable #-}

module Main (
    main
) where

import Control.Applicative
import Control.Exception
import Data.ByteString (ByteString)
import Data.Char (toLower)
import Data.Maybe (fromMaybe, catMaybes, mapMaybe)
import Data.Monoid
import Data.Typeable
import System.Console.GetOpt
import System.Environment (getArgs)
import System.Exit (exitWith)
import System.FilePath.Posix
import qualified Data.Iteratee as I
import Data.Iteratee (Iteratee(..), stream2stream, fileDriverRandom)
import Data.Iteratee.ZoomCache (Stream)
import Data.ZoomCache.Numeric

import Data.ZoomCache.Gnuplot
import qualified Graphics.Gnuplot.Advanced as Plot
import Graphics.Gnuplot.Simple
import qualified Graphics.Gnuplot.Terminal.PNG as PNG
import qualified Graphics.Gnuplot.Terminal.PostScript as PostScript
import qualified Graphics.Gnuplot.Terminal.SVG as SVG
import qualified Graphics.Gnuplot.Terminal.X11 as X11
import Graphics.Gnuplot.Value.Tuple (C(..))
import qualified Graphics.Gnuplot.Plot.TwoDimensional as Plot

data ParseError = ParseError

parseTrack :: String -> Either ParseError (FilePath, TrackNo, Int)
parseTrack arg =
    case w of
      [w1, w2, w3] -> Right (w1, read w2, read w3)
      _ ->  Left ParseError
  where
    w = words arg
    words :: String -> [String]
    words s = case dropWhile (==':') s of
                "" -> []
                s' -> w : words s''
                    where
                      (w, s'') = break (==':') s'

parseTrack2 :: String -> Either ParseError (FilePath, TrackNo)
parseTrack2 arg =
    case w of
      [w1, w2] -> Right (w1, read w2)
      _ ->  Left ParseError
  where
    w = words arg
    words :: String -> [String]
    words s = case dropWhile (==':') s of
                "" -> []
                s' -> w : words s''
                    where
                      (w, s'') = break (==':') s'


-- Options record, only gnuplot options for now
data Options = Options
    { gnuplotOpts :: [Attribute]
    , candleSticks :: [(FilePath, TrackNo, Int)]
    , avgs :: [(FilePath, TrackNo, Int)]
    , mavgs :: [(FilePath, TrackNo, Int)]
    , bbs :: [(FilePath, TrackNo, Int)]
    , ls :: [(FilePath, TrackNo)]
    }

defaultOptions = Options
    { gnuplotOpts = []
    , candleSticks = []
    , avgs = []
    , mavgs = []
    , bbs = []
    , ls = []
    }

parseCustom :: String -> Attribute
parseCustom s =
    Custom s1 [tail s2]
      where (s1, s2) = break (==':') s



-- Code needs to be abstracted and factored here
options :: [OptDescr (Options -> Options)]
options =
    [ Option ['g'] ["gnuplot"]
        (OptArg ((\ f opts -> opts { gnuplotOpts = parseCustom f : gnuplotOpts opts }) . fromMaybe "gnuplot")
                             "KEY:VALUE")
        "gnuplot KEY:VALUE"
    , Option ['c'] ["candlesticks"]
        (OptArg ((\ f opts ->
          opts { candleSticks = either (error "bad command line syntax")
                                 (: candleSticks opts) $ parseTrack f }) .
                               fromMaybe "candlesticks")
          "FILE:TRACKNO:SUMMARYLVL")
        "candlesticks FILE:TRACKNO:SUMMARYLVL"
    , Option ['a'] ["avg"]
        (OptArg ((\ f opts ->
          opts { avgs = either (error "bad command line syntax")
                                 (: avgs opts) $ parseTrack f }) .
                               fromMaybe "avg")
          "FILE:TRACKNO:SUMMARYLVL")
        "avg FILE:TRACKNO:SUMMARYLVL"
    , Option ['m'] ["mavg"]
        (OptArg ((\ f opts ->
          opts { mavgs = either (error "bad command line syntax")
                                 (: mavgs opts) $ parseTrack f }) .
                               fromMaybe "mavg")
          "FILE:TRACKNO:SUMMARYLVL")
        "mavg FILE:TRACKNO:SUMMARYLVL"
    , Option ['b'] ["bollinger"]
        (OptArg ((\ f opts ->
          opts { bbs = either (error "bad command line syntax")
                                 (: bbs opts) $ parseTrack f }) .
                               fromMaybe "bollinger")
          "FILE:TRACKNO:SUMMARYLVL")
        "bollinger FILE:TRACKNO:SUMMARYLVL"
    , Option ['l'] ["lines"]
        (OptArg ((\ f opts ->
          opts { ls = either (error "bad command line syntax")
                                 (: ls opts) $ parseTrack2 f }) .
                               fromMaybe "lines")
          "FILE:TRACKNO")
        "lines FILE:TRACKNO"
    ]

parseOpts :: [String] -> IO (Options, [String])
parseOpts argv =
    case getOpt Permute options argv of
      (o, n, []) -> return (foldl (flip id) defaultOptions o, n)
      (_, _, errs) -> ioError (userError (concat errs
                                          ++ usageInfo header options))
        where header = "Usage: zoom-cache-gnuplot ..."

candleProcess :: (FilePath, TrackNo, Int) -> IO (Plot.T TimeStamp Double)
candleProcess (fp, tn, lvl) = fileDriverRandom iter fp
  where
    iter :: Iteratee ByteString IO (Plot.T TimeStamp Double)
    iter = I.joinI . (enumCacheFile standardIdentifiers) $ do
        streams <- mapMaybe (isSumLvl tn lvl) <$> stream2stream
        let cData = candlePlotData streams
        return $ candlePlot cData

avgProcess :: (FilePath, TrackNo, Int) -> IO (Plot.T TimeStamp Double)
avgProcess (fp, tn, lvl) = fileDriverRandom iter fp
  where
    iter :: Iteratee ByteString IO (Plot.T TimeStamp Double)
    iter = I.joinI . (enumCacheFile standardIdentifiers) $ do
        streams <- mapMaybe (isSumLvl tn lvl) <$> stream2stream
        return $ avgPlot streams

mavgProcess :: (FilePath, TrackNo, Int) -> IO (Plot.T TimeStamp Double)
mavgProcess (fp, tn, lvl) = fileDriverRandom iter fp
  where
    iter :: Iteratee ByteString IO (Plot.T TimeStamp Double)
    iter = I.joinI . (enumCacheFile standardIdentifiers) $ do
      streams <- mapMaybe (isSumLvl tn lvl) <$> stream2stream
      return $ mavgPlot streams

bollingerProcess :: (FilePath, TrackNo, Int) -> IO (Plot.T TimeStamp Double)
bollingerProcess (fp, tn, lvl) = fileDriverRandom iter fp
  where
    iter :: Iteratee ByteString IO (Plot.T TimeStamp Double)
    iter = I.joinI . (enumCacheFile standardIdentifiers) $ do
      streams <- mapMaybe (isSumLvl tn lvl) <$> stream2stream
      return $ bollingerPlot streams

lineProcess :: (FilePath, TrackNo) -> IO (Plot.T TimeStamp Double)
lineProcess (fp, tn) = fileDriverRandom iter fp
  where
    iter :: Iteratee ByteString IO (Plot.T TimeStamp Double)
    iter = I.joinI . enumCacheFile standardIdentifiers $
                     (I.joinI . filterTracks [tn] .
                      I.joinI . enumDouble $ (linePlot <$> stream2stream))

isSumLvl :: TrackNo -> Int -> Stream -> Maybe ZoomSummary
isSumLvl tn lvl str =
    case str of
      StreamPacket{} -> Nothing
      StreamSummary _ tn' zsum@(ZoomSummary sum) ->
          if tn == tn' && summaryLevel sum == lvl then Just zsum else Nothing

data UnrecognisedFormatException = UnrecognisedFormatException
    deriving (Show, Typeable)

instance Exception UnrecognisedFormatException

--Can't write the type signature for this because the appropriate type classes
--are not exposed.
getPlotter Nothing = Right $ Plot.plot X11.cons
getPlotter (Just fp) =
    case map toLower $ takeExtension fp of
      ".png" -> Right . Plot.plot $ PNG.cons fp
      ".svg" -> Right . Plot.plot $ SVG.cons fp
      ".ps"  -> Right . Plot.plot $ PostScript.cons fp
      _      -> Left UnrecognisedFormatException

main :: IO ()
main = do
    args <- getArgs
    (opts, remainder) <- parseOpts args
    cPlots <- fmap mconcat . mapM candleProcess $
              candleSticks opts
    aPlots <- fmap mconcat . mapM avgProcess $ avgs opts
    mPlots <- fmap mconcat . mapM mavgProcess $ mavgs opts
    bPlots <- fmap mconcat . mapM bollingerProcess $ bbs opts
    lPlots <- fmap mconcat . mapM lineProcess $ ls opts
    let plots = mconcat [cPlots, aPlots, mPlots, bPlots, lPlots]
        plotter =
            case remainder of
              [] -> getPlotter Nothing
              x:[] -> getPlotter $ Just x
              _ -> error "too many output arguments"
    case plotter of
      Left e -> throwIO e
      Right p ->
          exitWith =<< p plots
