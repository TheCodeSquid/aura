{-# LANGUAGE OverloadedStrings, MultiWayIf, ViewPatterns #-}
{-# LANGUAGE FlexibleContexts, TypeApplications, MonoLocalBinds #-}

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

-- Layer for agnostic package installation.
-- Backend for `Aura.Commands.A`.

module Aura.Install
  ( InstallOptions(..)
  , install
  , displayPkgDeps
  ) where

import           Aura.Build
import           Aura.Colour.Text
import           Aura.Core
import           Aura.Dependencies
import           Aura.Languages
import           Aura.Pacman
import           Aura.Pkgbuild.Base
import           Aura.Pkgbuild.Records
import           Aura.Settings
import           Aura.Types
import           Aura.Utils
import           BasePrelude
import           Control.Concurrent.Async
import           Control.Monad.Freer
import           Control.Monad.Freer.Error
import           Control.Monad.Freer.Reader
import qualified Data.Set as S
import qualified Data.Text as T
import qualified Data.Text.IO as T
import           Shelly (toTextIgnore)

---

-- | Installation options.
data InstallOptions = InstallOptions
                      { label         :: T.Text
                      , installLookup :: Settings -> T.Text -> IO (Maybe Buildable)
                      , repository    :: Repository }

-- | High level 'install' command. Handles installing
-- dependencies.
install :: (Member (Reader Settings) r, Member (Error Failure) r, Member IO r) =>
  InstallOptions -> S.Set T.Text -> Eff r ()
install opts pkgs = do
  ss <- ask
  if | null pkgs -> throwError $ Failure install_2
     | not $ switch ss DeleteMakeDeps -> install' opts pkgs
     | otherwise -> do -- `-a` was used.
         orphansBefore <- send orphans
         install' opts pkgs
         orphansAfter <- send orphans
         let makeDeps = orphansAfter \\ orphansBefore
         unless (null makeDeps) $ do
           send . notify . removeMakeDepsAfter_1 $ langOf ss
           removePkgs makeDeps

install' :: (Member (Reader Settings) r, Member (Error Failure) r, Member IO r) =>
  InstallOptions -> S.Set T.Text -> Eff r ()
install' opts (toList -> pkgs) = do
  ss       <- ask
  unneeded <- bool (pure []) (catMaybes <$> send (mapConcurrently isInstalled pkgs)) $ shared ss NeededOnly
  let (ignored, notIgnored) = partition (`elem` ignoredPkgsOf (commonConfigOf ss)) pkgs
  installAnyway <- confirmIgnored ignored
  let toInstall = (notIgnored <> installAnyway) \\ unneeded
  -- reportIgnoredPackages ignored  -- 2014 December  7 @ 14:52
  reportUnneededPackages unneeded
  toBuild <- lookupPkgs (installLookup opts ss) toInstall >>= pkgbuildDiffs
  if | null toBuild && shared ss NeededOnly && unneeded == pkgs -> send . notify . install_2 $ langOf ss
     | null toBuild -> throwError $ Failure install_2
     | otherwise -> do
         send . notify . install_5 $ langOf ss
         allPkgs <- depsToInstall (repository opts) toBuild
         let (repoPkgs, buildPkgs) = partitionPkgs allPkgs
         reportPkgsToInstall (label opts) repoPkgs buildPkgs
         unless (switch ss DryRun) $ do
           continue <- send $ optionalPrompt @IO ss install_3
           if | not continue -> throwError $ Failure install_4
              | otherwise    -> do
                  repoInstall repoPkgs
                  send $ storePkgbuilds buildPkgs
                  buildAndInstall buildPkgs

confirmIgnored :: (Member (Reader Settings) r, Member IO r) => [T.Text] -> Eff r [T.Text]
confirmIgnored ps = ask >>= \ss -> filterM (send . optionalPrompt @IO ss . confirmIgnored_1) ps

-- | Check a list of a package names are buildable, and mark them as explicit.
lookupPkgs :: (Member (Reader Settings) r, Member IO r) =>
  (T.Text -> IO (Maybe Buildable)) -> [T.Text] -> Eff r [Buildable]
lookupPkgs f pkgs = do
  (nons, okay) <- partitionEithers <$> send (mapConcurrently lookupBuild pkgs)
  reportNonPackages nons
  pure $ map (\b -> b { isExplicit = True }) okay
  where lookupBuild pkg = maybe (Left pkg) Right <$> f pkg

depsToInstall :: (Member (Reader Settings) r, Member (Error Failure) r, Member IO r) =>
  Repository -> [Buildable] -> Eff r [Package]
depsToInstall repo bs = do
  ss <- ask
  traverse (send . packageBuildable ss) bs >>= resolveDeps repo

repoInstall :: (Member (Reader Settings) r, Member (Error Failure) r, Member IO r) => [T.Text] -> Eff r ()
repoInstall [] = pure ()
repoInstall ps = do
  pacOpts <- asks (asFlag . commonConfigOf)
  rethrow . pacman $ ["-S", "--asdeps"] <> pacOpts <> ps

buildAndInstall :: (Member (Reader Settings) r, Member (Error Failure) r, Member IO r) => [Buildable] -> Eff r ()
buildAndInstall []     = pure ()
buildAndInstall (b:bs) = do
  ps <- map toTextIgnore <$> buildPackages [b]
  installPkgFiles asDeps ps
  buildAndInstall bs
  where asDeps = if isExplicit b then Nothing else Just "--asdeps"

------------
-- REPORTING
------------
-- | Display dependencies.
displayPkgDeps :: (Member (Reader Settings) r, Member (Error Failure) r, Member IO r) =>
  InstallOptions -> S.Set T.Text -> Eff r ()
displayPkgDeps opts ps
  | null ps = pure ()
  | otherwise = do
      ss   <- ask
      bs   <- catMaybes <$> send (mapConcurrently (installLookup opts ss) $ toList ps)
      pkgs <- depsToInstall (repository opts) bs
      reportDeps (switch ss LowVerbosity) $ partitionPkgs pkgs
  where reportDeps True  = send . uncurry reportListOfDeps
        reportDeps False = uncurry (reportPkgsToInstall $ label opts)

reportPkgsToInstall :: (Member (Reader Settings) r, Member IO r) => T.Text -> [T.Text] -> [Buildable] -> Eff r ()
reportPkgsToInstall la rps bps = do
  lang <- asks langOf
  pl (reportPkgsToInstall_1    lang) (sort rps)
  pl (reportPkgsToInstall_2 la lang) (sort $ map baseNameOf bps)
      where pl m r = send $ printList @IO green cyan m r

reportListOfDeps :: [T.Text] -> [Buildable] -> IO ()
reportListOfDeps rps bps = do
  traverse_ T.putStrLn $ sort rps
  traverse_ T.putStrLn . sort $ map baseNameOf bps

reportNonPackages :: (Member (Reader Settings) r, Member IO r) => [T.Text] -> Eff r ()
reportNonPackages = badReport reportNonPackages_1

reportUnneededPackages :: (Member (Reader Settings) r, Member IO r) =>  [T.Text] -> Eff r ()
reportUnneededPackages pkgs = asks langOf >>= \lang ->
  send (printList @IO yellow cyan (reportUnneededPackages_1 lang) pkgs)

pkgbuildDiffs :: (Member (Reader Settings) r, Member IO r) => [Buildable] -> Eff r [Buildable]
pkgbuildDiffs [] = pure []
pkgbuildDiffs ps = ask >>= check
    where check ss | not $ switch ss DiffPkgbuilds = pure ps
                   | otherwise = traverse_ displayDiff ps $> ps
          displayDiff :: (Member (Reader Settings) r, Member IO r) => Buildable -> Eff r ()
          displayDiff p = do
            let name = baseNameOf p
            lang     <- asks langOf
            isStored <- send $ hasPkgbuildStored name
            if not isStored
               then send . warn $ reportPkgbuildDiffs_1 name lang
               else do
                 let new = _pkgbuild $ pkgbuildOf p
                 old <- send $ readPkgbuild name
                 case comparePkgbuilds name old new of
                   "" -> send . notify $ reportPkgbuildDiffs_2 name lang
                   d  -> send $ do
                      warn $ reportPkgbuildDiffs_3 name lang
                      T.putStrLn d
