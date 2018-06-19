{-# LANGUAGE FlexibleContexts, TypeApplications, MonoLocalBinds #-}
{-# LANGUAGE OverloadedStrings #-}

-- Handles all `-L` operations

{-

Copyright 2012 - 2018 Colin Woodbury <colin@fosskers.ca>

This file is part of Aura.

Aura is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

Aura is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with Aura.  If not, see <http://www.gnu.org/licenses/>.

-}

module Aura.Commands.L
  ( viewLogFile
  , searchLogFile
  , logInfoOnPkg
  ) where

import           Aura.Colour.Text (yellow)
import           Aura.Core (badReport)
import           Aura.Languages
import           Aura.Pacman (defaultLogFile)
import           Aura.Settings
import           Aura.Utils (entrify)
import           BasePrelude hiding (FilePath)
import           Control.Monad.Freer
import           Control.Monad.Freer.Reader
import qualified Data.Set as S
import qualified Data.Text as T
import qualified Data.Text.IO as T
import           Shelly
import           Utilities

---

-- | The contents of the Pacman log file.
newtype Log = Log [T.Text]

data LogEntry = LogEntry { _pkgName :: T.Text, _firstInstall :: T.Text, _upgrades :: Word, _recent :: [T.Text] }

viewLogFile :: (Member (Reader Settings) r, Member IO r) => Eff r ()
viewLogFile = do
  pth <- asks (fromMaybe defaultLogFile . logPathOf . commonConfigOf)
  void . send . shelly @IO . loudSh $ run_ "less" [toTextIgnore pth]

-- Very similar to `searchCache`. But is this worth generalizing?
searchLogFile :: Settings -> T.Text -> IO ()
searchLogFile ss input = do
  let pth = fromMaybe defaultLogFile . logPathOf $ commonConfigOf ss
  logFile <- T.lines <$> shelly (readfile pth)
  traverse_ T.putStrLn $ searchLines (Regex input) logFile

logInfoOnPkg :: (Member (Reader Settings) r, Member IO r) => S.Set T.Text -> Eff r ()
logInfoOnPkg pkgs
  | null pkgs = pure ()
  | otherwise = do
      ss <- ask
      let pth = fromMaybe defaultLogFile . logPathOf $ commonConfigOf ss
      logFile <- fmap (Log . T.lines) . send . shelly @IO $ readfile pth
      let (bads, goods) = partitionEithers . map (logLookup logFile) $ toList pkgs
      reportNotInLog bads
      send . traverse_ T.putStrLn $ map (renderEntry ss) goods

logLookup :: Log -> T.Text -> Either T.Text LogEntry
logLookup (Log lns) p = case matches of
  []    -> Left p
  (h:t) -> Right $ LogEntry p
                   (T.take 16 $ T.tail h)
                   (fromIntegral . length $ filter (T.isInfixOf " upgraded ") t)
                   (reverse . take 5 $ reverse t)
  where matches = filter (T.isInfixOf (" " <> p <> " (")) lns

renderEntry :: Settings -> LogEntry -> T.Text
renderEntry ss (LogEntry pn fi us rs) = entrify ss fields entries <> "\n" <> recent
  where fields  = map yellow . logLookUpFields $ langOf ss
        entries = [ pn, fi, T.pack (show us), "" ]
        recent  = T.unlines $ map (" " <>) rs

------------
-- REPORTING
------------
reportNotInLog :: (Member (Reader Settings) r, Member IO r) => [T.Text] -> Eff r ()
reportNotInLog = badReport reportNotInLog_1
